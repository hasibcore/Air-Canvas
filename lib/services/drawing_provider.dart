// Drawing State & Logic Manager
//
// Manages canvas drawing state:
// - Stroke collection
// - Pressure sensitivity
// - Brush settings
// - Offline canvas rendering (client-side mirror)

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/input_event.dart';
import 'one_euro_filter.dart';

/// Drawing accuracy & smoothing engine modes
enum PrecisionMode {
  /// Adaptive 1-Euro Filter (Casiez et al.): eliminates jitter at low speeds, zero lag on fast strokes.
  /// Recommended for precise handwriting and mathematical formulas.
  proAdaptive,

  /// Ultra Direct Raw (Unfiltered): zero filtering, direct hardware touch sensor data.
  rawDirect,

  /// Studio Art Stabilizer: smooth curves for slow artistic inking.
  studioSmooth,
}

/// Pressure response curves
enum PressureCurve {
  /// 1:1 linear response
  standard,

  /// Soft touch response for capacitive pens (Gamma 0.7)
  soft,

  /// High control for precise calligraphy (Gamma 1.4)
  firm,

  /// Sigmoid S-Curve (Hermite smoothstep)
  sCurve;

  /// Transforms pressure input ensuring 0.0 .. 1.0 range
  double transform(double rawPressure) {
    final p = rawPressure.clamp(0.0, 1.0);
    switch (this) {
      case PressureCurve.soft:
        return math.pow(p, 0.7).toDouble().clamp(0.0, 1.0);
      case PressureCurve.firm:
        return math.pow(p, 1.4).toDouble().clamp(0.0, 1.0);
      case PressureCurve.sCurve:
        return (p * p * (3.0 - 2.0 * p)).clamp(0.0, 1.0);
      case PressureCurve.standard:
        return p;
    }
  }
}

/// Explicit pointer/pen lifecycle state machine: IDLE -> DOWN -> MOVING -> UP -> IDLE
enum PenState {
  idle,
  down,
  moving,
}

/// PC handwriting size & scale presets
enum WritingScalePreset {
  /// Compact note size (natural notebook size - 50%)
  compact,

  /// Balanced note size (whiteboard and presentation - 75%)
  medium,

  /// Full screen (100% monitor coverage)
  full,
}

/// Screen writing anchor position
enum WritingAnchor {
  topLeft,
  center,
}

enum BrushMode {
  pen,      // Standard pen
  pencil,   // Pencil (rougher)
  brush,    // Brush (thicker, opacity)
  eraser,   // Eraser
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
  final double width;

