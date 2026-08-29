#!/usr/bin/env python3
"""
AirCanvasServer.cs এর auth gate + Secure Channel v2 হ্যান্ডশেকের সিমুলেশন।

এই স্যান্ডবক্সে csc.exe/mono নেই, তাই C# লজিকটা Python-এ হুবহু নকল করে
Dart ক্লায়েন্টের আসল বাইট সিকোয়েন্স দিয়ে যাচাই করা হয়। ক্রিপ্টো অংশ
secure_channel_ref.py থেকেই আসে — অর্থাৎ সিমুলেশন আর আসল কোড একই ফরম্যাটে।

যা যা এখানে যাচাই হয়:
  • ভুল PIN → কানেকশন বন্ধ, কোনো key যায় না
  • auth ছাড়া বাইনারি/JSON ইনপুট → inject হয় না
  • সঠিক PIN → PBKDF2-wrapped session key → sealed ইনপুট inject হয়
  • পুরনো ১৩ বাইট XOR প্যাকেট আর গৃহীত হয় না (ডাউনগ্রেড আটকানো)
  • replay / tamper / ভুল key → ফ্রেম ড্রপ, কানেকশন টেকে
  • পরপর ৫ বার ভুল PIN → ৩০ সেকেন্ড lockout, তখন সঠিক PIN-ও বাতিল

চালান:  python3 windows_server/authgate_sim.py
"""
import base64
import json
import os
import secrets
import time

from secure_channel_ref import (
    MIN_FRAME,
    PBKDF2_ITERATIONS,
    PBKDF2_SALT_LEN,
    SecureChannel,
    unwrap_session_key,
    wrap_session_key,
)

# C# এর AuthFailuresBeforeLockout / AuthLockoutSeconds এর হুবহু মান
AUTH_FAILURES_BEFORE_LOCKOUT = 5
AUTH_LOCKOUT_SECONDS = 30


def generate_pairing_pin() -> str:
    """C# GeneratePairingPin() এর নকল — RNG থেকে ৬ ডিজিট, modulo bias ছাড়া।"""
    out = []
    while len(out) < 6:
        b = secrets.token_bytes(1)[0]
        if b >= 250:          # ২৫০..২৫৫ ফেলে দিলে ০-৯ সমান সম্ভাবনার হয়
            continue
        out.append(str(b % 10))
    return "".join(out)


def is_valid_binary_packet(d: bytes) -> bool:
    """C# IsValidBinaryPacket() — ১৩ বাইট, টাইপ ০..৫, additive checksum।"""
    if d is None or len(d) != 13:
        return False
    if d[0] > 5:
        return False
    return (sum(d[:12]) & 0xFF) == d[12]


def fixed_time_equals(a: bytes, b: bytes) -> bool:
    if a is None or b is None or len(a) != len(b):
        return False
    diff = 0
    for x, y in zip(a, b):
        diff |= x ^ y
    return diff == 0


def extract_json_string(s: str, key: str):
    """C# ExtractJsonString() — হাতে লেখা ছোট JSON স্ক্যানার, হুবহু একই আচরণ।"""
    needle = '"%s"' % key
    k = s.find(needle)
    if k == -1:
        return None
    colon = s.find(':', k + len(needle))
    if colon == -1:
        return None
    start = s.find('"', colon + 1)
    if start == -1:
        return None
    end = s.find('"', start + 1)
    if end <= start:
        return None
    return s[start + 1:end]


def build_input_packet(tb, x, y, pressure) -> bytes:
    """Dart InputEvent.toBinary() এর হুবহু নকল (১৩ বাইট, big-endian)।"""
    xi = int(round(x * 65535))
    yi = int(round(y * 65535))
    b = [tb, (xi >> 8) & 0xFF, xi & 0xFF, (yi >> 8) & 0xFF, yi & 0xFF,
         int(round(pressure * 255)), 1, 0, 128, 128, 1, 1]
    b.append(sum(b) & 0xFF)
    return bytes(b)


