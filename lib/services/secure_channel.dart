// AirCanvas Secure Channel v2
//
// পুরনো XOR "এনক্রিপশন" সরিয়ে authenticated encryption। রেফারেন্স ইমপ্লিমেন্টেশন ও
// টেস্ট ভেক্টর: windows_server/secure_channel_ref.py — C# পাশের নকল
// windows_server/AirCanvasServer.cs এর SecureChannel ক্লাসে।
//
// ওয়্যার ফরম্যাট:
//   sealed frame = IV(16) || CT(16*n) || TAG(16)        // সর্বনিম্ন ৪৮ বাইট
//   plaintext    = SEQ(4, big-endian) || payload
//   CT           = AES-256-CBC(encKey, IV, PKCS7(plaintext))
//   TAG          = HMAC-SHA256(macKey, IV || CT)[0..16]
//
// Encrypt-then-MAC — MAC আগে যাচাই, না মিললে decrypt-ই হয় না, তাই padding oracle নেই।
// প্রতিটি দিকের নিজস্ব key, তাই সার্ভারের পাঠানো ফ্রেম সার্ভারেই ফেরত পাঠিয়ে
// (reflection) কিছু করা যায় না। SEQ কড়াকড়িভাবে বাড়তে হয়, তাই replay বাতিল।
//
// কেন GCM নয়: স্ট্যান্ডঅ্যালোন C# সার্ভার build_windows_exe.bat দিয়ে .NET
// Framework 4.0 এর csc.exe তে কম্পাইল হয়, যেখানে AesGcm ক্লাসই নেই। CBC + HMAC
// (Encrypt-then-MAC) সেখানে নেটিভভাবে পাওয়া যায় এবং নিরাপত্তার দিক থেকে সমতুল্য।

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart' as pc;

/// Web প্ল্যাটফর্মে dart:isolate সমর্থিত নয় — এই ফ্ল্যাগ দিয়ে নিরাপদ ফলব্যাক করা হয়।
const bool _kIsWeb = identical(0, 0.0);

/// একটি authenticated, replay-প্রতিরোধী চ্যানেল — একটি WebSocket কানেকশনের জন্য একটি।
class SecureChannel {
  static const int ivLength = 16;
  static const int tagLength = 16;
  static const int seqLength = 4;

  /// এর চেয়ে ছোট ফ্রেম কখনোই বৈধ নয় (IV + অন্তত এক ব্লক CT + TAG)।
  static const int minFrameLength = ivLength + 16 + tagLength;

  /// PIN থেকে key বানানোর খরচ (2048 iterations ensures sub-50ms instant pairing on mobile).
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

  /// কতগুলো ফ্রেম MAC/replay চেকে বাতিল হয়েছে — UI তে দেখানোর জন্য।
  int rejectedFrames = 0;

  SecureChannel._(this._sendEnc, this._sendMac, this._recvEnc, this._recvMac);

  /// [sessionKey] ঠিক ৩২ বাইট। [isServer] দিয়ে কোন দিকের key কোনটা তা ঠিক হয়।
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

  /// PIN + salt থেকে সরাসরি চ্যানেল — কেবল session key মোড়ানো/খোলার জন্য।
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