  StrokePoint({
    required this.position,
    required this.pressure,
    required this.timestamp,
    this.pointerType = PointerType.finger,
    this.width = 3.0,
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

  /// High-Fidelity Variable-Width Spline Renderer with seamless C1 Bézier midpoints
  void draw(Canvas canvas) {
    if (_points.isEmpty) return;
    if (_points.length == 1) {
      final point = _points.first;
      final w = point.width > 0 ? point.width : settings.baseWidth;
      final p = Paint()
        ..color = settings.mode == BrushMode.eraser
            ? const Color(0xFF0A0A12)
            : settings.color.withValues(alpha: settings.opacity.clamp(0.0, 1.0))
        ..style = PaintingStyle.fill;
      canvas.drawCircle(point.position, w / 2, p);
      return;
    }

    if (settings.pressureSensitivity <= 0.05 || _points.length < 3) {
      canvas.drawPath(path, paint);
      return;
    }

    // High-Fidelity Variable Width Spline Rendering
    final baseColor = settings.mode == BrushMode.eraser
        ? const Color(0xFF0A0A12)
        : settings.color.withValues(alpha: settings.opacity.clamp(0.0, 1.0));

    MaskFilter? maskFilter;
    if (settings.mode == BrushMode.brush) {
      maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    }

    for (int i = 0; i < _points.length - 1; i++) {
      final p1 = _points[i];
      final p2 = _points[i + 1];
      final segWidth = math.max(0.8, (p1.width + p2.width) / 2.0);

      final segPaint = Paint()
        ..color = baseColor
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..strokeWidth = settings.mode == BrushMode.pencil ? segWidth * 0.7 : segWidth;

      if (maskFilter != null) segPaint.maskFilter = maskFilter;

      if (i == 0) {
        canvas.drawLine(p1.position, (p1.position + p2.position) / 2, segPaint);
      } else if (i == _points.length - 2) {
        final prevMid = (_points[i - 1].position + p1.position) / 2;
        final segPath = Path()
          ..moveTo(prevMid.dx, prevMid.dy)
          ..quadraticBezierTo(p1.position.dx, p1.position.dy, p2.position.dx, p2.position.dy);
        canvas.drawPath(segPath, segPaint);
      } else {
        final prevMid = (_points[i - 1].position + p1.position) / 2;
        final nextMid = (p1.position + p2.position) / 2;
        final segPath = Path()
          ..moveTo(prevMid.dx, prevMid.dy)
          ..quadraticBezierTo(p1.position.dx, p1.position.dy, nextMid.dx, nextMid.dy);
        canvas.drawPath(segPath, segPaint);
      }
    }
  }

  double get averagePressure {
    if (_points.isEmpty) return 0.5;
    final avg = _pressureSum / _points.length;
    return avg.isNaN || avg.isInfinite ? 0.5 : avg.clamp(0.0, 1.0);
  }

  bool get isEmpty => _points.isEmpty;
  bool get isSinglePoint => _points.length == 1;

  /// Stroke bounding box
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
  PenState _penState = PenState.idle;
  PenState get penState => _penState;

  // Pro Precision & Jitter Filter Engine (1-Euro Filter)
  PrecisionMode _precisionMode = PrecisionMode.proAdaptive;
  PressureCurve _pressureCurve = PressureCurve.standard;
  // Tuned: minCutoff 0.85 Hz for zero jitter on slow/fine strokes, beta 0.015 for instant 0-lag flick tracking
  final OneEuroFilter2D _oneEuroFilter = OneEuroFilter2D(minCutoff: 0.85, beta: 0.015);

  // PC Output Writing Scale & Aspect Ratio Compensation
  // Default 1.0: 100% Full Screen Graphics Tablet mode (1:1 full monitor coverage)
  double _writingScale = 1.0;
  WritingAnchor _writingAnchor = WritingAnchor.center;
  double _serverAspectRatio = 16.0 / 9.0;

  // Canvas Mode: 16:9 PC Fit (false, default: zero distortion, perfect circles on laptop) vs Full Phone (true: stretched)
  bool _fullScreenTabletMode = false;
  bool get fullScreenTabletMode => _fullScreenTabletMode;
  set fullScreenTabletMode(bool val) {
    if (_fullScreenTabletMode != val) {
      _fullScreenTabletMode = val;
      notifyListeners();
    }
  }

  // --- Custom Drawing Box (Active Work Area / ROI) ---
  bool _customBoxEnabled = false;
  Rect _customBoxNormalized = const Rect.fromLTRB(0.12, 0.12, 0.88, 0.88);
  bool _isEditingCustomBox = false;
  bool _isSnippingBox = false;
  bool _boxMapsToFullScreen = false;

  bool get customBoxEnabled => _customBoxEnabled;
  set customBoxEnabled(bool val) {
    if (_customBoxEnabled != val) {
      _customBoxEnabled = val;
      notifyListeners();
    }
  }

  bool get isSnippingBox => _isSnippingBox;
  set isSnippingBox(bool val) {
    if (_isSnippingBox != val) {
      _isSnippingBox = val;
      notifyListeners();
    }
  }

  void resetToFullScreen() {
    _customBoxEnabled = false;
    _isSnippingBox = false;
    _isEditingCustomBox = false;
    _writingScale = 1.0;
    _customBoxNormalized = const Rect.fromLTRB(0.0, 0.0, 1.0, 1.0);
    notifyListeners();
  }

  Rect get customBoxNormalized => _customBoxNormalized;
  void setCustomBoxNormalized(Rect rect) {
    final l = math.min(rect.left, rect.right).clamp(0.0, 0.95);
    final t = math.min(rect.top, rect.bottom).clamp(0.0, 0.95);
    final r = math.max(rect.left, rect.right).clamp(l + 0.05, 1.0);
    final b = math.max(rect.top, rect.bottom).clamp(t + 0.05, 1.0);
    _customBoxNormalized = Rect.fromLTRB(l, t, r, b);
    notifyListeners();
  }

  bool get isEditingCustomBox => _isEditingCustomBox;
  set isEditingCustomBox(bool val) {
    if (_isEditingCustomBox != val) {
      _isEditingCustomBox = val;
      notifyListeners();
    }
  }

  bool get boxMapsToFullScreen => _boxMapsToFullScreen;
  set boxMapsToFullScreen(bool val) {
    if (_boxMapsToFullScreen != val) {
      _boxMapsToFullScreen = val;
      notifyListeners();
    }
  }

  /// Preset selection for Custom Drawing Box
  void setCustomBoxPreset(String preset) {
    switch (preset) {
      case 'center_75':
        setCustomBoxNormalized(const Rect.fromLTRB(0.125, 0.125, 0.875, 0.875));
        break;
      case 'center_50':
        setCustomBoxNormalized(const Rect.fromLTRB(0.25, 0.25, 0.75, 0.75));
        break;
      case 'top_half':
        setCustomBoxNormalized(const Rect.fromLTRB(0.05, 0.05, 0.95, 0.50));
        break;
      case 'bottom_half':
        setCustomBoxNormalized(const Rect.fromLTRB(0.05, 0.50, 0.95, 0.95));
        break;
      case 'left_half':
        setCustomBoxNormalized(const Rect.fromLTRB(0.05, 0.05, 0.50, 0.95));
        break;
      case 'right_half':
        setCustomBoxNormalized(const Rect.fromLTRB(0.50, 0.05, 0.95, 0.95));
        break;
      case 'full':
        setCustomBoxNormalized(const Rect.fromLTRB(0.0, 0.0, 1.0, 1.0));
        break;
    }
  }

  // --- Pro Features: Stylus-Only Inking & Predictive Tracking ---
  bool _stylusOnlyMode = false;
  bool _enablePrediction = true;
  Offset? _predictedPosition;
  Offset _currentVelocity = Offset.zero;

  bool get stylusOnlyMode => _stylusOnlyMode;
  set stylusOnlyMode(bool val) {
    if (_stylusOnlyMode != val) {
      _stylusOnlyMode = val;
      notifyListeners();
    }
  }

  bool get enablePrediction => _enablePrediction;
  set enablePrediction(bool val) {
    if (_enablePrediction != val) {
      _enablePrediction = val;
      notifyListeners();
    }
  }

  Offset? get predictedPosition => _predictedPosition;
  Offset get currentVelocity => _currentVelocity;

  // --- Pro Telemetry & Real-Time Performance HUD ---
  bool _showPerformanceHUD = true;
  double _liveFps = 120.0;
  double _livePollingRateHz = 240.0;
  int _frameCount = 0;
  DateTime _lastFpsTimestamp = DateTime.now();
  int _inputSampleCount = 0;
  DateTime _lastPollingTimestamp = DateTime.now();
  final ValueNotifier<int> metricNotifier = ValueNotifier<int>(0);

  bool get showPerformanceHUD => _showPerformanceHUD;
  set showPerformanceHUD(bool val) {
    if (_showPerformanceHUD != val) {
      _showPerformanceHUD = val;
      notifyListeners();
    }
  }

  double get liveFps => _liveFps;
  double get livePollingRateHz => _livePollingRateHz;

  void recordFrame() {
    _frameCount++;
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastFpsTimestamp).inMilliseconds;
    if (elapsedMs >= 500) {
      _liveFps = (_frameCount * 1000.0 / elapsedMs).clamp(1.0, 240.0);
      _frameCount = 0;
      _lastFpsTimestamp = now;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        metricNotifier.value++;
      });
    }
  }

  void _recordInputSample() {
    _inputSampleCount++;
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastPollingTimestamp).inMilliseconds;
    if (elapsedMs >= 500) {
      _livePollingRateHz = (_inputSampleCount * 1000.0 / elapsedMs).clamp(1.0, 1000.0);
      _inputSampleCount = 0;
      _lastPollingTimestamp = now;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        metricNotifier.value++;
      });
    }
  }

  // Smoothing buffer
  final List<Offset> _positionBuffer = [];
  final List<double> _pressureBuffer = [];

  // --- Pointer slot mapping ---
  //
  // Flutter PointerEvent.pointer is a process-global counter that increments
  // with every touch/hover/scroll. Previously pointerId > 100 caused events to be dropped.
  // Now active pointers are dynamically mapped to reusable 0..15 slots, preventing
  // wire pointerId overflow and allowing accurate multi-touch tracking.
  // Active pointers release slots upon pointerUp/cancel.
  //
  //
  // Desktop has a single cursor. Multiple pointers (stylus, palm, fingers)
  // are disambiguated by palm rejection rules:
  // - If idle, first touching pointer gains ownership.
  // - If drawing with finger and stylus touches, stylus takes precedence and finger emits pointerUp.
  static const int maxPointerSlots = 16;
  final Map<int, int> _pointerSlots = <int, int>{};
  final Map<int, Offset> _slotLastPosition = <int, Offset>{};

  // --- Palm rejection / single-cursor arbitration ---
  //
  // - If drawing with stylus and finger touches, finger is rejected as palm.
  // - Finger touches are suppressed for 400ms after stylus lifts (palm lift delay).
  // - Secondary pointers of the same kind are ignored (single desktop cursor).
  //
  //
  // Palm rejection rules:
  //   • When idle: first active pointer becomes stroke owner.
  //   • Finger drawing + stylus touches: stylus wins, pointerUp emitted for finger.
  //   • Stylus drawing + finger touches: finger ignored as palm.
  //   • Stylus lifted: finger ignored for 400ms cooldown.
  //   • Secondary pointer of same kind: ignored.
  //
  // Ignored pointers still receive slots to track pointerUp, but send no wire packets.
  //
  //
  static const Duration stylusGracePeriod = Duration(milliseconds: 400);
  bool _palmRejection = true;
  int? _drawingPointer;
  final Map<int, PointerType> _pointerKinds = <int, PointerType>{};
  DateTime? _lastStylusActivity;

  /// Maps raw pointer IDs that sent pointerDown to their assigned wire slot.
  /// Ensures pointerDown is always balanced by a matching pointerUp.
  ///
  /// Guarantees PC mouse/pen buttons are never stuck pressed.
  /// Prevents premature button release mid-stroke.
  ///
  /// Slot is recorded during down so up transmits on identical slot
  /// even if slot allocation changes.
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

  /// Determines whether pointer is granted drawing ownership.
  bool _claimOnDown(int rawPointerId, PointerType kind, DateTime now) {
    if (!_palmRejection) {
      _drawingPointer ??= rawPointerId;
      return _drawingPointer == rawPointerId;
    }

    final current = _drawingPointer;
    if (current == null) {
    if (!_isPen(kind) && _stylusRecentlyActive) return false; // Palm rejection
      _drawingPointer = rawPointerId;
      return true;
    }
    if (current == rawPointerId) return true;

    final currentKind = _pointerKinds[current] ?? PointerType.finger;
    if (_isPen(kind) && !_isPen(currentKind)) {
      _yieldOwnershipTo(rawPointerId, now);
      return true;
    }
    return false; // Secondary pointer rejection
  }

  /// Yields stroke ownership to newPointerId and emits pointerUp for previous pointer.
  /// Prevents stuck buttons on PC when switching pointers.
  void _yieldOwnershipTo(int newPointerId, DateTime now) {
    final old = _drawingPointer;
    _drawingPointer = newPointerId;
    if (old == null) return;

    // Emits pointerUp using recorded slot even if slot was reclaimed.
    // Guarantees desktop button release.
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

  /// Emits pointerUp for rawPointerId if pointerDown was previously sent.
  /// Removes tracking record so duplicate pointerUp is never sent.
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

  /// Returns existing or newly allocated slot for rawPointerId.
  ///
  /// If all slots are full, reclaims oldest slot to avoid lockup.
  /// Prevents drawing failure if pointerUp was missed during app backgrounding.
  ///
  /// Avoids legacy pointerId > 100 bug.
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

    // Insertion-ordered map ensures first key is oldest pointer.
    final stalest = _pointerSlots.keys.first;
    final reclaimed = _pointerSlots.remove(stalest)!;
    // Emits pointerUp prior to slot eviction to prevent stuck button.
    // Captures last known position before removing record.
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

  /// Releases all pointer state (canvas clear, dispose, remote reset).
  ///
  /// If flushPendingUps is true, emits pointerUp for active pointers
  /// to prevent stuck buttons on PC.
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
    _penState = PenState.idle;
  }

  /// Active pointer count for UI diagnostics and debugging.
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

  /// High-performance graphics tablet mode:
  /// Streams raw touch coordinates with zero latency for responsive whiteboard writing.
  /// Ensures crisp handwritten notes and mathematical equations without distortion.
  ///
  PrecisionMode get precisionMode => _precisionMode;

  set precisionMode(PrecisionMode mode) {
    if (_precisionMode != mode) {
      _precisionMode = mode;
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

  /// High-performance graphics tablet mode (Backwards-compatible API)
  bool get directTabletMode => _precisionMode != PrecisionMode.studioSmooth;

  set directTabletMode(bool val) {
    precisionMode = val ? PrecisionMode.proAdaptive : PrecisionMode.studioSmooth;
  }

  /// PC handwriting size / output scale (0.25 - 1.0)
  double get writingScale => _writingScale;

  set writingScale(double val) {
    final clamped = val.clamp(0.25, 1.0);
    if ((_writingScale - clamped).abs() > 0.001) {
      _writingScale = clamped;
      notifyListeners();
    }
  }

  /// Screen writing anchor position (Top-Left or Center)
  WritingAnchor get writingAnchor => _writingAnchor;

  set writingAnchor(WritingAnchor anchor) {
    if (_writingAnchor != anchor) {
      _writingAnchor = anchor;
      notifyListeners();
    }
  }

  /// Updates native PC display aspect ratio
  void updateServerAspectRatio(double ratio) {
    if (ratio > 0.1 && (_serverAspectRatio - ratio).abs() > 0.01) {
      _serverAspectRatio = ratio;
      notifyListeners();
    }
  }

  /// Selects preset (Compact, Balanced, Full)
  void setWritingScalePreset(WritingScalePreset preset) {
    switch (preset) {
      case WritingScalePreset.compact:
        writingScale = 0.50;
        break;
      case WritingScalePreset.medium:
        writingScale = 0.75;
        break;
      case WritingScalePreset.full:
        writingScale = 1.0;
        break;
    }
  }

  WritingScalePreset get currentScalePreset {
    if ((_writingScale - 1.0).abs() < 0.08) return WritingScalePreset.full;
    if ((_writingScale - 0.75).abs() < 0.08) return WritingScalePreset.medium;
    if ((_writingScale - 0.50).abs() < 0.08) return WritingScalePreset.compact;
    return WritingScalePreset.full;
  }

  void setCanvasDimensionsSilently(double width, double height) {
    if (width > 0) _canvasWidth = width;
    if (height > 0) _canvasHeight = height;
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

  /// Generates and sends input event via callback using ONE Authoritative Coordinate Contract:
  /// Phone Raw Space -> Normalized Space [0.0, 1.0] -> Desktop Canvas/Monitor Space -> Native OS Input Space.
  /// Preserves 1:1 circular aspect ratio uniformly without dual conflicting corrections.
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
    double rawNormX = (position.dx / w).clamp(0.0, 1.0);
    double rawNormY = (position.dy / h).clamp(0.0, 1.0);

    // If Custom Drawing Box is active and maps to full PC screen, re-normalize
    if (_customBoxEnabled && _boxMapsToFullScreen) {
      final boxW = _customBoxNormalized.width <= 0 ? 1.0 : _customBoxNormalized.width;
      final boxH = _customBoxNormalized.height <= 0 ? 1.0 : _customBoxNormalized.height;
      final boxNormX = ((rawNormX - _customBoxNormalized.left) / boxW).clamp(0.0, 1.0);
      final boxNormY = ((rawNormY - _customBoxNormalized.top) / boxH).clamp(0.0, 1.0);

      final event = InputEvent(
        type: type,
        x: boxNormX,
        y: boxNormY,
        pressure: pressure,
        pointerType: pointerType,
        pointerId: pointerId,
        tiltX: tiltX,
        tiltY: tiltY,
        buttons: buttons,
        timestamp: timestamp,
      );
      onInputGenerated?.call(event);
      return;
    }

    // Authoritative Single Transform Contract:
    // 1. Full-screen Graphics Tablet Mode (Default writingScale == 1.0):
    //    Mobile [0.0..1.0] maps 1:1 directly to PC [0.0..1.0].
    //    Left (0.0) -> Left (0.0), Center (0.5) -> Center (0.5), Right (1.0) -> Right (1.0).
    //    Entire PC screen is 100% reachable without arbitrary offsets.
    // 2. Scaled Note Mode (writingScale < 0.99):
    //    Scales stroke within selected anchor for compact handwriting when explicitly chosen.
    double normalizedX = rawNormX;
    double normalizedY = rawNormY;

    if (_writingScale < 0.99) {
      final scale = _writingScale.clamp(0.25, 1.0);
      double offsetX = 0.0;
      double offsetY = 0.0;
      if (_writingAnchor == WritingAnchor.center) {
        offsetX = ((1.0 - scale) / 2.0).clamp(0.0, 1.0);
        offsetY = ((1.0 - scale) / 2.0).clamp(0.0, 1.0);
      }
      normalizedX = (offsetX + rawNormX * scale).clamp(0.0, 1.0);
      normalizedY = (offsetY + rawNormY * scale).clamp(0.0, 1.0);
    }

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
    onInputGenerated?.call(event);
  }

  /// Touch/Pen down - starts new stroke
  void onPointerDown(Offset position, {
    double pressure = 0.5,
    PointerType pointerType = PointerType.finger,
    int pointerId = 0,
    double tiltX = 0.0,
    double tiltY = 0.0,
    int buttons = 0,
  }) {
    if (pointerId < 0) return; // Defensive pointerId check
    if (_isSnippingBox || _isEditingCustomBox) return; // Don't draw while snipping or editing box

    // Stylus-Only Inking Mode (Strict Palm Rejection: Finger touch never inks)
    if (_stylusOnlyMode && !_isPen(pointerType)) {
      return;
    }

    final w = _canvasWidth <= 0 ? 1.0 : _canvasWidth;
    final h = _canvasHeight <= 0 ? 1.0 : _canvasHeight;
    final normX = (position.dx / w).clamp(0.0, 1.0);
    final normY = (position.dy / h).clamp(0.0, 1.0);

    // Custom Drawing Box gating: ignore touches outside the designated box
    if (_customBoxEnabled && !_customBoxNormalized.contains(Offset(normX, normY))) {
      return;
    }

    // Pen State Machine: ensure clean transition from idle BEFORE acquiring slot
    if (_penState != PenState.idle && _pendingUpSlots.isEmpty) {
      _releaseAllSlots(flushPendingUps: true);
    }

    // Map Flutter global pointer id to compact slot (0..15)
    final slot = _acquireSlot(pointerId);
    if (slot < 0) return; // All 16 slots busy

    final now = DateTime.now();
    _pointerKinds[pointerId] = pointerType;
    if (_isPen(pointerType)) _lastStylusActivity = now;

    // Palm / secondary finger rejected here - slot tracked for up
    // but stroke does not start and no packet sent to wire.
    if (!_claimOnDown(pointerId, pointerType, now)) {
      _slotLastPosition[slot] = position;
      return;
    }

    _penState = PenState.down;

    _isDrawing = true;
    _currentVelocity = Offset.zero;
    _predictedPosition = null;
    _recordInputSample();

    final clampedPressure = pressure.isNaN || pressure.isInfinite ? 0.5 : pressure.clamp(0.0, 1.0);
    final calibratedPressure = _applyPressureCurve(clampedPressure);

    _resetSmoothingBuffers();
    final dynamicWidth = _brushSettings.baseWidth *
        (0.25 + calibratedPressure * 0.75 * _brushSettings.pressureSensitivity);
    final point = StrokePoint(
      position: position,
      pressure: calibratedPressure,
      timestamp: now,
      pointerType: pointerType,
      width: dynamicWidth,
    );

    _currentStroke = Stroke(settings: _brushSettings, startTime: now);
    _currentStroke!.addPoint(point);
    _lastPosition = position;
    _lastPressure = calibratedPressure;
    _slotLastPosition[slot] = position;

    _positionBuffer.add(position);
    _pressureBuffer.add(calibratedPressure);

    // Generate and send input event
    _emitInputEvent(
      InputEventType.pointerDown, position, calibratedPressure, pointerType, slot, now,
      tiltX: tiltX, tiltY: tiltY, buttons: buttons,
    );
    // pointerDown sent - pointerUp is now required upon completion.
    _pendingUpSlots[pointerId] = slot;

    canvasNotifier.notify();
    notifyListeners();
  }

  /// Touch/Pen move - continues stroke
  void onPointerMove(Offset position, {
    double pressure = 0.5,
    PointerType pointerType = PointerType.finger,
    int pointerId = 0,
    double tiltX = 0.0,
    double tiltY = 0.0,
    int buttons = 0,
  }) {
    if (!_isDrawing || _currentStroke == null || _penState == PenState.idle) return;
    if (pointerId < 0) return; // Defensive pointerId check
    if (_isSnippingBox || _isEditingCustomBox) return; // Ignore drawing while snipping or editing box

    // Stylus-Only Inking Mode
    if (_stylusOnlyMode && !_isPen(pointerType)) {
      return;
    }

    // Palm / secondary finger moves ignored (single cursor)
    if (_drawingPointer != null && _drawingPointer != pointerId) return;
    // Re-allocate slot if down was missed to prevent lost stroke
    final slot = _pointerSlots[pointerId] ?? _acquireSlot(pointerId);
    if (slot < 0) return;
    _drawingPointer ??= pointerId;
    _pointerKinds[pointerId] = pointerType;
    if (_isPen(pointerType)) _lastStylusActivity = DateTime.now();

    // Pen State Machine: transition down -> moving
    _penState = PenState.moving;

    final clampedPressure = pressure.isNaN || pressure.isInfinite ? 0.5 : pressure.clamp(0.0, 1.0);
    final now = DateTime.now();
    _recordInputSample();

    // Custom Drawing Box gating & boundary clamping
    final w = _canvasWidth <= 0 ? 1.0 : _canvasWidth;
    final h = _canvasHeight <= 0 ? 1.0 : _canvasHeight;
    Offset boundedPosition = position;
    if (_customBoxEnabled) {
      final minX = _customBoxNormalized.left * w;
      final maxX = _customBoxNormalized.right * w;
      final minY = _customBoxNormalized.top * h;
      final maxY = _customBoxNormalized.bottom * h;
      boundedPosition = Offset(
        position.dx.clamp(minX, maxX),
        position.dy.clamp(minY, maxY),
      );
    }

    // 1. Pro Precision filtering (1-Euro Adaptive vs Studio Smooth vs Raw Direct)
    // Preserves 100% of raw digitizer points without artificial threshold dropping
    Offset precisionPosition = boundedPosition;
    if (_precisionMode == PrecisionMode.proAdaptive) {
      precisionPosition = _oneEuroFilter.filter(boundedPosition, now);
    } else if (_precisionMode == PrecisionMode.studioSmooth) {
      precisionPosition = _smoothPosition(boundedPosition);
    } else {
      precisionPosition = boundedPosition;
    }

    // 2. Pro Pressure curve calibration & smoothing
    double calibratedPressure = _applyPressureCurve(clampedPressure);
    if (_brushSettings.smoothing && _precisionMode != PrecisionMode.rawDirect) {
      calibratedPressure = _smoothPressure(calibratedPressure);
    }

    // 3. Dynamic width calculation per point
    final dynamicWidth = _brushSettings.baseWidth *
        (0.25 + calibratedPressure * 0.75 * _brushSettings.pressureSensitivity);

    // 4. Predictive Lead-Point Tracking (Extrapolates 5-8ms forward to eliminate visual scanout latency)
    if (_currentStroke!.points.isNotEmpty) {
      final lastPt = _currentStroke!.points.last;
      final dt = now.difference(lastPt.timestamp).inMicroseconds / 1000000.0;
      if (dt > 0.001) {
        final instantVel = (precisionPosition - lastPt.position) / dt;
        _currentVelocity = _currentVelocity * 0.35 + instantVel * 0.65;
        if (_enablePrediction && _currentVelocity.distance > 15.0) {
          const leadSecs = 0.006; // 6 milliseconds ahead
          _predictedPosition = precisionPosition + _currentVelocity * leadSecs;
        } else {
          _predictedPosition = null;
        }
      }
    }

    final point = StrokePoint(
      position: precisionPosition,
      pressure: calibratedPressure,
      timestamp: now,
      pointerType: pointerType,
      width: dynamicWidth,
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

  /// Touch/Pen up - finishes stroke
  void onPointerUp({
    PointerType pointerType = PointerType.finger,
    int pointerId = 0,
    int buttons = 0,
  }) {
    if (pointerId < 0) return; // Defensive pointerId check

    final slot = _pointerSlots[pointerId];
    final slotPosition = slot == null ? null : _slotLastPosition[slot];
    final downSlot = _pendingUpSlots.remove(pointerId);
    if (_isPen(_pointerKinds[pointerId] ?? pointerType)) {
      _lastStylusActivity = DateTime.now();
    }
    final ownedStroke = _drawingPointer == null || _drawingPointer == pointerId;
    if (ownedStroke) {
      _penState = PenState.idle;
    }
    _releaseSlot(pointerId);

    // Clear prediction & velocity
    _predictedPosition = null;
    _currentVelocity = Offset.zero;

    if (downSlot == null) {
      if (ownedStroke) {
        _isDrawing = false;
        _currentStroke = null;
      }
      return;
    }

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
        final dynamicWidth = _brushSettings.baseWidth *
            (0.25 + _lastPressure * 0.75 * _brushSettings.pressureSensitivity);
        final lastPoint = StrokePoint(
          position: upPosition,
          pressure: _lastPressure,
          timestamp: now,
          pointerType: pointerType,
          width: dynamicWidth,
        );
        _currentStroke!.addPoint(lastPoint);
      }

      // Save stroke if at least 1 point exists
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

    _emitInputEvent(
      InputEventType.pointerUp, upPosition ?? Offset.zero, 0.0, pointerType, downSlot, now,
      buttons: buttons,
    );

    canvasNotifier.notify();
    notifyListeners();
  }

  /// Cancels active stroke safely upon pointer cancellation or loss of window focus
  void onPointerCancel({
    PointerType pointerType = PointerType.finger,
    int pointerId = 0,
    int buttons = 0,
  }) {
    if (_pendingUpSlots.containsKey(pointerId)) {
      onPointerUp(pointerType: pointerType, pointerId: pointerId, buttons: buttons);
    } else {
      _releaseAllSlots(flushPendingUps: true);
      _currentStroke = null;
      _isDrawing = false;
      _penState = PenState.idle;
      _lastPosition = null;
      _predictedPosition = null;
      _currentVelocity = Offset.zero;
      _resetSmoothingBuffers();
      canvasNotifier.notify();
      notifyListeners();
    }
  }

  /// Fully resets drawing session upon disconnect, window change, or remote reset
  void resetDrawingSession() {
    _releaseAllSlots(flushPendingUps: false);
    _currentStroke = null;
    _isDrawing = false;
    _penState = PenState.idle;
    _lastPosition = null;
    _predictedPosition = null;
    _currentVelocity = Offset.zero;
    _resetSmoothingBuffers();
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

    final dynamicWidth = _brushSettings.baseWidth *
        (0.25 + event.pressure * 0.75 * _brushSettings.pressureSensitivity);

    if (event.type == InputEventType.pointerDown) {
      _isDrawing = true;
      _resetSmoothingBuffers();
      final point = StrokePoint(
        position: pos,
        pressure: event.pressure,
        timestamp: event.timestamp,
        pointerType: event.pointerType,
        width: dynamicWidth,
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
        width: dynamicWidth,
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

  /// Position smoothing (Moving Average based on brushSettings.smoothingStrength)
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

  /// Pressure smoothing (Exponential Moving Average)
  double _smoothPressure(double pressure) {
    if (!_pressureSmoothing) return pressure;
    const alpha = 0.4; // Smoothing factor
    _lastPressure = alpha * pressure + (1 - alpha) * _lastPressure;
    return _lastPressure.clamp(0.0, 1.0);
  }

  /// Whether there are strokes available to undo (Bug 146)
  bool get canUndo => _strokes.isNotEmpty;

  /// Undo - removes last stroke
  void undo() {
    if (_strokes.isNotEmpty) {
      _strokes.removeLast();
      _resetSmoothingBuffers();
      canvasNotifier.notify();
      notifyListeners();
    }
  }

  /// Clears all strokes
  void clearCanvas() {
    _strokes.clear();
    _currentStroke = null;
    _isDrawing = false;
    _resetSmoothingBuffers();

    // Pointer may still touch screen. Emit pending pointerUp
    // to release PC buttons immediately.
    //
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
    // Release pointer slot map and canvas notifier
    // to prevent stale pointerId state across hot restarts.
    _releaseAllSlots();
    canvasNotifier.dispose();
    super.dispose();
  }
}