class Session:
    """C# ClientSession — প্রতি TCP কানেকশনের নিজস্ব auth ও crypto state।"""

    def __init__(self):
        self.authenticated = False
        self.channel = None


class Server:
    """AirCanvasServer এর নেটওয়ার্ক-বিহীন নকল। sent/injected লিস্টে ফলাফল জমে।"""

    def __init__(self, pin=None):
        self.pin = pin or generate_pairing_pin()
        self.consecutive_failures = 0
        self.lockout_until = 0.0
        self.rejected_auth_attempts = 0
        self.injected = []      # inject হওয়া ইনপুট ইভেন্ট
        self.sent = []          # ("text", str) বা ("bin", bytes)

    # ---------- brute-force throttle (C# IsAuthLockedOut / Register*) ----------
    def is_locked_out(self) -> bool:
        return time.time() < self.lockout_until

    def register_auth_failure(self):
        self.consecutive_failures += 1
        if self.consecutive_failures >= AUTH_FAILURES_BEFORE_LOCKOUT:
            self.lockout_until = time.time() + AUTH_LOCKOUT_SECONDS
            self.consecutive_failures = 0

    def register_auth_success(self):
        self.consecutive_failures = 0
        self.lockout_until = 0.0

    # ---------- আউটবাউন্ড ----------
    def send_text(self, t: str):
        """SendWebSocketText — কেবল handshake এর সময়, auth এর পরে আর নয়।"""
        self.sent.append(("text", t))

    def send_secure_json(self, session: Session, obj):
        """C# SendSecureJson — auth এর পরে সব JSON sealed বাইনারি ফ্রেমে যায়।"""
        if session is None or session.channel is None:
            return
        payload = json.dumps(obj, separators=(',', ':')).encode()
        self.sent.append(("bin", session.channel.seal(payload)))

    # ---------- ইনবাউন্ড ----------
    def process_json(self, js: str, session: Session) -> bool:
        """C# ProcessJsonMessage — False মানে কানেকশন বন্ধ করতে হবে।"""
        if '"type":"auth_response"' in js or '"type":"auth"' in js:
            if self.is_locked_out():
                self.send_text('{"type":"auth_fail","reason":'
                               '"Too many failed attempts, try again later"}')
                return False

            client_pin = extract_json_string(js, "pin")
            if (client_pin is None or self.pin is None or self.pin == "------"
                    or not fixed_time_equals(client_pin.encode(), self.pin.encode())):
                session.authenticated = False
                session.channel = None
                self.rejected_auth_attempts += 1
                self.register_auth_failure()
                self.send_text('{"type":"auth_fail","reason":"Incorrect pairing PIN"}')
                return False

            self.register_auth_success()
            key = os.urandom(32)
            salt = os.urandom(PBKDF2_SALT_LEN)
            wrapped = wrap_session_key(key, self.pin, salt)
            # auth_success এখনো প্লেইনটেক্সট — ভিতরের key PIN দিয়ে ঢাকা,
            # তাই passive শ্রোতা key পায় না (আগে পেত)।
            self.send_text(json.dumps({
                "type": "auth_success",
                "kx": "v2",
                "salt": base64.b64encode(salt).decode(),
                "iterations": PBKDF2_ITERATIONS,
                "wrapped_key": base64.b64encode(wrapped).decode(),
            }, separators=(',', ':')))
            session.channel = SecureChannel(key, is_server=True)
            session.authenticated = True
            return True

        if not session.authenticated:
            self.send_text('{"type":"auth_fail","reason":"Not authenticated"}')
            return False

        if '"type":"device_info"' in js:
            self.send_secure_json(session, {"type": "server_config",
                                            "data": {"port": 9090, "binary": True}})
        elif '"type":"input"' in js:
            self.injected.append(("json-input",))
        elif '"type":"ping"' in js:
            self.send_secure_json(session, {"type": "pong", "ts": 0})
        return True

    def process_binary(self, data: bytes, session: Session) -> bool:
        """C# ProcessBinaryPacket — সব বাইনারি ফ্রেম SecureChannel দিয়ে খুলতে হবে।"""
        if not session.authenticated or session.channel is None:
            self.send_text('{"type":"auth_fail","reason":"Not authenticated"}')
            return False
        if len(data) < 1:
            return True

        packet = session.channel.open(data)
        if packet is None:
            return True   # tamper / replay / ভুল key / পুরনো প্লেইন প্যাকেট — ড্রপ

        if len(packet) > 0 and packet[0:1] == b'{':
            return self.process_json(packet.decode('utf-8', 'replace'), session)
        if not is_valid_binary_packet(packet):
            return True
        if len(packet) < 6:
            return True

        tb = packet[0]
        etype = {0: "down", 1: "move", 2: "up", 3: "cancel", 5: "clear"}.get(tb, "move")
        if etype == "clear":
            self.injected.append(("clear",))
            return True
        x = ((packet[1] << 8) | packet[2]) / 65535.0
        y = ((packet[3] << 8) | packet[4]) / 65535.0
        p = packet[5] / 255.0
        self.injected.append((etype, round(x, 4), round(y, 4), round(p, 4)))
        return True


