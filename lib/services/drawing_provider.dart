/// ড্রয়িং স্টেট ও লজিক ম্যানেজার
///
/// ক্যানভাসে ড্রয়িং সম্পর্কিত সব কিছু ম্যানেজ করে:
/// - স্ট্রোক কালেকশন
/// - প্রেশার সেনসিটিভিটি
/// - ব্রাশ সেটিংস
/// - অফলাইন ক্যানভাস রেন্ডারিং (client side mirror)

import 'package:flutter/material.dart';
import '../models/input_event.dart';

enum BrushMode {
  pen,      // সাধারণ পেন
  pencil,   // পেন্সিল (rougher)
  brush,    // ব্রাশ (thicker, opacity)
  eraser,   // ইরেজার
}

class BrushSettings {
  Color color;
  double baseWidth;
  double pressureSensitivity;  // 0.0 - 1.0, 0 = no pressure effect
  double opacity;
  BrushMode mode;
  bool smoothing;
  int smoothingStrength;

  BrushSettings({
    this.color = Colors.white,
    this.baseWidth = 3.0,
    this.pressureSensitivity = 0.7,
    this.opacity = 1.0,
    this.mode = BrushMode.pen,
    this.smoothing = true,
    this.smoothingStrength = 3,
  });

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
  final List<StrokePoint> points;
  final BrushSettings settings;
  final DateTime startTime;
  double _pressureSum = 0.0;

  Stroke({
    List<StrokePoint>? points,
    required this.settings,
    DateTime? startTime,
  })  : points = points ?? [],
        startTime = startTime ?? DateTime.now() {
    if (points != null) {
      for (final p in points) {
        _pressureSum += p.pressure;
      }
    }
  }

  void addPoint(StrokePoint point) {
    points.add(point);
    _pressureSum += point.pressure;
  }

  double get averagePressure => points.isEmpty ? 0.5 : _pressureSum / points.length;

  bool get isEmpty => points.isEmpty;
  bool get isSinglePoint => points.length == 1;

  /// স্ট্রোকের বাউন্ডিং বক্স
  Rect? get bounds {
    if (points.isEmpty) return null;
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in points) {
      if (p.position.dx < minX) minX = p.position.dx;
      if (p.position.dy < minY) minY = p.position.dy;
      if (p.position.dx > maxX) maxX = p.position.dx;
      if (p.position.dy > maxY) maxY = p.position.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}

class DrawingProvider extends ChangeNotifier {
  // --- State ---
  final List<Stroke> _strokes = [];
  Stroke? _currentStroke;
  BrushSettings _brushSettings = BrushSettings();
  bool _isDrawing = false;
  Offset? _lastPosition;
  double _canvasWidth = 1.0;
  double _canvasHeight = 1.0;
  bool _pressureSmoothing = true;
  double _lastPressure = 0.0;

  // Smoothing buffer
  final List<Offset> _positionBuffer = [];
  final List<double> _pressureBuffer = [];
  static const int _maxBufferSize = 5;

  // Callbacks
  void Function(InputEvent)? onInputGenerated;

  // Getters
  List<Stroke> get strokes => List.unmodifiable(_strokes);
  Stroke? get currentStroke => _currentStroke;
  BrushSettings get brushSettings => _brushSettings;
  bool get isDrawing => _isDrawing;
  Offset? get lastPosition => _lastPosition;

  void updateCanvasSize(double width, double height) {
    _canvasWidth = width;
    _canvasHeight = height;
    notifyListeners();
  }

  void updateBrush(BrushSettings settings) {
    _brushSettings = settings;
    notifyListeners();
  }

