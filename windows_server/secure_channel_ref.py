#!/usr/bin/env python3
"""
AirCanvas Secure Channel v2 — রেফারেন্স ইমপ্লিমেন্টেশন ও টেস্ট ভেক্টর জেনারেটর।

এই ফাইলটাই wire format-এর "সত্য"। Dart (lib/services/secure_channel.dart) আর
C# (windows_server/AirCanvasServer.cs → SecureChannel) দুটোই এর হুবহু নকল হতে হবে।
স্যান্ডবক্সে dart/csc নেই, তাই দুই পাশের কোড লেখার আগে ফরম্যাটটা এখানে চালিয়ে
যাচাই করা হয়েছে এবং নিচে টেস্ট ভেক্টর ছাপানো হয় — ওগুলো Dart ইউনিট টেস্টে বসানো আছে।

ফরম্যাট (v2):
  sealed frame = IV(16) || CT(16*n) || TAG(16)          # সর্বনিম্ন ৪৮ বাইট
  plaintext    = SEQ(4, big-endian) || payload
  CT           = AES-256-CBC(encKey, IV, PKCS7(plaintext))
  TAG          = HMAC-SHA256(macKey, IV || CT)[0:16]
  encKey       = SHA256(label_enc || K)
  macKey       = SHA256(label_mac || K)

দিক অনুযায়ী আলাদা key (reflection attack আটকায়):
  ক্লায়েন্ট → সার্ভার : "AirCanvas-c2s-enc-v2" / "AirCanvas-c2s-mac-v2"
  সার্ভার → ক্লায়েন্ট : "AirCanvas-s2c-enc-v2" / "AirCanvas-s2c-mac-v2"

Encrypt-then-MAC: MAC আগে যাচাই হয়, না মিললে decrypt-ই করা হয় না →
padding oracle নেই।
"""
import hashlib
import hmac
import os

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

IV_LEN = 16
TAG_LEN = 16
SEQ_LEN = 4
MIN_FRAME = IV_LEN + 16 + TAG_LEN  # 48

PBKDF2_ITERATIONS = 100000
PBKDF2_SALT_LEN = 16

C2S_ENC = b"AirCanvas-c2s-enc-v2"
C2S_MAC = b"AirCanvas-c2s-mac-v2"
S2C_ENC = b"AirCanvas-s2c-enc-v2"
S2C_MAC = b"AirCanvas-s2c-mac-v2"


def derive(label: bytes, key: bytes) -> bytes:
    return hashlib.sha256(label + key).digest()


def pkcs7_pad(data: bytes) -> bytes:
    n = 16 - (len(data) % 16)
    return data + bytes([n]) * n


def pkcs7_unpad(data: bytes):
    """None ফেরালে padding অবৈধ।"""
    if not data or len(data) % 16 != 0:
        return None
    n = data[-1]
    if n < 1 or n > 16 or n > len(data):
        return None
    if data[-n:] != bytes([n]) * n:
        return None
    return data[:-n]


def aes_cbc_encrypt(key: bytes, iv: bytes, data: bytes) -> bytes:
    c = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return c.update(data) + c.finalize()


def aes_cbc_decrypt(key: bytes, iv: bytes, data: bytes) -> bytes:
    c = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    return c.update(data) + c.finalize()


def pin_key(pin: str, salt: bytes, iterations: int = PBKDF2_ITERATIONS) -> bytes:
    """PBKDF2-HMAC-SHA1 — .NET Framework 4.0 এর Rfc2898DeriveBytes এটাই ব্যবহার করে,
    তাই interop-এর জন্য SHA1 বাধ্যতামূলক। PBKDF2-এর ভিতরে HMAC-SHA1 এখনও ভাঙা নয়।"""
    return hashlib.pbkdf2_hmac("sha1", pin.encode("utf-8"), salt, iterations, 32)


class SecureChannel:
    def __init__(self, session_key: bytes, is_server: bool):
        if len(session_key) != 32:
            raise ValueError("session key must be 32 bytes")
        if is_server:
            self.send_enc, self.send_mac = derive(S2C_ENC, session_key), derive(S2C_MAC, session_key)
            self.recv_enc, self.recv_mac = derive(C2S_ENC, session_key), derive(C2S_MAC, session_key)
        else:
            self.send_enc, self.send_mac = derive(C2S_ENC, session_key), derive(C2S_MAC, session_key)
            self.recv_enc, self.recv_mac = derive(S2C_ENC, session_key), derive(S2C_MAC, session_key)
        self.send_seq = 0
        self.last_recv_seq = 0

    def seal(self, payload: bytes, iv: bytes = None, seq: int = None) -> bytes:
        if seq is None:
            self.send_seq += 1
            seq = self.send_seq
        if iv is None:
            iv = os.urandom(IV_LEN)
        pt = seq.to_bytes(SEQ_LEN, "big") + payload
        ct = aes_cbc_encrypt(self.send_enc, iv, pkcs7_pad(pt))
        tag = hmac.new(self.send_mac, iv + ct, hashlib.sha256).digest()[:TAG_LEN]
        return iv + ct + tag

    def open(self, frame: bytes):
        """None ফেরালে প্যাকেট বাতিল (tamper / replay / ভুল key)। কানেকশন বন্ধ করার
        দরকার নেই — শুধু ড্রপ, কারণ WiFi-তে corrupt ফ্রেম আসতে পারে।"""
        if frame is None or len(frame) < MIN_FRAME:
            return None
        if (len(frame) - IV_LEN - TAG_LEN) % 16 != 0:
            return None
        iv = frame[:IV_LEN]
        ct = frame[IV_LEN:-TAG_LEN]
        tag = frame[-TAG_LEN:]
        expect = hmac.new(self.recv_mac, iv + ct, hashlib.sha256).digest()[:TAG_LEN]
        if not hmac.compare_digest(tag, expect):
            return None
        pt = pkcs7_unpad(aes_cbc_decrypt(self.recv_enc, iv, ct))
        if pt is None or len(pt) < SEQ_LEN:
            return None
        seq = int.from_bytes(pt[:SEQ_LEN], "big")
        if seq <= self.last_recv_seq:
            return None  # replay বা out-of-order — বাতিল
        self.last_recv_seq = seq
        return pt[SEQ_LEN:]


def wrap_session_key(session_key: bytes, pin: str, salt: bytes, iv: bytes = None) -> bytes:
    """সার্ভার auth_success-এ session key এভাবে ঢেকে পাঠায় (server → client দিক)।"""
    ch = SecureChannel(pin_key(pin, salt), is_server=True)
    return ch.seal(session_key, iv=iv, seq=1)


def unwrap_session_key(wrapped: bytes, pin: str, salt: bytes):
    ch = SecureChannel(pin_key(pin, salt), is_server=False)
    return ch.open(wrapped)
