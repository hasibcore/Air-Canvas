// ড্রয়িং স্টেট ও লজিক ম্যানেজার
//
// ক্যানভাসে ড্রয়িং সম্পর্কিত সব কিছু ম্যানেজ করে:
// - স্ট্রোক কালেকশন
// - প্রেশার সেনসিটিভিটি
// - ব্রাশ সেটিংস
// - অফলাইন ক্যানভাস রেন্ডারিং (client side mirror)

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/input_event.dart';
import 'one_euro_filter.dart';

/// ড্রয়িং অ্যাকুরেসি ও স্মুথিং ইঞ্জিন মোড
enum PrecisionMode {
  /// 🎯 1-Euro অ্যাডাপ্টিভ ফিল্টার (Casiez et al.): ধীরে লিখলে জিটার ১০০% শূন্য করে,
  /// দ্রুত লিখলে শূন্য ল্যাগে শার্প কোণা বজায় রাখে। প্রো ড্রয়িং ও হ্যান্ডরাইটিং এর জন্য আদর্শ।
  proAdaptive,

  /// ⚡ আল্ট্রা ডিরেক্ট র (Unfiltered): কোনো প্রকার ফিল্টারিং ছাড়া সরাসরি সেন্সরের ডাটা।
  rawDirect,

  /// 🎨 স্টুডিও আর্ট স্টেবিলাইজার: ধীরগতির মসৃণ কার্ভ ও ইঙ্কিং এর জন্য।
  studioSmooth,
}

/// প্রেশার রেসপন্স কার্ভ
enum PressureCurve {
  /// 1:1 লিনিয়ার রেসপন্স
  standard,

  /// হালকা স্পর্শেই গাঢ় লাইন (ক্যাপাসিটিভ পেন ও হালকা হাতের জন্য উপযোগী - Gamma 0.7)
  soft,

  /// সূক্ষ্ম নিখুঁত রেখা ও ক্যালিগ্রাফির জন্য উচ্চ নিয়ন্ত্রণ (Gamma 1.4)
  firm;

  /// প্রেশার ইনপুট ট্রান্সফর্ম করে (0.0 .. 1.0 রেঞ্জ নিশ্চিত করে)
  double transform(double rawPressure) {
    switch (this) {
      case PressureCurve.soft:
        return math.pow(rawPressure.clamp(0.0, 1.0), 0.7).toDouble().clamp(0.0, 1.0);
      case PressureCurve.firm:
        return math.pow(rawPressure.clamp(0.0, 1.0), 1.4).toDouble().clamp(0.0, 1.0);
      case PressureCurve.standard:
        return rawPressure.clamp(0.0, 1.0);
    }
  }
}

enum BrushMode {
  pen,      // সাধারণ পেন
  pencil,   // পেন্সিল (rougher)
  brush,    // ব্রাশ (thicker, opacity)
  eraser,   // ইরেজার
}

class BrushSettings {
  final Color color;
  final double baseWidth;
  final double pressureSensitivity;  // 0.0 - 1.0, 0 = no pressure effect
  final double opacity;
  final BrushMode mode;
  final bool smoothing;
  final int smoothingStrength;

  const BrushSettings({
    this.color = Colors.white,
    double baseWidth = 3.0,
    double pressureSensitivity = 0.7,
    double opacity = 1.0,
    this.mode = BrushMode.pen,
    this.smoothing = true,
    int smoothingStrength = 3,
  }) : baseWidth = baseWidth < 0.1 ? 0.1 : (baseWidth > 100.0 ? 100.0 : baseWidth),
       pressureSensitivity = pressureSensitivity < 0.0 ? 0.0 : (pressureSensitivity > 1.0 ? 1.0 : pressureSensitivity),
       opacity = opacity < 0.0 ? 0.0 : (opacity > 1.0 ? 1.0 : opacity),
       smoothingStrength = smoothingStrength < 1 ? 1 : (smoothingStrength > 20 ? 20 : smoothingStrength);

  BrushSettings copyWith({
    Color? color,
    double? baseWidth,
    double? pressureSensitivity,
    double? opacity,
    BrushMode? mode,
    bool? smoothing,
    int? smoothingStrength,
  }) => BrushSettings(
    color: color ?? this.color,
    baseWidth: baseWidth ?? this.baseWidth,
    pressureSensitivity: pressureSensitivity ?? this.pressureSensitivity,
    opacity: opacity ?? this.opacity,
    mode: mode ?? this.mode,
    smoothing: smoothing ?? this.smoothing,
    smoothingStrength: smoothingStrength ?? this.smoothingStrength,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BrushSettings &&
          runtimeType == other.runtimeType &&
          color == other.color &&
          baseWidth == other.baseWidth &&
          pressureSensitivity == other.pressureSensitivity &&
          opacity == other.opacity &&
          mode == other.mode &&
          smoothing == other.smoothing &&
          smoothingStrength == other.smoothingStrength;

  @override
  int get hashCode =>
      color.hashCode ^
      baseWidth.hashCode ^
      pressureSensitivity.hashCode ^
      opacity.hashCode ^
      mode.hashCode ^
      smoothing.hashCode ^
      smoothingStrength.hashCode;
}

class StrokePoint {
  final Offset position;
  final double pressure;
  final DateTime timestamp;
  final PointerType pointerType;

