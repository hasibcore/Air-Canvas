# -*- coding: utf-8 -*-
"""DrawingProvider এর palm-rejection / slot arbitration লজিকের রেফারেন্স মডেল।

`flutter test` এখানে চালানো যায় না, তাই lib/services/drawing_provider.dart এর
onPointerDown / onPointerMove / onPointerUp এর সিদ্ধান্ত-লজিক হাতে পোর্ট করে
র‍্যান্ডম পয়েন্টার-সিকোয়েন্স দিয়ে ফাজ করা হয়। যেসব ইনভ্যারিয়েন্ট চেক হয়:

  1. ওয়্যারে যাওয়া প্রতিটি pointerDown এর ঠিক একটা pointerUp জোড়া থাকে।
  2. কখনো একইসাথে একটার বেশি pointer "নামানো" অবস্থায় থাকে না (PC তে কার্সর
     একটাই, তাই দুটো down একসাথে গেলে বাটন চাপা থেকে যেত)।
  3. up সব সময় সেই স্লট নাম্বারেই যায় যেটায় তার down গিয়েছিল।
  4. পেন আঁকা অবস্থায় আঙুল/তালুর কোনো ইভেন্ট ওয়্যারে যায় না।
  5. সব pointer উঠে গেলে কিছুই চাপা থাকে না।
"""
import random
import sys

MAX_SLOTS = 16
GRACE_MS = 400
PEN_KINDS = ("stylus", "eraser")


def is_pen(kind):
    return kind in PEN_KINDS


class Model(object):
    def __init__(self, palm_rejection=True):
        self.palm_rejection = palm_rejection
        self.slots = {}            # rawId -> slot   (insertion ordered)
        self.slot_pos = {}         # slot -> pos
        self.kinds = {}            # rawId -> kind
        self.pending_up = {}       # rawId -> slot (down গেছে, up বাকি)
        self.drawing_pointer = None
        self.last_stylus_ms = None
        self.is_drawing = False
        self.has_stroke = False
        self.wire = []             # (type, rawId, slot)
        self.now = 0

    # --- helpers ---
    def _emit(self, kind, raw_id, slot):
        self.wire.append((kind, raw_id, slot))

    def _emit_up_for(self, raw_id):
        slot = self.pending_up.pop(raw_id, None)
        if slot is None:
            return
        self._emit("up", raw_id, slot)

    def _acquire_slot(self, raw_id):
        if raw_id in self.slots:
            return self.slots[raw_id]
        used = set(self.slots.values())
        for slot in range(MAX_SLOTS):
            if slot not in used:
                self.slots[raw_id] = slot
                return slot
        stalest = next(iter(self.slots))
        reclaimed = self.slots.pop(stalest)
        self._emit_up_for(stalest)
        self.slot_pos.pop(reclaimed, None)
        self.kinds.pop(stalest, None)
        if self.drawing_pointer == stalest:
            self.drawing_pointer = None
        self.slots[raw_id] = reclaimed
        return reclaimed

    def _release_slot(self, raw_id):
        slot = self.slots.pop(raw_id, None)
        if slot is not None:
            self.slot_pos.pop(slot, None)
        self.kinds.pop(raw_id, None)
        if self.drawing_pointer == raw_id:
            self.drawing_pointer = None

    def _release_all(self, flush=False):
        if flush:
            for raw_id in list(self.pending_up.keys()):
                self._emit_up_for(raw_id)
        self.pending_up.clear()
        self.slots.clear()
        self.slot_pos.clear()
        self.kinds.clear()
        self.drawing_pointer = None

    def _stylus_recent(self):
        if self.last_stylus_ms is None:
            return False
        return (self.now - self.last_stylus_ms) < GRACE_MS

    def _yield_to(self, new_id):
        old = self.drawing_pointer
        self.drawing_pointer = new_id
        if old is None:
            return
        self._emit_up_for(old)
        self.has_stroke = False
        self.is_drawing = False

    def _claim(self, raw_id, kind):
        if not self.palm_rejection:
            if self.drawing_pointer is None:
                self.drawing_pointer = raw_id
            return self.drawing_pointer == raw_id
        current = self.drawing_pointer
        if current is None:
            if not is_pen(kind) and self._stylus_recent():
                return False
            self.drawing_pointer = raw_id
            return True
        if current == raw_id:
            return True
        current_kind = self.kinds.get(current, "touch")
        if is_pen(kind) and not is_pen(current_kind):
            self._yield_to(raw_id)
            return True
        return False

    # --- public event handlers (mirror the Dart ones) ---
    def down(self, raw_id, kind, pos):
        if raw_id < 0:
            return
        slot = self._acquire_slot(raw_id)
        self.kinds[raw_id] = kind
        if is_pen(kind):
            self.last_stylus_ms = self.now
        if not self._claim(raw_id, kind):
            self.slot_pos[slot] = pos
            return
        self.is_drawing = True
        self.has_stroke = True
        self.slot_pos[slot] = pos
        self._emit("down", raw_id, slot)
        self.pending_up[raw_id] = slot

    def move(self, raw_id, kind, pos):
        if not self.is_drawing or not self.has_stroke:
            return
        if raw_id < 0:
            return
        if self.drawing_pointer is not None and self.drawing_pointer != raw_id:
            return
        slot = self.slots.get(raw_id)
        if slot is None:
            slot = self._acquire_slot(raw_id)
        if self.drawing_pointer is None:
            self.drawing_pointer = raw_id
        self.kinds[raw_id] = kind
        if is_pen(kind):
            self.last_stylus_ms = self.now
        self.slot_pos[slot] = pos
        if raw_id not in self.pending_up:
            self._emit("down", raw_id, slot)
            self.pending_up[raw_id] = slot
        self._emit("move", raw_id, slot)

    def up(self, raw_id, kind):
        if raw_id < 0:
            return
        down_slot = self.pending_up.pop(raw_id, None)
        if is_pen(self.kinds.get(raw_id, kind)):
            self.last_stylus_ms = self.now
        owned = self.drawing_pointer is None or self.drawing_pointer == raw_id
        self._release_slot(raw_id)
        if down_slot is None:
            return
        if owned and self.is_drawing and self.has_stroke:
            self.is_drawing = False
            self.has_stroke = False
        self._emit("up", raw_id, down_slot)

    def clear_canvas(self):
        self.has_stroke = False
        self.is_drawing = False
        self._release_all(flush=True)
        self._emit("clear", -1, 0)


