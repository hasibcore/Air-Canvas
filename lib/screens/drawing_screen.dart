// ড্রয়িং স্ক্রিন - পুরো স্ক্রিন ড্রয়িং ক্যানভাস
//
// এই স্ক্রিন মোবাইল/ট্যাবে পুরো স্ক্রিন জুড়ে একটি ড্রয়িং এরিয়া দেখায়।
// টাচ ইনপুট ক্যাপচার করে WebSocket এর মাধ্যমে সার্ভারে পাঠায়।
// স্টাইলাস সাপোর্ট সহ pressure-sensitive ড্রয়িং।

import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/input_event.dart';
import '../services/connection_provider.dart';
import '../services/drawing_provider.dart';
import '../widgets/toolbar_widget.dart';
import '../widgets/connection_floating_button.dart';

class DrawingScreen extends StatefulWidget {
  const DrawingScreen({super.key});

  @override
  State<DrawingScreen> createState() => _DrawingScreenState();
}

class _DrawingScreenState extends State<DrawingScreen> {
  bool _showToolbar = true;
  Timer? _hideToolbarTimer;

  // Track last canvas dimensions to detect updates (Bug 81)
  double? _lastWidth;
  double? _lastHeight;

  // Track if stylus support has already been registered (Bug 92)
  bool _stylusSupportDetected = false;

  // Default fallback pressure constant (Bug 93)
  static const double _defaultPressure = 0.5;

  // Hint text localized helper (Bug 94)
  String get _tapToShowToolbarHint => 'Tap to show toolbar';

