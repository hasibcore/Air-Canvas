// Unit tests for Secure Channel v2.
//
// Test vectors generated from windows_server/secure_channel_ref.py (reference
// implementation). Passing these vectors guarantees identical byte-level
// interop across Dart, Python, and C#.
//
// Run: flutter test test/secure_channel_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:air_canvas/services/secure_channel.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Reference vectors - output from secure_channel_ref.py
const String kSessionKeyHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const String kIvHex = '101112131415161718191a1b1c1d1e1f';
const String kPayloadHex = '014000bfff8001008080010182';
const String kSealedHex =
    '101112131415161718191a1b1c1d1e1f'
    '8a63d20ef35249fbb1e07cf04d2c1cde24ac25321d89b259a19794b885dd5fa2'
    '48d0ab9d77500c1633ac328caa52dc70';
const String kC2sEncHex =
    '8e445588d8dd168d930f4c5a31d84796cc21b30feda1a1b450b7de13f21adc36';
const String kC2sMacHex =
    'c7381c0759b807c7e19244e6ce1ab000a5734d0473d7e330ae031c4184364c1c';
const String kPin = '428913';
const String kSaltHex = '404142434445464748494a4b4c4d4e4f';
const String kPinKeyHex =
    '94c2cbec4806e65f189441827e62a1e2c13b44eebf6dfe97a69bf66ceff3c56d';
const String kWrappedKeyB64 =
    'EBESExQVFhcYGRobHB0eHygNlEVgt32Q76vVCDRK8gscFtrtlBAfed15Lk3Fi/uknhexhWL1b+rm'
    'tw719tzkP39RGoi3lCTwZsnGTdWlxfo=';

void main() {
  final sessionKey = hex(kSessionKeyHex);
  final payload = hex(kPayloadHex);

  group('Test vectors (Byte-level match with Python/C#)', () {
    test('seal() matches reference frame exactly', () {
      final client = SecureChannel(sessionKey, isServer: false);
      final frame = client.seal(payload, iv: hex(kIvHex), seq: 1);
      expect(toHex(frame), kSealedHex);
    });

    test('Reference frame opens successfully on server side', () {
      final server = SecureChannel(sessionKey, isServer: true);
      expect(server.open(hex(kSealedHex)), payload);
    });

    test('PBKDF2 PIN key matches reference', () {
      expect(toHex(SecureChannel.derivePinKey(kPin, hex(kSaltHex), iterations: 100000)), kPinKeyHex);
    });

    test('Reference wrapped session key unwraps successfully', () {
      final got = unwrapSessionKey(
          base64Decode(kWrappedKeyB64), kPin, hex(kSaltHex), iterations: 100000);
      expect(got, sessionKey);
    });
  });

  group('roundtrip', () {
    test('13-byte input event -> 64-byte frame -> exact roundtrip', () {
      final c = SecureChannel(sessionKey, isServer: false);
      final s = SecureChannel(sessionKey, isServer: true);
      final frame = c.seal(payload);
      expect(frame.length, 64);
      expect(s.open(frame), payload);
    });

    test('server -> client direction roundtrips', () {
      final c = SecureChannel(sessionKey, isServer: false);
      final s = SecureChannel(sessionKey, isServer: true);
      final msg = utf8.encode('{"type":"pong","ts":7}');
      expect(c.open(s.seal(msg)), msg);
    });

    test('Large JSON payload roundtrips', () {
      final c = SecureChannel(sessionKey, isServer: false);
      final s = SecureChannel(sessionKey, isServer: true);
      final msg = utf8.encode(jsonEncode({
        'type': 'device_info',
        'data': {'deviceName': 'Galaxy Tab S9 Ultra', 'screenWidth': 2960.0}
      }));
      expect(s.open(c.seal(msg)), msg);
    });

    test('200 sequential frames - all unique and all accepted', () {
      final c = SecureChannel(sessionKey, isServer: false);
      final s = SecureChannel(sessionKey, isServer: true);
      final seen = <String>{};
      for (int i = 0; i < 200; i++) {
        final f = c.seal(payload);
        seen.add(toHex(f));
        expect(s.open(f), payload);
      }
      expect(seen.length, 200, reason: 'Each frame must have fresh random IV');
      expect(c.sendSequence, 200);
    });
  });

  group('Attack mitigation', () {
    test('Replay attack - duplicate frame rejected', () {
      final c = SecureChannel(sessionKey, isServer: false);
      final s = SecureChannel(sessionKey, isServer: true);
      final f = c.seal(payload);
      expect(s.open(f), payload);
      expect(s.open(f), isNull);
    });

    test('Reflection attack - server frame reflected to server rejected', () {
      final s1 = SecureChannel(sessionKey, isServer: true);
      final s2 = SecureChannel(sessionKey, isServer: true);
      expect(s2.open(s1.seal(payload)), isNull);
    });

    test('Tamper attack - single bit flipped in ciphertext / IV / tag rejected', () {
      for (final idx in <int>[2, 20, 63]) {
        final c = SecureChannel(sessionKey, isServer: false);
        final s = SecureChannel(sessionKey, isServer: true);
        final f = c.seal(payload);
        f[idx] ^= 0x01;
        expect(s.open(f), isNull, reason: 'Byte $idx was modified');
      }
    });

    test('Frame encrypted with mismatched key is rejected', () {
      final c = SecureChannel(SecureChannel.generateSessionKey(), isServer: false);
      final s = SecureChannel(sessionKey, isServer: true);
      expect(s.open(c.seal(payload)), isNull);
    });

    test('Session key cannot be unwrapped with incorrect PIN', () {
      final salt = SecureChannel.generateSalt();
      final wrapped = wrapSessionKey(sessionKey, '123456', salt);
      expect(unwrapSessionKey(wrapped, '123456', salt), sessionKey);
      expect(unwrapSessionKey(wrapped, '654321', salt), isNull);
      expect(unwrapSessionKey(wrapped, '123456', SecureChannel.generateSalt()),
          isNull);
    });

    test('Legacy 13-byte XOR packets are rejected', () {
      final s = SecureChannel(sessionKey, isServer: true);
      expect(s.open(payload), isNull);
      expect(s.open(Uint8List(0)), isNull);
      expect(s.open(Uint8List(SecureChannel.minFrameLength - 1)), isNull);
      expect(s.open(Uint8List(SecureChannel.minFrameLength + 3)), isNull);
    });

    test('Rejected frames counter tracks dropped frames', () {
      final s = SecureChannel(sessionKey, isServer: true);
      s.open(Uint8List(10));
      s.open(Uint8List(64));
      expect(s.rejectedFrames, 2);
    });
  });

  group('Performance benchmark', () {
    test('seal + open pair averages far below 1 millisecond', () {
      final c = SecureChannel(sessionKey, isServer: false);
      final s = SecureChannel(sessionKey, isServer: true);
      const iterations = 2000;
      final sw = Stopwatch()..start();
      for (int i = 0; i < iterations; i++) {
        s.open(c.seal(payload));
      }
      sw.stop();
      final perPair = sw.elapsedMicroseconds / iterations;
      // At 120 Hz stroke rate, budget is 8333 µs per packet
      expect(perPair, lessThan(1000),
          reason: 'Took ${perPair.toStringAsFixed(1)} µs per pair');
    });
  });
}
