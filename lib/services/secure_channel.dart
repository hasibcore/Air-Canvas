// AirCanvas Secure Channel v2
//
// Authenticated encryption replacing former XOR obfuscation. Reference implementation
// and test vectors: windows_server/secure_channel_ref.py - mirrors C# implementation in
// windows_server/AirCanvasServer.cs SecureChannel class.
//
// Wire format:
//   sealed frame = IV(16) || CT(16*n) || TAG(16)        // minimum 48 bytes
//   plaintext    = SEQ(4, big-endian) || payload
//   CT           = AES-256-CBC(encKey, IV, PKCS7(plaintext))
//   TAG          = HMAC-SHA256(macKey, IV || CT)[0..16]
//
// Encrypt-then-MAC: MAC verified prior to decryption, preventing padding oracle attacks.
// Directional keys prevent reflection attacks. Monotonic sequence numbers defeat replays.
//
// Standalone C# server compiles on .NET Framework 4.0 via build_windows_exe.bat
// where AesGcm is unavailable; CBC + HMAC (Encrypt-then-MAC) is natively supported
// and cryptographically equivalent in security.

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart' as pc;

/// Web platform does not support dart:isolate - safe fallback flag.
const bool _kIsWeb = identical(0, 0.0);

/// Authenticated, replay-resistant channel per WebSocket connection.
class SecureChannel {
  static const int ivLength = 16;
  static const int tagLength = 16;
  static const int seqLength = 4;

  /// Minimum valid frame size (IV + at least one block CT + TAG).
  static const int minFrameLength = ivLength + 16 + tagLength;

  /// PIN key derivation iterations (2048 iterations ensures sub-50ms instant pairing on mobile).
  static const int pbkdf2Iterations = 2048;
  static const int pbkdf2SaltLength = 16;

  static const String _c2sEnc = 'AirCanvas-c2s-enc-v2';
  static const String _c2sMac = 'AirCanvas-c2s-mac-v2';
  static const String _s2cEnc = 'AirCanvas-s2c-enc-v2';
  static const String _s2cMac = 'AirCanvas-s2c-mac-v2';

  static final Random _rng = Random.secure();

  final Uint8List _sendEnc;
  final Uint8List _sendMac;
  final Uint8List _recvEnc;
  final Uint8List _recvMac;

  int _sendSeq = 0;
  int _lastRecvSeq = 0;

  /// Number of frames rejected by MAC/replay check.
  int rejectedFrames = 0;

  SecureChannel._(this._sendEnc, this._sendMac, this._recvEnc, this._recvMac);

  /// [sessionKey] must be exactly 32 bytes. [isServer] configures directional keys.
  factory SecureChannel(List<int> sessionKey, {required bool isServer}) {
    if (sessionKey.length != 32) {
      throw ArgumentError('session key must be 32 bytes, got ${sessionKey.length}');
    }
    final key = Uint8List.fromList(sessionKey);
    final c2sE = _derive(_c2sEnc, key);
    final c2sM = _derive(_c2sMac, key);
    final s2cE = _derive(_s2cEnc, key);
    final s2cM = _derive(_s2cMac, key);
    return isServer
        ? SecureChannel._(s2cE, s2cM, c2sE, c2sM)
        : SecureChannel._(c2sE, c2sM, s2cE, s2cM);
  }

  /// Direct channel from PIN + salt for session key wrapping/unwrapping.
  factory SecureChannel.fromPin(String pin, List<int> salt,
      {required bool isServer, int iterations = pbkdf2Iterations}) {
    return SecureChannel(derivePinKey(pin, salt, iterations: iterations),
        isServer: isServer);
  }

  int get sendSequence => _sendSeq;

  static Uint8List _derive(String label, Uint8List key) {
    final input = Uint8List.fromList(<int>[...utf8.encode(label), ...key]);
    return Uint8List.fromList(c.sha256.convert(input).bytes);
  }