  /// টাচ/পেন ডাউন - নতুন স্ট্রোক শুরু
  void onPointerDown(Offset position, {
    double pressure = 0.5,
    PointerType pointerType = PointerType.finger,
    int pointerId = 0,
  }) {
    _isDrawing = true;

    final point = StrokePoint(
      position: position,
      pressure: pressure,
      timestamp: DateTime.now(),
      pointerType: pointerType,
    );

    _currentStroke = Stroke(settings: _brushSettings);
    _currentStroke!.addPoint(point);
    _lastPosition = position;
    _lastPressure = pressure;

    // Clear smoothing buffers
    _positionBuffer.clear();
    _pressureBuffer.clear();
    _positionBuffer.add(position);
    _pressureBuffer.add(pressure);

    // ইনপুট ইভেন্ট জেনারেট ও পাঠানো
    _emitInputEvent(InputEventType.pointerDown, position, pressure, pointerType, pointerId);

    notifyListeners();
  }

  /// টাচ/পেন মুভ - স্ট্রোক চালিয়ে যাওয়া
  void onPointerMove(Offset position, {
    double pressure = 0.5,
    PointerType pointerType = PointerType.finger,
    int pointerId = 0,
  }) {
    if (!_isDrawing || _currentStroke == null) return;

    Offset smoothedPosition = position;
    double smoothedPressure = pressure;

    // Smoothing apply করা
    if (_brushSettings.smoothing) {
      smoothedPosition = _smoothPosition(position);
      smoothedPressure = _smoothPressure(pressure);
    }

    final point = StrokePoint(
      position: smoothedPosition,
      pressure: smoothedPressure,
      timestamp: DateTime.now(),
      pointerType: pointerType,
    );

    _currentStroke!.addPoint(point);
    _lastPosition = smoothedPosition;
    _lastPressure = smoothedPressure;

    // ইনপুট ইভেন্ট পাঠানো
    _emitInputEvent(InputEventType.pointerMove, smoothedPosition, smoothedPressure, pointerType, pointerId);

    notifyListeners();
  }

  /// টাচ/পেন আপ - স্ট্রোক শেষ
  void onPointerUp({
    PointerType pointerType = PointerType.finger,
    int pointerId = 0,
  }) {
    if (!_isDrawing || _currentStroke == null) return;

    _isDrawing = false;

    // স্ট্রোক সেভ করা (minimum 1 point থাকলে)
    if (_currentStroke!.points.isNotEmpty) {
      _strokes.add(_currentStroke!);
    }
    _currentStroke = null;
    _positionBuffer.clear();
    _pressureBuffer.clear();

    // ইনপুট ইভেন্ট পাঠানো
    if (_lastPosition != null) {
      _emitInputEvent(InputEventType.pointerUp, _lastPosition!, 0.0, pointerType, pointerId);
    }

    notifyListeners();
  }

  /// ইনপুট ইভেন্ট জেনারেট ও callback এ পাঠানো
  void _emitInputEvent(
    InputEventType type,
    Offset position,
    double pressure,
    PointerType pointerType,
    int pointerId,
  ) {
    final normalizedX = (position.dx / _canvasWidth).clamp(0.0, 1.0);
    final normalizedY = (position.dy / _canvasHeight).clamp(0.0, 1.0);

    final event = InputEvent(
      type: type,
      x: normalizedX,
      y: normalizedY,
      pressure: pressure,
      pointerType: pointerType,
      pointerId: pointerId,
    );

    onInputGenerated?.call(event);
  }

  /// পজিশন স্মুথিং (Moving Average)
  Offset _smoothPosition(Offset position) {
    _positionBuffer.add(position);
    if (_positionBuffer.length > _maxBufferSize) {
      _positionBuffer.removeAt(0);
    }

    double sumX = 0, sumY = 0;
    // Weighted average - newer points have more weight
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
    final alpha = 0.4; // Smoothing factor
    _lastPressure = alpha * pressure + (1 - alpha) * _lastPressure;
    return _lastPressure;
  }

  /// আন্ডো - শেষ স্ট্রোক মুছে ফেলা
  void undo() {
    if (_strokes.isNotEmpty) {
      _strokes.removeLast();
      notifyListeners();
    }
  }

  /// সব স্ট্রোক মুছে ফেলা
  void clearCanvas() {
    _strokes.clear();
    _currentStroke = null;
    _isDrawing = false;
    notifyListeners();
  }
}