# ---------------- checks ----------------
passed = 0
failed = 0


def check(name, cond):
    global passed, failed
    if cond:
        passed += 1
        print("  PASS  " + name)
    else:
        failed += 1
        print("  FAIL  " + name)


def verify_wire(wire, label):
    """down/up জোড়া, একসাথে একটাই down, আর স্লট মিল — তিনটাই যাচাই।"""
    held = {}
    max_concurrent = 0
    for kind, raw_id, slot in wire:
        if kind == "down":
            if raw_id in held:
                return "%s: pointer %d এর জন্য দুইবার down" % (label, raw_id)
            held[raw_id] = slot
            max_concurrent = max(max_concurrent, len(held))
        elif kind == "up":
            if raw_id not in held:
                return "%s: pointer %d এর up এসেছে down ছাড়াই" % (label, raw_id)
            if held.pop(raw_id) != slot:
                return "%s: pointer %d এর up ভুল স্লটে" % (label, raw_id)
    if max_concurrent > 1:
        return "%s: একসাথে %d টা down চাপা ছিল" % (label, max_concurrent)
    if held:
        return "%s: শেষে %d টা বাটন চাপা রয়ে গেছে" % (label, sorted(held))
    return None


print("১) আঙুল দিয়ে সাধারণ একটা স্ট্রোক")
m = Model()
m.down(7, "touch", (10, 10))
for i in range(5):
    m.now += 12
    m.move(7, "touch", (10 + i, 10))
m.up(7, "touch")
check("down/move/up সবই ওয়্যারে গেছে", [w[0] for w in m.wire] ==
      ["down"] + ["move"] * 5 + ["up"])
check("ইনভ্যারিয়েন্ট ঠিক", verify_wire(m.wire, "s1") is None)

print("২) পেন আঁকছে, তালু ছোঁয়াল — তালুর কিছুই যাবে না")
m = Model()
m.down(1, "stylus", (5, 5))
m.now += 10
m.move(1, "stylus", (6, 6))
m.down(2, "touch", (80, 80))          # তালু
m.now += 10
m.move(2, "touch", (81, 81))
m.move(1, "stylus", (7, 7))
m.up(2, "touch")                       # তালু উঠল
m.now += 10
m.move(1, "stylus", (8, 8))
m.up(1, "stylus")
check("তালুর একটাও ইভেন্ট যায়নি", all(w[1] != 2 for w in m.wire))
check("পেনের স্ট্রোক অটুট", [w[0] for w in m.wire] ==
      ["down", "move", "move", "move", "up"])
check("ইনভ্যারিয়েন্ট ঠিক", verify_wire(m.wire, "s2") is None)

print("৩) আঙুল আঁকছিল, পেন নামল — পেন জেতে, আঙুলের up যায়")
m = Model()
m.down(3, "touch", (10, 10))
m.now += 10
m.move(3, "touch", (11, 11))
m.down(4, "stylus", (50, 50))
m.now += 10
m.move(4, "stylus", (51, 51))
m.up(3, "touch")                       # আঙুল পরে উঠল
m.up(4, "stylus")
kinds = [(w[0], w[1]) for w in m.wire]
check("আঙুলের up পেনের down এর আগেই গেছে",
      kinds.index(("up", 3)) < kinds.index(("down", 4)))
