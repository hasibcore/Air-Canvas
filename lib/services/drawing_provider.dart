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
    if (pointerId < 0 || pointerId > 100) return; // Defensive pointerId check
    _isDrawing = true;

    final clampedPressure = pressure.isNaN || pressure.isInfinite ? 0.5 : pressure.clamp(0.0, 1.0);
    final now = DateTime.now();

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

    // Clear and init smoothing buffers
    _resetSmoothingBuffers();
    _positionBuffer.add(position);
    _pressureBuffer.add(clampedPressure);

    // ইনপুট ইভেন্ট জেনারেট ও পাঠানো
    _emitInputEvent(
      InputEventType.pointerDown, position, clampedPressure, pointerType, pointerId, now,
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
    if (pointerId < 0 || pointerId > 100) return; // Defensive pointerId check

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

    // ইনপুট ইভেন্ট পাঠানো
    _emitInputEvent(
      InputEventType.pointerMove, smoothedPosition, smoothedPressure, pointerType, pointerId, now,
      tiltX: tiltX, tiltY: tiltY, buttons: buttons,
    );

    // Only notify the canvas repaint notifier (avoids rebuilding the entire widget tree/toolbar)
    canvasNotifier.notify();
  }

  /// টাচ/পেন আপ - স্ট্রোক শেষ
  void onPointerUp({
    PointerType pointerType = PointerType.finger,
    int pointerId = 0,
    int buttons = 0,
  }) {
    if (!_isDrawing || _currentStroke == null) return;
    if (pointerId < 0 || pointerId > 100) return; // Defensive pointerId check

    _isDrawing = false;
    final now = DateTime.now();

    // Add final point using _lastPosition if available to ensure stroke completeness
    if (_lastPosition != null && _currentStroke!.points.isNotEmpty) {
      final lastPoint = StrokePoint(
        position: _lastPosition!,
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

    // ইনপুট ইভেন্ট পাঠানো
    if (_lastPosition != null) {
      _emitInputEvent(
        InputEventType.pointerUp, _lastPosition!, 0.0, pointerType, pointerId, now,
        buttons: buttons,
      );
    }

    canvasNotifier.notify();
    notifyListeners();
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
}