  /// ক্রিপ্টোগ্রাফিকভাবে নিরাপদ র‍্যান্ডম বাইট।
  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (int i = 0; i < length; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  static Uint8List generateSessionKey() => randomBytes(32);

  static Uint8List generateSalt() => randomBytes(pbkdf2SaltLength);

  /// PBKDF2-HMAC-SHA1। SHA1 বেছে নেওয়ার কারণ interop: .NET Framework 4.0 এর
  /// Rfc2898DeriveBytes কেবল HMAC-SHA1 সাপোর্ট করে (SHA256 ওভারলোড 4.7.2 তে এসেছে)।
  /// PBKDF2-এর ভিতরে HMAC-SHA1 এখনও নিরাপদ — WPA2-ও এটাই ব্যবহার করে।
  static Uint8List derivePinKey(String pin, List<int> salt,
      {int iterations = pbkdf2Iterations}) {
    final derivator = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA1Digest(), 64))
      ..init(pc.Pbkdf2Parameters(Uint8List.fromList(salt), iterations, 32));
    return derivator.process(Uint8List.fromList(utf8.encode(pin)));
  }

  /// [payload] এনক্রিপ্ট + authenticate করে ওয়্যারে পাঠানোর ফ্রেম বানায়।
  /// [iv] ও [seq] কেবল টেস্ট ভেক্টর মেলানোর জন্য — আসল ব্যবহারে দেবেন না।
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

  /// ফ্রেম যাচাই করে payload ফেরত দেয়। বাতিল হলে null — টেম্পার, ভুল key,
  /// অথবা replay। কানেকশন বন্ধ করার দরকার নেই, ফ্রেমটা ফেলে দিলেই হয়।
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
      rejectedFrames++; // replay অথবা পুরনো ফ্রেম
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
    final pad = 16 - (data.length % 16); // ১..১৬, কখনো ০ নয়
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

  /// দৈর্ঘ্য ও কনটেন্ট constant-time এ তুলনা — timing দিয়ে tag অনুমান আটকায়।
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// pairing-এর সময় সার্ভার session key এভাবে ঢেকে পাঠায় (server → client দিক)।
/// PIN থেকে PBKDF2 দিয়ে key আসে, তাই আড়ি পাতা কেউ session key পেতে চাইলে
/// PIN brute-force করতে হবে — প্রতি চেষ্টায় ১ লাখ PBKDF2 ইটারেশন।
Uint8List wrapSessionKey(List<int> sessionKey, String pin, List<int> salt,
    {int iterations = SecureChannel.pbkdf2Iterations, Uint8List? iv}) {
  final wrapper =
      SecureChannel.fromPin(pin, salt, isServer: true, iterations: iterations);
  return wrapper.seal(sessionKey, iv: iv, seq: 1);
}

/// ক্লায়েন্ট পাশে খোলা। null মানে PIN ভুল (MAC মেলেনি) বা ডেটা নষ্ট।
Uint8List? unwrapSessionKey(List<int> wrapped, String pin, List<int> salt,
    {int iterations = SecureChannel.pbkdf2Iterations}) {
  final wrapper =
      SecureChannel.fromPin(pin, salt, isServer: false, iterations: iterations);
  final key = wrapper.open(wrapped);
  if (key == null || key.length != 32) return null;
  return key;
}

// ---------------------------------------------------------------------------
// PBKDF2 আলাদা isolate এ
//
// pointycastle পুরোটাই Dart-এ লেখা, native নয়। ১ লাখ HMAC-SHA1 ইটারেশন মানে
// ~২ লাখ SHA1 কম্প্রেশন — ডেস্কটপে কয়েকশ মিলিসেকেন্ড, ফোনে কয়েক সেকেন্ডও
// হতে পারে। pairing-এর সময় এটা UI isolate-এ সিঙ্ক্রোনাসলি চললে অ্যাপ পুরো
// সময়টা জমে থাকে, ইউজারের কাছে "কানেক্ট হচ্ছে না" মনে হয়। তাই ভারী অংশটা
// Isolate.run দিয়ে সরিয়ে দেওয়া হলো — ফলাফল হুবহু একই, কেবল UI থ্রেড খালি থাকে।
//
// এগুলো কেবল pairing-এ একবার চলে; প্রতি প্যাকেটের seal/open UI isolate-এই
// থাকে, কারণ সেটা মাইক্রোসেকেন্ডের কাজ আর isolate hop-এর খরচই বেশি হয়ে যেত।
// ---------------------------------------------------------------------------

/// [wrapSessionKey] এর isolate সংস্করণ (সার্ভার পাশে ব্যবহার)।
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

/// [unwrapSessionKey] এর isolate সংস্করণ (ক্লায়েন্ট পাশে ব্যবহার)।
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