class Client:
    """Dart ConnectionProvider এর ক্লায়েন্ট পাশ — auth_success থেকে key উদ্ধার করে।"""

    def __init__(self, pin: str):
        self.pin = pin
        self.channel = None
        self.session_key = None

    def handle_auth_success(self, js: str) -> bool:
        j = json.loads(js)
        if j.get("kx") != "v2" or "wrapped_key" not in j or "salt" not in j:
            return False      # v1 সার্ভার — ডাউনগ্রেড প্রত্যাখ্যান
        key = unwrap_session_key(base64.b64decode(j["wrapped_key"]),
                                 self.pin, base64.b64decode(j["salt"]))
        if key is None or len(key) != 32:
            return False
        self.session_key = key
        self.channel = SecureChannel(key, is_server=False)
        return True


# ------------------------------- টেস্ট -------------------------------
fails = []


def check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    if not cond:
        fails.append(name)


def auth_msg(pin):
    return json.dumps({"type": "auth_response", "pin": pin}, separators=(',', ':'))


def wrong_pin(srv):
    """srv.pin এর থেকে নিশ্চিতভাবে ভিন্ন একটি ৬ ডিজিটের PIN।"""
    return "000000" if srv.pin != "000000" else "111111"


def paired():
    """সঠিক PIN দিয়ে পূর্ণ handshake — (server, session, client) ফেরায়।"""
    srv = Server()
    ses = Session()
    ok = srv.process_json(auth_msg(srv.pin), ses)
    cli = Client(srv.pin)
    kind, frame = srv.sent[-1]
    assert ok and kind == "text"
    assert cli.handle_auth_success(frame)
    return srv, ses, cli


print("১) ভুল PIN")
srv, ses = Server(), Session()
keep = srv.process_json(auth_msg(wrong_pin(srv)), ses)
check("কানেকশন বন্ধ হয়েছে", keep is False)
check("authenticated হয়নি", ses.authenticated is False)
check("channel তৈরি হয়নি", ses.channel is None)
check("auth_fail পাঠানো হয়েছে",
      any("auth_fail" in t for k, t in srv.sent if k == "text"))
check("কোনো wrapped_key ফাঁস হয়নি",
      not any("wrapped_key" in t for k, t in srv.sent if k == "text"))

print("২) auth ছাড়া সরাসরি valid বাইনারি ইনপুট (পুরনো আসল ফাঁক)")
srv, ses = Server(), Session()
keep = srv.process_binary(build_input_packet(0, 0.5, 0.5, 1.0), ses)
check("কানেকশন বন্ধ হয়েছে", keep is False)
check("কোনো ইনপুট inject হয়নি", srv.injected == [])