  @override
  void initState() {
    super.initState();
    _initWakelock(); // Await safely (Bug 85)

    // ল্যান্ডস্কেপ মোড
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // Full screen
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // DrawingProvider এ ইনপুট ইভেন্ট callback সেট করা
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final drawing = context.read<DrawingProvider>();
      final connection = context.read<ConnectionProvider>();
      drawing.onInputGenerated = (event) {
        connection.sendInputEvent(event);
      };
    });

    // Auto-hide toolbar
    _resetToolbarTimer();
  }

  // Await and handle Wakelock (Bug 85)
  Future<void> _initWakelock() async {
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('Error enabling wakelock: $e');
    }
  }

  Future<void> _disposeWakelock() async {
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('Error disabling wakelock: $e');
    }
  }

  @override
  void dispose() {
    _disposeWakelock(); // Await safely (Bug 85)
    // Reset preferred orientations to empty/default to restore auto-rotate behavior (Bug 86)
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _hideToolbarTimer?.cancel();
    super.dispose();
  }

  void _resetToolbarTimer() {
    _hideToolbarTimer?.cancel();
    _hideToolbarTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _showToolbar) { // Only set state if toolbar is actually visible (Bug 87, 95)
        setState(() => _showToolbar = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Watch providers granularly inside consumers to prevent whole screen rebuilds (Bug 88, 89)
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A12),
      body: Stack(
        children: [
          // Drawing Canvas
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Canvas size dynamically updates when constraints change (Bug 81)
                if (_lastWidth != constraints.maxWidth || _lastHeight != constraints.maxHeight) {
                  _lastWidth = constraints.maxWidth;
                  _lastHeight = constraints.maxHeight;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      context.read<DrawingProvider>().updateCanvasSize(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          );
                    }
                  });
                }
                return Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  onPointerCancel: _onPointerCancel,
                  child: Container(
                    color: const Color(0xFF0A0A12),
                    child: CustomPaint(
                      painter: DrawingPainter(
                        drawingProvider: context.read<DrawingProvider>(),
                      ),
                      size: Size.infinite,
                    ),
                  ),
                );
              },
            ),
          ),

          // Grid overlay (subtle, optimized with RepaintBoundary and const to prevent grid repaint) (Bug 91)
          const Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: GridPainter(),
                  size: Size.infinite,
                ),
              ),
            ),
          ),

          // Toolbar (animated, wrapped in granular Consumer to prevent whole screen rebuilds) (Bug 88, 89)
          if (_showToolbar)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Consumer2<DrawingProvider, ConnectionProvider>(
                builder: (context, drawing, connection, child) {
                  return ToolbarWidget(
                    brushSettings: drawing.brushSettings,
                    onBrushChanged: (settings) => drawing.updateBrush(settings),
                    onUndo: () => drawing.undo(),
                    onClear: () => drawing.clearCanvas(),
                    onDisconnect: () {
                      connection.disconnect();
                      Navigator.of(context).pop();
                    },
                    isConnected: connection.isConnected,
                    latency: connection.latencyMs,
                  );
                },
              ),
            ),

          // Connection floating indicator (wrapped in granular Consumer to prevent whole screen rebuilds) (Bug 89)
          Positioned(
            top: 16,
            right: 16,
            child: Consumer<ConnectionProvider>(
              builder: (context, connection, child) {
                return ConnectionFloatingButton(
                  isConnected: connection.isConnected,
                  latency: connection.latencyMs,
                  deviceName: connection.connectedDeviceName,
                  onTap: () {
                    if (!_showToolbar) {
                      setState(() => _showToolbar = true);
                    } else {
                      setState(() => _showToolbar = false);
                    }
                    _resetToolbarTimer();
                  },
                );
              },
            ),
          ),

          // Touch to show toolbar hint
          if (!_showToolbar)
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  _tapToShowToolbarHint, // Extracted for localization (Bug 94)
                  style: const TextStyle(color: Colors.white24, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ==================== TOUCH HANDLING ====================

  // Helper to resolve PointerDeviceKind to PointerType (Bug 82, 84)
  PointerType _getPointerType(PointerDeviceKind kind) {
    switch (kind) {
      case PointerDeviceKind.stylus:
        return PointerType.stylus;
      case PointerDeviceKind.invertedStylus:
        return PointerType.eraser;
      case PointerDeviceKind.mouse:
        return PointerType.mouse;
      default:
        return PointerType.finger;
    }
  }

  // Helper to extract and normalize pressure safely (Bug 83, 84, 93)
  double _getPressure(PointerEvent event) {
    if (event.pressureMin < event.pressureMax && event.pressureMax > 0.0) {
      return ((event.pressure - event.pressureMin) / (event.pressureMax - event.pressureMin)).clamp(0.0, 1.0);
    }
    if (event.pressure > 0.0) {
      return event.pressure.clamp(0.0, 1.0);
    }
    return _defaultPressure;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!_showToolbar) { // Only set state if not already visible (Bug 87, 95)
      setState(() => _showToolbar = true);
    }
    _resetToolbarTimer();

    final drawing = context.read<DrawingProvider>();
    final pressure = _getPressure(event);
    final pointerType = _getPointerType(event.kind);

    // Optimized stylus detection (Bug 92)
    if (pointerType == PointerType.stylus && !_stylusSupportDetected) {
      _stylusSupportDetected = true;
      final connection = context.read<ConnectionProvider>();
      if (!connection.hasStylusSupportSetting) {
        connection.setStylusSupport(true);
      }
    }

    drawing.onPointerDown(
      event.position,
      pressure: pressure,
      pointerType: pointerType,
      pointerId: event.pointer,
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    final drawing = context.read<DrawingProvider>();
    final pressure = _getPressure(event);
    final pointerType = _getPointerType(event.kind);

    // Optimized stylus detection (Bug 92)
    if (pointerType == PointerType.stylus && !_stylusSupportDetected) {
      _stylusSupportDetected = true;
      final connection = context.read<ConnectionProvider>();
      if (!connection.hasStylusSupportSetting) {
        connection.setStylusSupport(true);
      }
    }

    drawing.onPointerMove(
      event.position,
      pressure: pressure,
      pointerType: pointerType,
      pointerId: event.pointer,
    );
  }

  void _onPointerUp(PointerUpEvent event) {
    final drawing = context.read<DrawingProvider>();
    final pointerType = _getPointerType(event.kind);

    drawing.onPointerUp(
      pointerType: pointerType,
      pointerId: event.pointer,
    );
  }

  void _onPointerCancel(PointerCancelEvent event) {
    final drawing = context.read<DrawingProvider>();
    final pointerType = _getPointerType(event.kind); // Fixed: stylus cancel now retains type stylus (Bug 82)

    drawing.onPointerUp(
      pointerType: pointerType,
      pointerId: event.pointer,
    );
  }
}

