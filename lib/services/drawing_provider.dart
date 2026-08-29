// ড্রয়িং স্টেট ও লজিক ম্যানেজার
//
// ক্যানভাসে ড্রয়িং সম্পর্কিত সব কিছু ম্যানেজ করে:
// - স্ট্রোক কালেকশন
// - প্রেশার সেনসিটিভিটি
// - ব্রাশ সেটিংস
// - অফলাইন ক্যানভাস রেন্ডারিং (client side mirror)

import 'package:flutter/material.dart';
import '../models/input_event.dart';

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
    _slotLastPosition.remove(reclaimed);
    debugPrint('[Drawing] Reclaimed pointer slot $reclaimed from stale pointer $stalest');
    _pointerSlots[rawPointerId] = reclaimed;
    return reclaimed;
  }

  void _releaseSlot(int rawPointerId) {
    final slot = _pointerSlots.remove(rawPointerId);
    if (slot != null) _slotLastPosition.remove(slot);
  }

  /// সব pointer state ছেড়ে দেওয়া (canvas clear, dispose, রিমোট reset)।
  void _releaseAllSlots() {
    _pointerSlots.clear();
    _slotLastPosition.clear();
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

  void updateCanvasSize(double width, double height) {
    _canvasWidth = width <= 0 ? 1.0 : width;
    _canvasHeight = height <= 0 ? 1.0 : height;
    notifyListeners();
  }

  void updateBrush(BrushSettings settings) {
    _brushSettings = settings;
    notifyListeners();
  }

  void _resetSmoothingBuffers() {
    _lastPosition = null;
    _lastPressure = 0.0;
    _positionBuffer.clear();
    _pressureBuffer.clear();
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
    _isDrawing = true;

    final clampedPressure = pressure.isNaN || pressure.isInfinite ? 0.5 : pressure.clamp(0.0, 1.0);
    final now = DateTime.now();

    _resetSmoothingBuffers();
    final point = StrokePoint(
      position: position,
      pressure: clampedPressure,
      timestamp: now,
      pointerType: pointerType,
    );

    _currentStroke = Stroke(settings: _brushSettings, startTime: now);
    _currentStroke!.addPoint(point);
    _lastPosition = position;
    _lastPressure = clampedPressure;
    _slotLastPosition[slot] = position;

    _positionBuffer.add(position);
    _pressureBuffer.add(clampedPressure);

    // ইনপুট ইভেন্ট জেনারেট ও পাঠানো
    _emitInputEvent(
      InputEventType.pointerDown, position, clampedPressure, pointerType, slot, now,
      tiltX: tiltX, tiltY: tiltY, buttons: buttons,
    );

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
    // down মিস হয়ে থাকলেও স্লট দিয়ে দেওয়া হয় — নাহলে পুরো স্ট্রোক হারিয়ে যেত।
    final slot = _pointerSlots[pointerId] ?? _acquireSlot(pointerId);
    if (slot < 0) return;

    final clampedPressure = pressure.isNaN || pressure.isInfinite ? 0.5 : pressure.clamp(0.0, 1.0);
    final now = DateTime.now();

    Offset smoothedPosition = position;
    double smoothedPressure = clampedPressure;

    // Smoothing apply করা
    if (_brushSettings.smoothing) {
      smoothedPosition = _smoothPosition(position);
      smoothedPressure = _smoothPressure(clampedPressure);
    }

    final point = StrokePoint(
      position: smoothedPosition,
      pressure: smoothedPressure,
      timestamp: now,
      pointerType: pointerType,
    );

    _currentStroke!.addPoint(point);
    _lastPosition = smoothedPosition;
    _lastPressure = smoothedPressure;
    _slotLastPosition[slot] = smoothedPosition;

    // ইনপুট ইভেন্ট পাঠানো
    _emitInputEvent(
      InputEventType.pointerMove, smoothedPosition, smoothedPressure, pointerType, slot, now,
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
    _releaseSlot(pointerId); // early return এর আগেই স্লট ছাড়া — নাহলে লিক হতো

    final now = DateTime.now();
    final upPosition = _lastPosition ??
        slotPosition ??
        (_currentStroke != null && _currentStroke!.points.isNotEmpty
            ? _currentStroke!.points.last.position
            : null);

    if (_isDrawing && _currentStroke != null) {
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
    // নাহলে PC তে বাটন চাপা থেকে যায়।
    if (slot != null) {
      _emitInputEvent(
        InputEventType.pointerUp, upPosition ?? Offset.zero, 0.0, pointerType, slot, now,
        buttons: buttons,
      );
    }

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