  StrokePoint({
    required this.position,
    required this.pressure,
    required this.timestamp,
    this.pointerType = PointerType.finger,
  });
}

class Stroke {
  final List<StrokePoint> _points;
  final BrushSettings settings;
  final DateTime startTime;
  double _pressureSum = 0.0;
  Path? _cachedPath;
  Paint? _cachedPaint;

  Stroke({
    List<StrokePoint>? points,
    required this.settings,
    DateTime? startTime,
  })  : _points = points ?? [],
        startTime = startTime ?? DateTime.now() {
    if (points != null) {
      for (final p in points) {
        _pressureSum += p.pressure.isNaN || p.pressure.isInfinite ? 0.5 : p.pressure.clamp(0.0, 1.0);
      }
    }
  }

  List<StrokePoint> get points => List.unmodifiable(_points);

  void addPoint(StrokePoint point) {
    final pressureVal = point.pressure.isNaN || point.pressure.isInfinite ? 0.5 : point.pressure.clamp(0.0, 1.0);
    _points.add(point);
    _pressureSum += pressureVal;
    _cachedPath = null;
  }

  Path get path {
    if (_cachedPath != null) return _cachedPath!;
    final p = Path();
    if (_points.isEmpty) return _cachedPath = p;

    p.moveTo(_points.first.position.dx, _points.first.position.dy);
    if (_points.length == 2) {
      p.lineTo(_points.last.position.dx, _points.last.position.dy);
    } else if (_points.length > 2) {
      for (int i = 1; i < _points.length - 1; i++) {
        final p1 = _points[i].position;
        final p2 = _points[i + 1].position;
        final midX = (p1.dx + p2.dx) / 2;
        final midY = (p1.dy + p2.dy) / 2;
        p.quadraticBezierTo(p1.dx, p1.dy, midX, midY);
      }
      p.lineTo(_points.last.position.dx, _points.last.position.dy);
    }
    return _cachedPath = p;
  }

  Paint get paint {
    if (_cachedPaint != null) return _cachedPaint!;
    final avgPressure = averagePressure;
    final width = settings.baseWidth * (0.3 + avgPressure * 0.7 * settings.pressureSensitivity);

    final p = Paint()
      ..color = settings.mode == BrushMode.eraser
          ? const Color(0xFF0A0A12)
          : settings.color.withValues(alpha: settings.opacity.clamp(0.0, 1.0))
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    if (settings.mode == BrushMode.pencil) {
      p.strokeWidth = width * 0.7;
    } else if (settings.mode == BrushMode.brush) {
      p.maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    }
    return _cachedPaint = p;
  }

  double get averagePressure {
    if (_points.isEmpty) return 0.5;
    final avg = _pressureSum / _points.length;
    return avg.isNaN || avg.isInfinite ? 0.5 : avg.clamp(0.0, 1.0);
  }

  bool get isEmpty => _points.isEmpty;
  bool get isSinglePoint => _points.length == 1;

  /// স্ট্রোকের বাউন্ডিং বক্স
  Rect? get bounds {
    if (_points.isEmpty) return null;
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in _points) {
      if (p.position.dx < minX) minX = p.position.dx;
      if (p.position.dy < minY) minY = p.position.dy;
      if (p.position.dx > maxX) maxX = p.position.dx;
      if (p.position.dy > maxY) maxY = p.position.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}

class CanvasRepaintNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

class DrawingProvider extends ChangeNotifier {
  // --- State ---
  final List<Stroke> _strokes = [];
  Stroke? _currentStroke;
  BrushSettings _brushSettings = const BrushSettings();
  bool _isDrawing = false;
  Offset? _lastPosition;
  double _canvasWidth = 1.0;
  double _canvasHeight = 1.0;
  bool _pressureSmoothing = true;
  double _lastPressure = 0.0;
  bool _directTabletMode = true;

  // Pro Precision & Jitter Filter Engine (1-Euro Filter)
  PrecisionMode _precisionMode = PrecisionMode.proAdaptive;
  PressureCurve _pressureCurve = PressureCurve.standard;
  final OneEuroFilter2D _oneEuroFilter = OneEuroFilter2D(minCutoff: 1.2, beta: 0.008);

  // Smoothing buffer
  final List<Offset> _positionBuffer = [];
  final List<double> _pressureBuffer = [];