// ==================== CUSTOM PAINTERS ====================

/// ড্রয়িং রেন্ডারার - সব স্ট্রোক ও কারেন্ট স্ট্রোক আঁকে
class DrawingPainter extends CustomPainter {
  final DrawingProvider drawingProvider;

  DrawingPainter({
    required this.drawingProvider,
  }) : super(repaint: drawingProvider.canvasNotifier);

  @override
  void paint(Canvas canvas, Size size) {
    // সব completed strokes আঁকা
    for (final stroke in drawingProvider.strokes) {
      _drawStroke(canvas, stroke, size);
    }

    // কারেন্ট (in-progress) স্ট্রোক আঁকা
    final currentStroke = drawingProvider.currentStroke;
    if (currentStroke != null && currentStroke.points.isNotEmpty) {
      _drawStroke(canvas, currentStroke, size);
    }
  }

  void _drawStroke(Canvas canvas, Stroke stroke, Size size) {
    if (stroke.points.isEmpty) return;
    final settings = stroke.settings;

    if (stroke.points.length == 1) {
      // Single dot
      final point = stroke.points.first;
      final width = settings.baseWidth * (0.3 + point.pressure * 0.7 * settings.pressureSensitivity);
      canvas.drawCircle(
        point.position,
        width / 2,
        Paint()
          ..color = settings.mode == BrushMode.eraser
              ? const Color(0xFF0A0A12)
              : settings.color.withValues(alpha: settings.opacity)
          ..strokeWidth = 1
          ..style = PaintingStyle.fill,
      );
      return;
    }

    // Path তৈরি
    final path = Path();
    path.moveTo(stroke.points.first.position.dx, stroke.points.first.position.dy);

    // Smooth curve through points (Catmull-Rom to Bezier)
    for (int i = 1; i < stroke.points.length - 1; i++) {
      final p0 = stroke.points[i - 1].position;
      final p1 = stroke.points[i].position;
      final p2 = stroke.points[i + 1].position;

      final controlPoint1 = Offset(
        p0.dx + (p1.dx - p0.dx) / 3,
        p0.dy + (p1.dy - p0.dy) / 3,
      );
      final controlPoint2 = Offset(
        p1.dx - (p2.dx - p0.dx) / 6,
        p1.dy - (p2.dy - p0.dy) / 6,
      );
      path.cubicTo(controlPoint1.dx, controlPoint1.dy, controlPoint2.dx, controlPoint2.dy, p1.dx, p1.dy);
    }

    // শেষ পয়েন্ট
    final lastPoint = stroke.points.last;
    path.lineTo(lastPoint.position.dx, lastPoint.position.dy);

    // Variable width stroke simulation
    if (stroke.points.length >= 2) {
      // Simple approach: draw path with average width
      final avgPressure = stroke.averagePressure;
      final width = settings.baseWidth * (0.3 + avgPressure * 0.7 * settings.pressureSensitivity);

      final paint = Paint()
        ..color = settings.mode == BrushMode.eraser
            ? const Color(0xFF0A0A12)
            : settings.color.withValues(alpha: settings.opacity)
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      if (settings.mode == BrushMode.pencil) {
        paint.strokeWidth = width * 0.7;
      } else if (settings.mode == BrushMode.brush) {
        paint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      }

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant DrawingPainter oldDelegate) {
    return oldDelegate.drawingProvider != drawingProvider;
  }
}

/// Subtle grid overlay
class GridPainter extends CustomPainter {
  const GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.03)
      ..strokeWidth = 0.5;

    const gridSize = 40.0;

    for (double x = 0; x <= size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}