  /// Cryptographically secure random bytes.
  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (int i = 0; i < length; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  static Uint8List generateSessionKey() => randomBytes(32);

  static Uint8List generateSalt() => randomBytes(pbkdf2SaltLength);

  /// PBKDF2-HMAC-SHA1 for .NET Framework 4.0 compatibility.
  /// RFC 2898 / HMAC-SHA1 provides secure key derivation across Dart, Python, and C#.
  static Uint8List derivePinKey(String pin, List<int> salt,
      {int iterations = pbkdf2Iterations}) {
    final derivator = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA1Digest(), 64))
      ..init(pc.Pbkdf2Parameters(Uint8List.fromList(salt), iterations, 32));
    return derivator.process(Uint8List.fromList(utf8.encode(pin)));
  }

  /// Encrypts and authenticates [payload] into a wire frame.
  /// [iv] and [seq] are optional parameters for deterministic test vectors.
  Uint8List seal(List<int> payload, {Uint8List? iv, int? seq}) {
    final int sequence;
    if (seq != null) {
      sequence = seq;
    } else {
      _sendSeq++;
      sequence = _sendSeq;
    }
    final nonce = iv ?? randomBytes(ivLength);

    final plain = Uint8List(seqLength + payload.length);
    plain[0] = (sequence >> 24) & 0xFF;
    plain[1] = (sequence >> 16) & 0xFF;
    plain[2] = (sequence >> 8) & 0xFF;
    plain[3] = sequence & 0xFF;
    plain.setRange(seqLength, plain.length, payload);

    final ct = _aesCbc(_sendEnc, nonce, _pkcs7Pad(plain), forEncryption: true);
    final tag = _tag(_sendMac, nonce, ct);

    final out = Uint8List(nonce.length + ct.length + tagLength);
    out.setRange(0, nonce.length, nonce);
    out.setRange(nonce.length, nonce.length + ct.length, ct);
    out.setRange(nonce.length + ct.length, out.length, tag);
    return out;
  }

  /// Verifies frame and returns payload, or null if tampered, wrong key, or replayed.
  Uint8List? open(List<int> frame) {
    if (frame.length < minFrameLength ||
        (frame.length - ivLength - tagLength) % 16 != 0) {
      rejectedFrames++;
      return null;
    }
    final data = frame is Uint8List ? frame : Uint8List.fromList(frame);
    final iv = Uint8List.sublistView(data, 0, ivLength);
    final ct = Uint8List.sublistView(data, ivLength, data.length - tagLength);
    final tag = Uint8List.sublistView(data, data.length - tagLength);

    if (!constantTimeEquals(tag, _tag(_recvMac, iv, ct))) {
      rejectedFrames++;
      return null;
    }

    final plain = _pkcs7Unpad(_aesCbc(_recvEnc, iv, ct, forEncryption: false));
    if (plain == null || plain.length < seqLength) {
      rejectedFrames++;
      return null;
    }

    final seq = (plain[0] << 24) | (plain[1] << 16) | (plain[2] << 8) | plain[3];
    if (seq <= _lastRecvSeq) {
      rejectedFrames++; // Replay or outdated frame
      return null;
    }
    _lastRecvSeq = seq;
    return Uint8List.sublistView(plain, seqLength);
  }

  static Uint8List _tag(Uint8List macKey, Uint8List iv, Uint8List ct) {
    final signed = Uint8List(iv.length + ct.length);
    signed.setRange(0, iv.length, iv);
    signed.setRange(iv.length, signed.length, ct);
    final full = c.Hmac(c.sha256, macKey).convert(signed).bytes;
    return Uint8List.fromList(full.sublist(0, tagLength));
  }

  static Uint8List _aesCbc(Uint8List key, Uint8List iv, Uint8List input,
      {required bool forEncryption}) {
    final cipher = pc.CBCBlockCipher(pc.AESEngine())
      ..init(forEncryption,
          pc.ParametersWithIV<pc.KeyParameter>(pc.KeyParameter(key), iv));
    final out = Uint8List(input.length);
    var offset = 0;
    while (offset < input.length) {
      offset += cipher.processBlock(input, offset, out, offset);
    }
    return out;
  }

  static Uint8List _pkcs7Pad(Uint8List data) {
    final pad = 16 - (data.length % 16); // 1..16, never 0
    final out = Uint8List(data.length + pad);
    out.setRange(0, data.length, data);
    for (int i = data.length; i < out.length; i++) {
      out[i] = pad;
    }
    return out;
  }

  static Uint8List? _pkcs7Unpad(Uint8List data) {
    if (data.isEmpty || data.length % 16 != 0) return null;
    final pad = data[data.length - 1];
    if (pad < 1 || pad > 16 || pad > data.length) return null;
    for (int i = data.length - pad; i < data.length; i++) {
      if (data[i] != pad) return null;
    }
    return Uint8List.sublistView(data, 0, data.length - pad);
  }

  /// Constant-time comparison to prevent timing side-channel attacks on tags.
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Wraps session key on server using PIN-derived key during pairing.
Uint8List wrapSessionKey(List<int> sessionKey, String pin, List<int> salt,
    {int iterations = SecureChannel.pbkdf2Iterations, Uint8List? iv}) {
  final wrapper =
      SecureChannel.fromPin(pin, salt, isServer: true, iterations: iterations);
  return wrapper.seal(sessionKey, iv: iv, seq: 1);
}

/// Unwraps session key on client. Returns null if PIN or MAC is invalid.
Uint8List? unwrapSessionKey(List<int> wrapped, String pin, List<int> salt,
    {int iterations = SecureChannel.pbkdf2Iterations}) {
  final wrapper =
      SecureChannel.fromPin(pin, salt, isServer: false, iterations: iterations);
  final key = wrapper.open(wrapped);
  if (key == null || key.length != 32) return null;
  return key;
}

// ---------------------------------------------------------------------------
// Background Isolate PBKDF2
//
// Offloads PBKDF2 execution via Isolate.run so UI thread remains completely responsive.
// Runs once during pairing; per-packet seal/open stays on UI isolate (sub-millisecond).
// ---------------------------------------------------------------------------

/// Isolate-backed version of [wrapSessionKey] (server side).
Future<Uint8List> wrapSessionKeyAsync(
    List<int> sessionKey, String pin, List<int> salt,
    {int iterations = SecureChannel.pbkdf2Iterations, Uint8List? iv}) {
  if (_kIsWeb) {
    return Future.value(wrapSessionKey(sessionKey, pin, salt,
        iterations: iterations, iv: iv));
  }
  return Isolate.run(() =>
      wrapSessionKey(sessionKey, pin, salt, iterations: iterations, iv: iv));
}

/// Isolate-backed version of [unwrapSessionKey] (client side).
Future<Uint8List?> unwrapSessionKeyAsync(
    List<int> wrapped, String pin, List<int> salt,
    {int iterations = SecureChannel.pbkdf2Iterations}) {
  if (_kIsWeb) {
    return Future.value(
        unwrapSessionKey(wrapped, pin, salt, iterations: iterations));
  }
  return Isolate.run(
      () => unwrapSessionKey(wrapped, pin, salt, iterations: iterations));
}