  // --- Pointer slot mapping ---
  //
  // Flutter এর `PointerEvent.pointer` একটা প্রসেস-গ্লোবাল কাউন্টার — অ্যাপ চালু
  // থাকা অবস্থায় প্রতিটি নতুন টাচ/হোভার/স্ক্রলে ১ করে বাড়ে, কখনো রিসেট হয় না।
  // মেনু ট্যাপ, স্ক্রল, বাটন চাপ — সবই গোনায় ধরা হয়। আগে এখানে
  // `pointerId > 100` হলে ইভেন্ট ফেলে দেওয়া হতো, ফলে অ্যাপ কিছুক্ষণ ব্যবহারের
  // পর (~১০০ বার আঙুল ছোঁয়ানোর পর) down/move/up তিনটাই সাইলেন্টলি ড্রপ হতো —
  // অ্যাপ "connected" দেখাত কিন্তু কিছুই আঁকা হতো না।
  //
  // এখন প্রতিটি সক্রিয় পয়েন্টারকে ০..১৫ এর একটা ছোট স্লট দেওয়া হয়, pointer
  // উঠে গেলে স্লট ছেড়ে দেওয়া হয়। তাই ওয়্যারের ১ বাইট pointerId কখনো ওভারফ্লো
  // করে না (আগে input_event.dart `clamp(0, 255)` করত, মানে ২৫৫+ সব এক হয়ে যেত),
  // আর multi-touch এ কোন আঙুল কোনটা সেটাও PC পাশে আলাদা করে বোঝা যায়।
  static const int maxPointerSlots = 16;
  final Map<int, int> _pointerSlots = <int, int>{};
  final Map<int, Offset> _slotLastPosition = <int, Offset>{};

  // --- Palm rejection / single-cursor arbitration ---
  //
  // PC পাশে কার্সর একটাই। কিন্তু স্ক্রিনে একসাথে কয়েকটা পয়েন্টার থাকতে পারে —
  // পেন, পেন ধরা হাতের তালু, আরেকটা আঙুল। আগে সবগুলোর down/move/up একই
  // কার্সরে ইনজেক্ট হতো, ফলে তালু ছোঁয়ালেই লাইন লাফ দিত আর দুই আঙুল লাগলে
  // স্ট্রোক এলোমেলো হয়ে যেত — "draw ঠিকমতো হচ্ছে না" এর একটা বড় কারণ।
  //
  // নিয়ম (palmRejection চালু থাকলে):
  //   • কেউ না আঁকলে — প্রথম যে পয়েন্টার নামে, সে-ই স্ট্রোকের মালিক।
  //   • আঙুল আঁকছিল, পেন নামল — পেন জেতে। আঙুলের জন্য pointerUp পাঠিয়ে
  //     (PC তে বাটন ছেড়ে) মালিকানা পেনকে দেওয়া হয়।
  //   • পেন আঁকছে, আঙুল নামল — সেটা তালু, চুপচাপ উপেক্ষা।
  //   • পেন উঠে যাওয়ার পরেও ৪০০ ms আঙুল উপেক্ষা করা হয়, কারণ তালু সাধারণত
  //     পেনের একটু পরে ওঠে।
  //   • একই ধরনের দ্বিতীয় পয়েন্টার — উপেক্ষা (একটাই কার্সর)।
  //
  // উপেক্ষিত পয়েন্টারও স্লট পায় এবং তার up ট্র্যাক হয়, শুধু ওয়্যারে কিছু যায় না।
  static const Duration stylusGracePeriod = Duration(milliseconds: 400);
  bool _palmRejection = true;
  int? _drawingPointer;
  final Map<int, PointerType> _pointerKinds = <int, PointerType>{};
  DateTime? _lastStylusActivity;

  /// যেসব raw pointer এর জন্য সত্যিই একটা `pointerDown` ওয়্যারে গেছে →
  /// সেই down টা কোন স্লট নাম্বারে গিয়েছিল।
  ///
  /// up পাঠানো হবে কি না এই ম্যাপ দেখেই ঠিক হয়। "down গেছে ⇒ up যেতেই হবে,
  /// down যায়নি ⇒ up কখনো যাবে না" — এই দুটো একসাথে ধরে রাখলে PC তে বাটন
  /// চাপা থেকে যাওয়া আর চলতি স্ট্রোকের মাঝপথে বাটন ছেড়ে দেওয়া, দুটোই আটকায়।
  /// স্লটটাও এখানেই রাখা হয়, কারণ `_pointerSlots` থেকে স্লট কেড়ে নেওয়া হতে
  /// পারে — তখনও up টা যে স্লটে down গিয়েছিল সেই স্লটেই যাওয়া দরকার।
  final Map<int, int> _pendingUpSlots = <int, int>{};

  bool get palmRejection => _palmRejection;

  set palmRejection(bool value) {
    if (_palmRejection == value) return;
    _palmRejection = value;
    notifyListeners();
  }

  static bool _isPen(PointerType kind) =>
      kind == PointerType.stylus || kind == PointerType.eraser;

  bool get _stylusRecentlyActive {
    final last = _lastStylusActivity;
    if (last == null) return false;
    return DateTime.now().difference(last) < stylusGracePeriod;
  }

