#!/usr/bin/env python3
"""
Secure Channel v2 এর টেস্ট + Dart/C# এর জন্য টেস্ট ভেক্টর ছাপায়।
চালান:  python3 windows_server/secure_channel_test.py
"""
import base64
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from secure_channel_ref import (  # noqa: E402
    MIN_FRAME, SecureChannel, pin_key, pkcs7_pad, pkcs7_unpad,
    unwrap_session_key, wrap_session_key,
)

fails = []


def check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    if not cond:
        fails.append(name)


def build_input_packet(tb, x, y, pressure):
    """Dart InputEvent.toBinary() এর নকল (13 বাইট)।"""
    xi = int(round(x * 65535))
    yi = int(round(y * 65535))
    b = [tb, (xi >> 8) & 0xFF, xi & 0xFF, (yi >> 8) & 0xFF, yi & 0xFF,
         int(round(pressure * 255)), 1, 0, 128, 128, 1, 1]
    b.append(sum(b) & 0xFF)
    return bytes(b)


SESSION_KEY = bytes(range(32))            # নির্দিষ্ট key → reproducible ভেক্টর
FIXED_IV = bytes(range(0x10, 0x20))
PIN = "428913"
SALT = bytes(range(0x40, 0x50))

print("1) roundtrip: ক্লায়েন্ট seal → সার্ভার open")
client = SecureChannel(SESSION_KEY, is_server=False)
server = SecureChannel(SESSION_KEY, is_server=True)
pkt = build_input_packet(1, 0.25, 0.75, 0.5)
frame = client.seal(pkt)
check("13-বাইট ইনপুট → 64-বাইট ফ্রেম", len(frame) == 64)
check("সার্ভার হুবহু payload ফিরে পেয়েছে", server.open(frame) == pkt)

print("2) দুই দিকই কাজ করে (server → client)")
back = server.seal(b'{"type":"pong","ts":7}')
check("ক্লায়েন্ট server→client ফ্রেম খুলতে পেরেছে",
      client.open(back) == b'{"type":"pong","ts":7}')

print("3) reflection: server→client ফ্রেম সার্ভারে ফেরত পাঠালে বাতিল")
srv2 = SecureChannel(SESSION_KEY, is_server=True)
check("নিজের পাঠানো ফ্রেম নিজে খুলতে পারে না", srv2.open(server.seal(b"hello")) is None)

print("4) replay: একই ফ্রেম দুইবার")
c, s = SecureChannel(SESSION_KEY, False), SecureChannel(SESSION_KEY, True)
f = c.seal(pkt)
check("প্রথমবার গৃহীত", s.open(f) == pkt)
check("দ্বিতীয়বার বাতিল (replay)", s.open(f) is None)

print("5) tamper: এক বিট বদলালে")
c, s = SecureChannel(SESSION_KEY, False), SecureChannel(SESSION_KEY, True)
f = bytearray(c.seal(pkt))
f[20] ^= 0x01                       # ciphertext-এ এক বিট
check("ciphertext বদলালে বাতিল", s.open(bytes(f)) is None)
f = bytearray(c.seal(pkt))
f[2] ^= 0x80                        # IV-তে এক বিট
check("IV বদলালে বাতিল (MAC IV-ও ঢাকে)", s.open(bytes(f)) is None)
f = bytearray(c.seal(pkt))
f[-1] ^= 0x01                       # tag
check("tag বদলালে বাতিল", s.open(bytes(f)) is None)

print("6) ভুল key")
c = SecureChannel(SESSION_KEY, False)
s = SecureChannel(os.urandom(32), True)
check("অন্য key এর ফ্রেম বাতিল", s.open(c.seal(pkt)) is None)

print("7) দৈর্ঘ্য সীমা")
s = SecureChannel(SESSION_KEY, True)
check("খালি ফ্রেম বাতিল", s.open(b"") is None)
check("পুরনো 13-বাইট XOR প্যাকেট বাতিল", s.open(pkt) is None)
check("47 বাইট বাতিল", s.open(os.urandom(MIN_FRAME - 1)) is None)
check("block-এর গুণিতক না হলে বাতিল", s.open(os.urandom(MIN_FRAME + 3)) is None)

print("8) PKCS7 padding")
check("pad/unpad roundtrip", pkcs7_unpad(pkcs7_pad(b"abc")) == b"abc")
check("ঠিক এক ব্লক ইনপুটে পুরো ব্লক padding",
      len(pkcs7_pad(b"x" * 16)) == 32 and pkcs7_unpad(pkcs7_pad(b"x" * 16)) == b"x" * 16)
check("অবৈধ padding ধরা পড়ে", pkcs7_unpad(bytes(15) + b"\x11") is None)

print("9) session key wrap (PIN pairing)")
wrapped = wrap_session_key(SESSION_KEY, PIN, SALT)
check("সঠিক PIN দিয়ে key উদ্ধার", unwrap_session_key(wrapped, PIN, SALT) == SESSION_KEY)
check("ভুল PIN দিলে None (MAC ফেল)", unwrap_session_key(wrapped, "000000", SALT) is None)
check("ভুল salt দিলে None", unwrap_session_key(wrapped, PIN, os.urandom(16)) is None)
check("wrapped দৈর্ঘ্য 16+48+16 = 80", len(wrapped) == 80)

print("10) বড় payload (JSON device_info)")
c, s = SecureChannel(SESSION_KEY, False), SecureChannel(SESSION_KEY, True)
big = json.dumps({"type": "device_info", "data": {"deviceName": "Galaxy Tab S9 Ultra",
                  "screenWidth": 2960.0, "screenHeight": 1848.0}}).encode()
check("বড় JSON roundtrip", s.open(c.seal(big)) == big)

print("11) seq বাড়তেই থাকে, ফ্রেম প্রতিবার আলাদা")
c, s = SecureChannel(SESSION_KEY, False), SecureChannel(SESSION_KEY, True)
frames = [c.seal(pkt) for _ in range(200)]
check("সব ফ্রেম ইউনিক (random IV)", len({bytes(f) for f in frames}) == 200)
check("ধারাক্রমে সব গৃহীত", all(s.open(f) == pkt for f in frames))
check("send_seq == 200", c.send_seq == 200)

print()
print("=" * 64)
print("Dart/C# এর জন্য টেস্ট ভেক্টর (নির্দিষ্ট key ও IV)")
print("=" * 64)
c = SecureChannel(SESSION_KEY, is_server=False)
vec = c.seal(pkt, iv=FIXED_IV, seq=1)
print("sessionKey (hex)  : " + SESSION_KEY.hex())
print("c2s encKey (hex)  : " + c.send_enc.hex())
print("c2s macKey (hex)  : " + c.send_mac.hex())
print("s2c encKey (hex)  : " + c.recv_enc.hex())
print("s2c macKey (hex)  : " + c.recv_mac.hex())
print("IV (hex)          : " + FIXED_IV.hex())
print("seq               : 1")
print("payload (hex)     : " + pkt.hex())
print("sealed frame (hex): " + vec.hex())
print()
print("PIN               : " + PIN)
print("salt (hex)        : " + SALT.hex())
print("pinKey (hex)      : " + pin_key(PIN, SALT).hex())
wv = wrap_session_key(SESSION_KEY, PIN, SALT, iv=FIXED_IV)
print("wrapped key (b64) : " + base64.b64encode(wv).decode())
print()

if fails:
    print("FAILED: %d" % len(fails))
    for f in fails:
        print(" - " + f)
    raise SystemExit(1)
print("সব চেক পাস করেছে।")