check("আঙুল ওঠার সময় দ্বিতীয়বার up যায়নি",
      len([1 for w in m.wire if w[0] == "up" and w[1] == 3]) == 1)
check("ইনভ্যারিয়েন্ট ঠিক", verify_wire(m.wire, "s3") is None)

print("৪) পেন উঠেই আঙুল নামল (৪০০ ms grace)")
m = Model()
m.down(5, "stylus", (10, 10))
m.up(5, "stylus")
m.now += 100
m.down(6, "touch", (10, 10))           # grace এর ভেতরে → তালু
check("grace এর ভেতরের আঙুল উপেক্ষিত", all(w[1] != 6 for w in m.wire))
m.up(6, "touch")
m.now += 500
m.down(8, "touch", (10, 10))           # grace শেষ → আঁকবে
check("grace শেষ হলে আঙুল আঁকে", ("down", 8) in [(w[0], w[1]) for w in m.wire])
m.up(8, "touch")
check("ইনভ্যারিয়েন্ট ঠিক", verify_wire(m.wire, "s4") is None)

print("৫) মাঝপথে clearCanvas — বাটন ছেড়ে দিতে হবে")
m = Model()
m.down(9, "stylus", (10, 10))
m.now += 10
m.move(9, "stylus", (11, 11))
m.clear_canvas()
m.now += 10
m.move(9, "stylus", (12, 12))          # স্ট্রোক নেই, ড্রপ হবে
m.up(9, "stylus")
check("clear এর সময় up পাঠানো হয়েছে",
      [w[0] for w in m.wire if w[0] in ("down", "up")] == ["down", "up"])
check("ইনভ্যারিয়েন্ট ঠিক", verify_wire(m.wire, "s5") is None)

print("৬) down ড্রপ হলেও move থেকে synthetic down")
# এই শাখাটা defensive — স্বাভাবিক পথে down আর pending_up একসাথেই সেট হয়, তাই
# হাতে করে "down প্যাকেটটা কখনো ওয়্যারে যায়ইনি" অবস্থা বানানো হচ্ছে: wire থেকে
# down সরানো হলো এবং pending রেকর্ডও মুছে দেওয়া হলো।
m = Model()
m.down(11, "touch", (10, 10))          # মালিক
m.pending_up.pop(11)
m.wire = [w for w in m.wire if w[0] != "down"]
m.now += 10
m.move(11, "touch", (11, 11))
m.up(11, "touch")
check("synthetic down + up জোড়া মিলেছে", verify_wire(m.wire, "s6") is None)
check("move থেকেই down টা এসেছে", m.wire[0][0] == "down")

print("৭) ১৭তম pointer — স্লট কেড়ে নেওয়ার সময় পুরনোটার up")
m = Model()
for i in range(MAX_SLOTS):
    m.down(100 + i, "touch", (i, i))    # প্রথমটাই মালিক, বাকিরা উপেক্ষিত
m.down(200, "touch", (1, 1))            # স্লট কেড়ে নেবে
check("মালিক pointer 100 এর up গেছে", ("up", 100) in [(w[0], w[1]) for w in m.wire])
for i in range(1, MAX_SLOTS):
    m.up(100 + i, "touch")
m.up(200, "touch")
check("ইনভ্যারিয়েন্ট ঠিক", verify_wire(m.wire, "s7") is None)

print("৮) র‍্যান্ডম ফাজ — ২০০০টা সিকোয়েন্স")
random.seed(20260829)
bad = None
for trial in range(2000):
    m = Model(palm_rejection=(trial % 7 != 0))
    live = {}
    next_id = 1
    for _ in range(random.randint(1, 60)):
        m.now += random.randint(0, 250)
        roll = random.random()
        if roll < 0.30 or not live:
            kind = random.choice(["touch", "touch", "stylus", "eraser", "mouse"])
            live[next_id] = kind
            m.down(next_id, kind, (random.random(), random.random()))
            next_id += 1
        elif roll < 0.75:
            rid = random.choice(list(live))
            m.move(rid, live[rid], (random.random(), random.random()))
        elif roll < 0.97:
            rid = random.choice(list(live))
            m.up(rid, live.pop(rid))
        else:
            m.clear_canvas()
    for rid, kind in list(live.items()):
        m.up(rid, kind)
    err = verify_wire(m.wire, "trial %d" % trial)
    if err:
        bad = err
        break
check("সব সিকোয়েন্সে ইনভ্যারিয়েন্ট টিকেছে " + (bad or ""), bad is None)

print("")
if failed:
    print("%d টি চেক ফেল করেছে।" % failed)
    sys.exit(1)
print("সব %d টি চেক পাস করেছে।" % passed)