  /// এই pointer টা স্ট্রোক চালানোর অধিকার পাবে কি না ঠিক করে।
  bool _claimOnDown(int rawPointerId, PointerType kind, DateTime now) {
    if (!_palmRejection) {
      _drawingPointer ??= rawPointerId;
      return _drawingPointer == rawPointerId;
    }

    final current = _drawingPointer;
    if (current == null) {
      if (!_isPen(kind) && _stylusRecentlyActive) return false; // তালু
      _drawingPointer = rawPointerId;
      return true;
    }
    if (current == rawPointerId) return true;

    final currentKind = _pointerKinds[current] ?? PointerType.finger;
    if (_isPen(kind) && !_isPen(currentKind)) {
      _yieldOwnershipTo(rawPointerId, now);
      return true;
    }
    return false; // দ্বিতীয় আঙুল / তালু
  }

  /// চলতি স্ট্রোক বন্ধ করে মালিকানা [newPointerId] কে দেয়, এবং পুরনো পয়েন্টারের
  /// জন্য pointerUp পাঠায় যাতে PC তে বাটন চাপা থেকে না যায়।
  void _yieldOwnershipTo(int newPointerId, DateTime now) {
    final old = _drawingPointer;
    _drawingPointer = newPointerId;
    if (old == null) return;

    // স্লট না থাকলেও up যাবে — _emitPointerUpFor নিজেই down এর রেকর্ড করা স্লট
    // ব্যবহার করে, তাই পুরনো pointer এর বাটন কোনো অবস্থাতেই চাপা থাকে না।
    final oldSlot = _pointerSlots[old];
    _emitPointerUpFor(
        old, oldSlot == null ? null : _slotLastPosition[oldSlot], now);

    if (_currentStroke != null && _currentStroke!.points.isNotEmpty) {
      _strokes.add(_currentStroke!);
      if (_strokes.length > 500) _strokes.removeAt(0);
    }
    _currentStroke = null;
    _isDrawing = false;
    _resetSmoothingBuffers();
  }

  /// [rawPointerId] এর জন্য একটা pointerUp পাঠায়, শুধু যদি তার down আগে গিয়ে
  /// থাকে। রেকর্ডটা মুছেও দেয়, তাই একই pointer এর জন্য দুইবার up যায় না।
  void _emitPointerUpFor(int rawPointerId, Offset? position, DateTime now) {
    final slot = _pendingUpSlots.remove(rawPointerId);
    if (slot == null) return;
    _emitInputEvent(
      InputEventType.pointerUp,
      position ?? _lastPosition ?? Offset.zero,
      0.0,
      _pointerKinds[rawPointerId] ?? PointerType.finger,
      slot,
      now,
    );
  }

  /// এই raw pointer এর স্লট, না থাকলে নতুন একটা দেয়।
  ///
  /// সব স্লট ব্যস্ত থাকলে সবচেয়ে পুরনোটা কেড়ে নেওয়া হয়, ব্যর্থ হওয়া হয় না।
  /// কারণ pointer up/cancel কোনোভাবে মিস হলে (যেমন অ্যাপ ব্যাকগ্রাউন্ডে গেলে)
  /// স্লট আটকে থাকতে পারে — তখন "ব্যর্থ" হলে ড্রয়িং চিরতরে বন্ধ হয়ে যেত,
  /// অর্থাৎ পুরনো `pointerId > 100` বাগটাই ছোট আকারে ফিরে আসত।
  int _acquireSlot(int rawPointerId) {
    final existing = _pointerSlots[rawPointerId];
    if (existing != null) return existing;

    final used = _pointerSlots.values.toSet();
    for (int slot = 0; slot < maxPointerSlots; slot++) {
      if (!used.contains(slot)) {
        _pointerSlots[rawPointerId] = slot;
        return slot;
      }
    }

    // Map টা insertion-ordered, তাই প্রথম key-ই সবচেয়ে পুরনো pointer।
    final stalest = _pointerSlots.keys.first;
    final reclaimed = _pointerSlots.remove(stalest)!;
    // স্লট কেড়ে নেওয়ার আগে ওই হারানো pointer এর up পাঠিয়ে দেওয়া, নাহলে PC তে
    // তার বাটন চিরকাল চাপা থাকত। পজিশনটা মুছে ফেলার আগেই নিতে হয়।
    _emitPointerUpFor(stalest, _slotLastPosition[reclaimed], DateTime.now());
    _slotLastPosition.remove(reclaimed);
    _pointerKinds.remove(stalest);
    if (_drawingPointer == stalest) _drawingPointer = null;
    debugPrint('[Drawing] Reclaimed pointer slot $reclaimed from stale pointer $stalest');
    _pointerSlots[rawPointerId] = reclaimed;
    return reclaimed;
  }

  void _releaseSlot(int rawPointerId) {
    final slot = _pointerSlots.remove(rawPointerId);
    if (slot != null) _slotLastPosition.remove(slot);
    _pointerKinds.remove(rawPointerId);
    if (_drawingPointer == rawPointerId) _drawingPointer = null;
  }