print("৩) auth ছাড়া plaintext JSON ইনপুট")
srv, ses = Server(), Session()
keep = srv.process_json('{"type":"input","data":{}}', ses)
check("কানেকশন বন্ধ হয়েছে", keep is False)
check("কোনো ইনপুট inject হয়নি", srv.injected == [])

print("৪) সঠিক PIN → v2 key exchange")
srv, ses = Server(), Session()
keep = srv.process_json(auth_msg(srv.pin), ses)
check("authenticated হয়েছে", keep is True and ses.authenticated)
kind, frame = srv.sent[-1]
check("auth_success প্লেইনটেক্সট টেক্সট ফ্রেমে গেছে", kind == "text")
aj = json.loads(frame)
check("kx=v2 বলা হয়েছে", aj.get("kx") == "v2")
check("পুরনো প্লেইন session_key আর নেই", "session_key" not in aj)
check("salt ১৬ বাইট", len(base64.b64decode(aj["salt"])) == PBKDF2_SALT_LEN)
check("iterations = %d" % PBKDF2_ITERATIONS, aj["iterations"] == PBKDF2_ITERATIONS)
wrapped = base64.b64decode(aj["wrapped_key"])
check("wrapped_key ৮০ বাইট (IV+CT+TAG)", len(wrapped) == 80)

cli = Client(srv.pin)
check("ক্লায়েন্ট সঠিক PIN দিয়ে key উদ্ধার করেছে", cli.handle_auth_success(frame))
check("ভুল PIN দিয়ে key উদ্ধার হয় না",
      Client(wrong_pin(srv)).handle_auth_success(frame) is False)
check("v1 handshake প্রত্যাখ্যাত (ডাউনগ্রেড আটকানো)",
      Client(srv.pin).handle_auth_success(
          '{"type":"auth_success","session_key":"AAAA"}') is False)

print("৫) sealed ইনপুট ইভেন্ট")
srv, ses, cli = paired()
pkt = build_input_packet(1, 0.25, 0.75, 0.5)
sealed = cli.channel.seal(pkt)
check("১৩ বাইট ইনপুট → ৬৪ বাইট ফ্রেম", len(sealed) == 64)
keep = srv.process_binary(sealed, ses)
check("inject হয়েছে", keep is True and len(srv.injected) == 1)
check("কোঅর্ডিনেট ও চাপ ঠিক আছে",
      srv.injected[0][0] == "move"
      and abs(srv.injected[0][1] - 0.25) < 0.001
      and abs(srv.injected[0][2] - 0.75) < 0.001
      and abs(srv.injected[0][3] - 0.5) < 0.01)

print("৬) sealed device_info → sealed server_config (ক্লায়েন্ট খুলতে পারে)")
srv, ses, cli = paired()
dev = json.dumps({"type": "device_info", "data": {"name": "Pixel"}},
                 separators=(',', ':')).encode()
keep = srv.process_binary(cli.channel.seal(dev), ses)
check("কানেকশন টিকে আছে", keep is True)
kind, reply = srv.sent[-1]
check("উত্তর sealed বাইনারিতে গেছে (প্লেইনটেক্সটে নয়)", kind == "bin")
opened = cli.channel.open(reply)
check("ক্লায়েন্ট server_config পড়তে পেরেছে",
      opened is not None and json.loads(opened)["type"] == "server_config")

print("৭) পুরনো ভার্সনের প্যাকেট আর গ্রহণযোগ্য নয়")
srv, ses, cli = paired()
raw13 = build_input_packet(0, 0.5, 0.5, 1.0)
check("প্লেইন ১৩ বাইট প্যাকেট ড্রপ", srv.process_binary(raw13, ses) is True)


def xor(data, key):
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


check("পুরনো XOR('1234') প্যাকেট ড্রপ",
      srv.process_binary(xor(raw13, b"1234"), ses) is True)