  /// সব pointer state ছেড়ে দেওয়া (canvas clear, dispose, রিমোট reset)।
  ///
  /// [flushPendingUps] true হলে যেসব pointer এর down ওয়্যারে গেছে কিন্তু up যায়নি,
  /// তাদের জন্য আগে up পাঠানো হয় — নাহলে PC তে বাটন চাপা অবস্থায় আটকে থাকত।
  void _releaseAllSlots({bool flushPendingUps = false}) {
    if (flushPendingUps && _pendingUpSlots.isNotEmpty) {
      final now = DateTime.now();
      for (final pointerId in _pendingUpSlots.keys.toList()) {
        final slot = _pendingUpSlots[pointerId];
        _emitPointerUpFor(
            pointerId, slot == null ? null : _slotLastPosition[slot], now);
      }
    }
    _pendingUpSlots.clear();
    _pointerSlots.clear();
    _slotLastPosition.clear();
    _pointerKinds.clear();
    _drawingPointer = null;
  }

  /// UI/ডিবাগের জন্য — এখন কতগুলো পয়েন্টার সক্রিয় ধরে রাখা হয়েছে।
  int get activePointerCount => _pointerSlots.length;

  // Canvas repaint notifier (prevents whole screen rebuilding during fast pointer movements)
  final CanvasRepaintNotifier canvasNotifier = CanvasRepaintNotifier();

  // Callbacks
  void Function(InputEvent)? onInputGenerated;

  // Getters
  List<Stroke> get strokes => List.unmodifiable(_strokes);
  Stroke? get currentStroke => _currentStroke;
  BrushSettings get brushSettings => _brushSettings;
  bool get isDrawing => _isDrawing;
  Offset? get lastPosition => _lastPosition;
  bool get pressureSmoothing => _pressureSmoothing;

  set pressureSmoothing(bool val) {
    _pressureSmoothing = val;
    notifyListeners();
  }

  /// হাই-পারফরম্যান্স গ্রাফিক্স ট্যাবলেট মোড:
  /// true থাকলে পিসিতে 0-latency তে অবিকল raw touch কো-অর্ডিনেট পাঠানো হয়,
  /// ফলে অনলাইন ক্লাসে ব্ল্যাকবোর্ড/হোয়াইটবোর্ডে গণিতের সমীকরণ বা দ্রুত হাতের
  /// লেখা (handwriting) কোনোরকম lag বা বিকৃতি ছাড়া অবিকল ফুটিয়ে তোলা যায়।
  PrecisionMode get precisionMode => _precisionMode;

  set precisionMode(PrecisionMode mode) {
    if (_precisionMode != mode) {
      _precisionMode = mode;
      _directTabletMode = (mode != PrecisionMode.studioSmooth);
      _resetSmoothingBuffers();
      notifyListeners();
    }
  }

  PressureCurve get pressureCurve => _pressureCurve;

  set pressureCurve(PressureCurve curve) {
    if (_pressureCurve != curve) {
      _pressureCurve = curve;
      notifyListeners();
    }
  }

  /// হাই-পারফরম্যান্স গ্রাফিক্স ট্যাবলেট মোড (Backwards-compatible API)
  bool get directTabletMode => _precisionMode != PrecisionMode.studioSmooth;

  set directTabletMode(bool val) {
    precisionMode = val ? PrecisionMode.proAdaptive : PrecisionMode.studioSmooth;
  }

  void updateCanvasSize(double width, double height) {
    _canvasWidth = width <= 0 ? 1.0 : width;
    _canvasHeight = height <= 0 ? 1.0 : height;
    notifyListeners();
  }

  void updateBrush(BrushSettings settings) {
    _brushSettings = settings;
    notifyListeners();
  }

  double _applyPressureCurve(double rawPressure) {
    return _pressureCurve.transform(rawPressure);
  }

  void _resetSmoothingBuffers() {
    _lastPosition = null;
    _lastPressure = 0.0;
    _positionBuffer.clear();
    _pressureBuffer.clear();
    _oneEuroFilter.reset();
  }

  /// টাচ/পেন ডাউন - নতুন স্ট্রোক শুরু
  void onPointerDown(Offset position, {
    double pressure = 0.5,
    PointerType pointerType = PointerType.finger,
    int pointerId = 0,
    double tiltX = 0.0,
    double tiltY = 0.0,
    int buttons = 0,
  }) {
    if (pointerId < 0) return; // Defensive pointerId check
    // Flutter এর গ্লোবাল pointer id কে ছোট স্লটে ম্যাপ করা — উপরের নোট দেখুন।
    final slot = _acquireSlot(pointerId);
    if (slot < 0) return; // ১৬টা স্লটই ব্যস্ত

    final now = DateTime.now();
    _pointerKinds[pointerId] = pointerType;
    if (_isPen(pointerType)) _lastStylusActivity = now;

    // তালু / দ্বিতীয় আঙুল হলে এখানেই থামা — স্লট রাখা হয় (যাতে up ট্র্যাক হয়)
    // কিন্তু স্ট্রোকও শুরু হয় না, ওয়্যারেও কিছু যায় না।
    if (!_claimOnDown(pointerId, pointerType, now)) {
      _slotLastPosition[slot] = position;
      return;
    }

    _isDrawing = true;

    final clampedPressure = pressure.isNaN || pressure.isInfinite ? 0.5 : pressure.clamp(0.0, 1.0);
    final calibratedPressure = _applyPressureCurve(clampedPressure);

    _resetSmoothingBuffers();
    final point = StrokePoint(
      position: position,
      pressure: calibratedPressure,
      timestamp: now,
      pointerType: pointerType,
    );

    _currentStroke = Stroke(settings: _brushSettings, startTime: now);
    _currentStroke!.addPoint(point);
    _lastPosition = position;
    _lastPressure = calibratedPressure;
    _slotLastPosition[slot] = position;

    _positionBuffer.add(position);
    _pressureBuffer.add(calibratedPressure);

    // ইনপুট ইভেন্ট জেনারেট ও পাঠানো
    _emitInputEvent(
      InputEventType.pointerDown, position, calibratedPressure, pointerType, slot, now,
      tiltX: tiltX, tiltY: tiltY, buttons: buttons,
    );
    // down গেল — এখন এই pointer এর up পাঠানো বাধ্যতামূলক।
    _pendingUpSlots[pointerId] = slot;

    canvasNotifier.notify();
    notifyListeners();
  }

  /// টাচ/পেন মুভ - স্ট্রোক চালিয়ে যাওয়া
  void onPointerMove(Offset position, {
    double pressure = 0.5,
    PointerType pointerType = PointerType.finger,
    int pointerId = 0,
    double tiltX = 0.0,
    double tiltY = 0.0,
    int buttons = 0,
  }) {
    if (!_isDrawing || _currentStroke == null) return;
    if (pointerId < 0) return; // Defensive pointerId check
    // তালু / দ্বিতীয় আঙুলের move উপেক্ষা — কার্সর একটাই।
    if (_drawingPointer != null && _drawingPointer != pointerId) return;
    // down মিস হয়ে থাকলেও স্লট দিয়ে দেওয়া হয় — নাহলে পুরো স্ট্রোক হারিয়ে যেত।
    final slot = _pointerSlots[pointerId] ?? _acquireSlot(pointerId);
    if (slot < 0) return;
    _drawingPointer ??= pointerId;
    _pointerKinds[pointerId] = pointerType;
    if (_isPen(pointerType)) _lastStylusActivity = DateTime.now();

    final clampedPressure = pressure.isNaN || pressure.isInfinite ? 0.5 : pressure.clamp(0.0, 1.0);
    final now = DateTime.now();

    // 1. Pro Precision filtering (1-Euro Adaptive vs Studio Smooth vs Raw Direct)
    Offset precisionPosition = position;
    if (_precisionMode == PrecisionMode.proAdaptive) {
      precisionPosition = _oneEuroFilter.filter(position, now);
    } else if (_precisionMode == PrecisionMode.studioSmooth) {
      precisionPosition = _smoothPosition(position);
    } else {
      precisionPosition = position;
    }

    // 2. Pro Pressure curve calibration & smoothing
    double calibratedPressure = _applyPressureCurve(clampedPressure);
    if (_brushSettings.smoothing && _precisionMode != PrecisionMode.rawDirect) {
      calibratedPressure = _smoothPressure(calibratedPressure);
    }

    final point = StrokePoint(
      position: precisionPosition,
      pressure: calibratedPressure,
      timestamp: now,
      pointerType: pointerType,
    );

    _currentStroke!.addPoint(point);
    _lastPosition = precisionPosition;
    _lastPressure = calibratedPressure;
    _slotLastPosition[slot] = precisionPosition;

    // Both local mirror canvas and Windows PC receive the EXACT SAME precision coordinates
    if (!_pendingUpSlots.containsKey(pointerId)) {
      _emitInputEvent(
        InputEventType.pointerDown, precisionPosition, calibratedPressure, pointerType, slot, now,
        tiltX: tiltX, tiltY: tiltY, buttons: buttons,
      );
      _pendingUpSlots[pointerId] = slot;
    }
    _emitInputEvent(
      InputEventType.pointerMove, precisionPosition, calibratedPressure, pointerType, slot, now,
      tiltX: tiltX, tiltY: tiltY, buttons: buttons,
    );

    // Only notify the canvas repaint notifier (avoids rebuilding the entire widget tree/toolbar)
    canvasNotifier.notify();
  }