check("প্লেইন JSON বাইনারি ফ্রেম ড্রপ",
      srv.process_binary(b'{"type":"input","data":{}}', ses) is True)
check("MIN_FRAME এর চেয়ে ছোট ফ্রেম ড্রপ",
      srv.process_binary(bytes(MIN_FRAME - 1), ses) is True)
check("কোনোটাই inject হয়নি", srv.injected == [])

print("৮) replay / tamper / ভুল key")
srv, ses, cli = paired()
f = cli.channel.seal(build_input_packet(1, 0.4, 0.4, 0.9))
srv.process_binary(f, ses)
check("প্রথমবার গৃহীত", len(srv.injected) == 1)
srv.process_binary(f, ses)
check("একই ফ্রেম দ্বিতীয়বার বাতিল (replay)", len(srv.injected) == 1)

srv, ses, cli = paired()
for idx in (2, 20, 63):
    t = bytearray(cli.channel.seal(build_input_packet(1, 0.4, 0.4, 0.9)))
    t[idx] ^= 0x01
    srv.process_binary(bytes(t), ses)
check("এক বিট বদলালেই বাতিল (IV/CT/TAG)", srv.injected == [])

srv, ses, _ = paired()
other = SecureChannel(os.urandom(32), is_server=False)
keep = srv.process_binary(other.seal(build_input_packet(0, 0.1, 0.1, 1.0)), ses)
check("ভুল key এর ফ্রেম বাতিল", srv.injected == [])
check("তবু কানেকশন টিকে আছে (DoS হয় না)", keep is True)

srv, ses, cli = paired()
reflected = SecureChannel(cli.session_key, is_server=True)
srv.process_binary(reflected.seal(build_input_packet(0, 0.1, 0.1, 1.0)), ses)
check("একই key কিন্তু সার্ভার-দিকে সিল করা ফ্রেম বাতিল (reflection)",
      srv.injected == [])

print("৯) brute-force lockout")
srv = Server()
bad = wrong_pin(srv)
for i in range(AUTH_FAILURES_BEFORE_LOCKOUT):
    check("চেষ্টা %d বাতিল" % (i + 1),
          srv.process_json(auth_msg(bad), Session()) is False)
check("%d বার ভুলের পর lockout চালু" % AUTH_FAILURES_BEFORE_LOCKOUT,
      srv.is_locked_out())
ses = Session()
keep = srv.process_json(auth_msg(srv.pin), ses)
check("lockout চলাকালে সঠিক PIN-ও বাতিল", keep is False and not ses.authenticated)
check("lockout এর কারণ জানানো হয়েছে",
      any("Too many failed attempts" in t for k, t in srv.sent if k == "text"))
check("ভুল চেষ্টার গণনা ঠিক আছে",
      srv.rejected_auth_attempts == AUTH_FAILURES_BEFORE_LOCKOUT)

# lockout শেষ হওয়ার সময় এগিয়ে এনে (৩০ সেকেন্ড অপেক্ষা না করে) যাচাই
srv.lockout_until = time.time() - 0.001
ses = Session()
check("lockout শেষ হলে সঠিক PIN আবার কাজ করে",
      srv.process_json(auth_msg(srv.pin), ses) is True and ses.authenticated)
check("সফল auth এর পর lockout state পরিষ্কার",
      srv.consecutive_failures == 0 and not srv.is_locked_out())

print("১০) একটানা ২০০টি ফ্রেম")
srv, ses, cli = paired()
frames = set()
for i in range(200):
    fr = cli.channel.seal(build_input_packet(1, 0.5, 0.5, 1.0))
    frames.add(fr)
    srv.process_binary(fr, ses)
check("সব ২০০টি গৃহীত", len(srv.injected) == 200)
check("প্রতিটি ফ্রেম ইউনিক (random IV + seq)", len(frames) == 200)

print()
if fails:
    print("FAILED: %d" % len(fails))
    for f in fails:
        print(" - " + f)
    raise SystemExit(1)
print("সব চেক পাস করেছে।")