  /// টাচ/পেন আপ - স্ট্রোক শেষ
  ///
  /// এখানে আগে `if (!_isDrawing || _currentStroke == null) return;` দিয়ে শুরু
  /// হতো। কিন্তু down টা কোনো কারণে ড্রপ হলে বা মাঝপথে canvas clear হলে
  /// pointerUp নেটওয়ার্কে যেতই না — PC পাশে MOUSEEVENTF_LEFTUP আসত না, মাউস
  /// চাপা অবস্থায় আটকে থেকে স্ক্রিনজুড়ে দাগ টানত। তাই এখন যে pointer এর জন্য
  /// একবার down পাঠানো হয়েছে, তার up সব সময় যায় — স্ট্রোক state যা-ই থাকুক।
  void onPointerUp({
    PointerType pointerType = PointerType.finger,
    int pointerId = 0,
    int buttons = 0,
  }) {
    if (pointerId < 0) return; // Defensive pointerId check

    final slot = _pointerSlots[pointerId];
    final slotPosition = slot == null ? null : _slotLastPosition[slot];
    // "এই pointer এর down কি সত্যিই ওয়্যারে গিয়েছিল, আর কোন স্লটে?" — অনুমান
    // নয়, রেকর্ড। আগে এখানে `_drawingPointer == null || _drawingPointer ==
    // pointerId` হিউরিস্টিক ছিল, কিন্তু উপেক্ষিত তালুর down কখনো যায় না অথচ তার
    // সময় _drawingPointer null হতে পারত — ফলে তালু তোলামাত্র একটা ভুয়া up যেত
    // এবং চলতি পেন স্ট্রোকের মাঝখানে PC তে বাটন ছেড়ে দিত।
    final downSlot = _pendingUpSlots.remove(pointerId);
    if (_isPen(_pointerKinds[pointerId] ?? pointerType)) {
      _lastStylusActivity = DateTime.now();
    }
    // লোকাল স্ট্রোক শেষ করার অধিকার। null-ও ধরা হয়েছে ইচ্ছে করেই — নাহলে
    // _drawingPointer কোনোভাবে হারালে _isDrawing চিরকাল true থেকে যেত।
    final ownedStroke = _drawingPointer == null || _drawingPointer == pointerId;
    _releaseSlot(pointerId); // early return এর আগেই স্লট ছাড়া — নাহলে লিক হতো

    // তালু / দ্বিতীয় আঙুল উঠল: এর down কখনো পাঠানো হয়নি, তাই up-ও পাঠানো যাবে
    // না — পাঠালে চলতি পেন স্ট্রোকের মাঝখানে PC তে বাটন ছেড়ে দিত।
    if (downSlot == null) return;

    final now = DateTime.now();
    final upPosition = _lastPosition ??
        slotPosition ??
        (_currentStroke != null && _currentStroke!.points.isNotEmpty
            ? _currentStroke!.points.last.position
            : null);

    if (ownedStroke && _isDrawing && _currentStroke != null) {
      _isDrawing = false;

      // Add final point using upPosition if available to ensure stroke completeness
      if (upPosition != null && _currentStroke!.points.isNotEmpty) {
        final lastPoint = StrokePoint(
          position: upPosition,
          pressure: _lastPressure,
          timestamp: now,
          pointerType: pointerType,
        );
        _currentStroke!.addPoint(lastPoint);
      }

      // স্ট্রোক সেভ করা (minimum 1 point থাকলে)
      if (_currentStroke!.points.isNotEmpty) {
        _strokes.add(_currentStroke!);
        // Limit strokes history length to prevent memory leak
        if (_strokes.length > 500) {
          _strokes.removeAt(0);
        }
      }
      _currentStroke = null;
      _resetSmoothingBuffers();
    }

    // ইনপুট ইভেন্ট পাঠানো — এই pointer এর down গেছে মানে up-ও যেতেই হবে,
    // নাহলে PC তে বাটন চাপা থেকে যায়। down যে স্লটে গিয়েছিল সেই স্লটেই যায়,
    // স্লটটা মাঝপথে অন্য pointer এর কাছে চলে গেলেও।
    _emitInputEvent(
      InputEventType.pointerUp, upPosition ?? Offset.zero, 0.0, pointerType, downSlot, now,
      buttons: buttons,
    );

    canvasNotifier.notify();
    notifyListeners();
  }

  /// Handle incoming remote input event (e.g. tablet strokes received on PC server)
  void handleIncomingInputEvent(InputEvent event) {
    final w = _canvasWidth <= 0 ? 1.0 : _canvasWidth;
    final h = _canvasHeight <= 0 ? 1.0 : _canvasHeight;
    final pos = Offset(event.x * w, event.y * h);

    if (event.type == InputEventType.clear) {
      _strokes.clear();
      _currentStroke = null;
      _isDrawing = false;
      _resetSmoothingBuffers();
      canvasNotifier.notify();
      notifyListeners();
      return;
    }

    if (event.type == InputEventType.pointerDown) {
      _isDrawing = true;
      _resetSmoothingBuffers();
      final point = StrokePoint(
        position: pos,
        pressure: event.pressure,
        timestamp: event.timestamp,
        pointerType: event.pointerType,
      );
      _currentStroke = Stroke(settings: _brushSettings, startTime: event.timestamp);
      _currentStroke!.addPoint(point);
      _lastPosition = pos;
      _lastPressure = event.pressure;
      _positionBuffer.add(pos);
      _pressureBuffer.add(event.pressure);
      canvasNotifier.notify();
      notifyListeners();
    } else if (event.type == InputEventType.pointerMove) {
      if (_currentStroke == null) {
        _isDrawing = true;
        _currentStroke = Stroke(settings: _brushSettings, startTime: event.timestamp);
      }
      final point = StrokePoint(
        position: pos,
        pressure: event.pressure,
        timestamp: event.timestamp,
        pointerType: event.pointerType,
      );
      _currentStroke!.addPoint(point);
      _lastPosition = pos;
      _lastPressure = event.pressure;
      canvasNotifier.notify();
    } else if (event.type == InputEventType.pointerUp || event.type == InputEventType.pointerCancel) {
      if (_currentStroke != null) {
        _strokes.add(_currentStroke!);
        _currentStroke = null;
      }
      _isDrawing = false;
      _resetSmoothingBuffers();
      canvasNotifier.notify();
      notifyListeners();
    }
  }

  /// ইনপুট ইভেন্ট জেনারেট ও callback এ পাঠানো
  void _emitInputEvent(
    InputEventType type,
    Offset position,
    double pressure,
    PointerType pointerType,
    int pointerId,
    DateTime timestamp, {
    double tiltX = 0.0,
    double tiltY = 0.0,
    int buttons = 0,
  }) {
    final w = _canvasWidth <= 0 ? 1.0 : _canvasWidth;
    final h = _canvasHeight <= 0 ? 1.0 : _canvasHeight;
    final normalizedX = (position.dx / w).clamp(0.0, 1.0);
    final normalizedY = (position.dy / h).clamp(0.0, 1.0);

    final event = InputEvent(
      type: type,
      x: normalizedX,
      y: normalizedY,
      pressure: pressure,
      pointerType: pointerType,
      pointerId: pointerId,
      tiltX: tiltX,
      tiltY: tiltY,
      buttons: buttons,
      timestamp: timestamp,
    );

    try {
      onInputGenerated?.call(event);
    } catch (e, stackTrace) {
      debugPrint('Error in onInputGenerated callback: $e\n$stackTrace');
    }
  }

  /// পজিশন স্মুথিং (Moving Average based on brushSettings.smoothingStrength)
  Offset _smoothPosition(Offset position) {
    _positionBuffer.add(position);
    final maxBufSize = _brushSettings.smoothingStrength.clamp(1, 20);
    while (_positionBuffer.length > maxBufSize) {
      _positionBuffer.removeAt(0);
    }

    double sumX = 0, sumY = 0;
    double totalWeight = 0;
    for (int i = 0; i < _positionBuffer.length; i++) {
      final weight = (i + 1).toDouble();
      sumX += _positionBuffer[i].dx * weight;
      sumY += _positionBuffer[i].dy * weight;
      totalWeight += weight;
    }

    return Offset(sumX / totalWeight, sumY / totalWeight);
  }

  /// প্রেশার স্মুথিং (Exponential Moving Average)
  double _smoothPressure(double pressure) {
    if (!_pressureSmoothing) return pressure;
    const alpha = 0.4; // Smoothing factor
    _lastPressure = alpha * pressure + (1 - alpha) * _lastPressure;
    return _lastPressure.clamp(0.0, 1.0);
  }

  /// Whether there are strokes available to undo (Bug 146)
  bool get canUndo => _strokes.isNotEmpty;

  /// আন্ডো - শেষ স্ট্রোক মুছে ফেলা
  void undo() {
    if (_strokes.isNotEmpty) {
      _strokes.removeLast();
      _resetSmoothingBuffers();
      canvasNotifier.notify();
      notifyListeners();
    }
  }

  /// সব স্ট্রোক মুছে ফেলা
  void clearCanvas() {
    _strokes.clear();
    _currentStroke = null;
    _isDrawing = false;
    _resetSmoothingBuffers();

    // আঙুল/পেন এখনো স্ক্রিনে থাকতে পারে। clear এর পর ওই pointer এর move গুলো
    // ড্রপ হবে (স্ট্রোক নেই), তাই তার up-ও আর যাবে না — সেই কারণে এখানেই বাকি
    // up গুলো পাঠিয়ে PC এর বাটন ছেড়ে দেওয়া হয়।
    _releaseAllSlots(flushPendingUps: true);

    // Emit clear event to remote side
    final event = InputEvent(
      type: InputEventType.clear,
      x: 0.0,
      y: 0.0,
      pressure: 0.0,
      pointerType: PointerType.finger,
      pointerId: 0,
    );
    try {
      onInputGenerated?.call(event);
    } catch (e, stackTrace) {
      debugPrint('Error calling onInputGenerated callback on clear: $e\n$stackTrace');
    }

    canvasNotifier.notify();
    notifyListeners();
  }

  @override
  void dispose() {
    // pointer slot map ও canvas notifier ছেড়ে দেওয়া — নাহলে hot restart এর পর
    // পুরনো স্লট ধরে থাকা state নিয়ে ভুল pointerId ওয়্যারে যেতে পারত।
    _releaseAllSlots();
    canvasNotifier.dispose();
    super.dispose();
  }
}