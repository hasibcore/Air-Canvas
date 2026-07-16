/// ড্রয়িং স্ক্রিন - পুরো স্ক্রিন ড্রয়িং ক্যানভাস
///
/// এই স্ক্রিন মোবাইল/ট্যাবে পুরো স্ক্রিন জুড়ে একটি ড্রয়িং এরিয়া দেখায়।
/// টাচ ইনপুট ক্যাপচার করে WebSocket এর মাধ্যমে সার্ভারে পাঠায়।
/// স্টাইলাস সাপোর্ট সহ pressure-sensitive ড্রয়িং।

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
  bool _canvasSizeSet = false;

  @override
  void initState() {
    super.initState();
    // Screen always on while drawing
    WakelockPlus.enable();

    // ল্যান্ডস্কেপ মোড
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // Full screen
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // DrawingProvider এ ইনপুট ইভেন্ট callback সেট করা
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final drawing = context.read<DrawingProvider>();
      final connection = context.read<ConnectionProvider>();
      drawing.onInputGenerated = (event) {
        connection.sendInputEvent(event);
      };
    });

    // Auto-hide toolbar
    _resetToolbarTimer();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _hideToolbarTimer?.cancel();
    super.dispose();
  }

  void _resetToolbarTimer() {
    _hideToolbarTimer?.cancel();
    _hideToolbarTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_showToolbar) return;
      setState(() => _showToolbar = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final drawing = context.watch<DrawingProvider>();
    final connection = context.watch<ConnectionProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A12),
      body: Stack(
        children: [
          // Drawing Canvas
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Canvas size শুধুমাত্র একবার set করা হবে
                if (!_canvasSizeSet) {
                  _canvasSizeSet = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    drawing.updateCanvasSize(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
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
                        strokes: drawing.strokes,
                        currentStroke: drawing.currentStroke,
                        currentStrokePointsCount: drawing.currentStroke?.points.length ?? 0,
                        brushSettings: drawing.brushSettings,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                );
              },
            ),
          ),

          // Grid overlay (subtle)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: GridPainter(),
                size: Size.infinite,
              ),
            ),
          ),

          // Toolbar (animated)
          if (_showToolbar)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ToolbarWidget(
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
              ),
            ),

          // Connection floating indicator
          Positioned(
            top: 16,
            right: 16,
            child: ConnectionFloatingButton(
              isConnected: connection.isConnected,
              latency: connection.latencyMs,
              deviceName: connection.connectedDeviceName,
              onTap: () {
                setState(() => _showToolbar = !_showToolbar);
                _resetToolbarTimer();
              },
            ),
          ),

          // Touch to show toolbar hint
          if (!_showToolbar)
            const Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'Tap to show toolbar',
                  style: TextStyle(color: Colors.white24, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ==================== TOUCH HANDLING ====================

  void _onPointerDown(PointerDownEvent event) {
    setState(() => _showToolbar = true);
    _resetToolbarTimer();

    final drawing = context.read<DrawingProvider>();

    // প্রেশার বের করা (stylus support)
    double pressure = 0.5;
    if (event.pressure > 0 && event.pressure <= 1.0) {
      pressure = event.pressure;
    }

    // Pointer type detect করা
    PointerType pointerType = PointerType.finger;
    if (event.kind == PointerDeviceKind.stylus) {
      pointerType = PointerType.stylus;
      final connection = context.read<ConnectionProvider>();
      if (!connection.hasStylusSupportSetting) {
        connection.setStylusSupport(true);
      }
    } else if (event.kind == PointerDeviceKind.mouse) {
      pointerType = PointerType.mouse;
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

    double pressure = 0.5;
    if (event.pressure > 0 && event.pressure <= 1.0) {
      pressure = event.pressure;
    }

    PointerType pointerType = PointerType.finger;
    if (event.kind == PointerDeviceKind.stylus) {
      pointerType = PointerType.stylus;
      final connection = context.read<ConnectionProvider>();
      if (!connection.hasStylusSupportSetting) {
        connection.setStylusSupport(true);
      }
    } else if (event.kind == PointerDeviceKind.mouse) {
      pointerType = PointerType.mouse;
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

    PointerType pointerType = PointerType.finger;
    if (event.kind == PointerDeviceKind.stylus) {
      pointerType = PointerType.stylus;
    } else if (event.kind == PointerDeviceKind.mouse) {
      pointerType = PointerType.mouse;
    }

    drawing.onPointerUp(
      pointerType: pointerType,
      pointerId: event.pointer,
    );
  }

  void _onPointerCancel(PointerCancelEvent event) {
    final drawing = context.read<DrawingProvider>();
    // Cancel = force end the stroke without sending an up event
    drawing.onPointerUp(
      pointerType: PointerType.finger,
      pointerId: event.pointer,
    );
  }
}

// ==================== CUSTOM PAINTERS ====================

/// ড্রয়িং রেন্ডারার - সব স্ট্রোক ও কারেন্ট স্ট্রোক আঁকে
class DrawingPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  final int currentStrokePointsCount;
  final BrushSettings brushSettings;

  DrawingPainter({
    required this.strokes,
    this.currentStroke,
    required this.currentStrokePointsCount,
    required this.brushSettings,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // সব completed strokes আঁকা
    for (final stroke in strokes) {
      _drawStroke(canvas, stroke, size);
    }

    // কারেন্ট (in-progress) স্ট্রোক আঁকা
    if (currentStroke != null && currentStroke!.points.isNotEmpty) {
      _drawStroke(canvas, currentStroke!, size);
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
              : settings.color.withOpacity(settings.opacity)
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
            : settings.color.withOpacity(settings.opacity)
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
    return oldDelegate.currentStrokePointsCount != currentStrokePointsCount ||
        oldDelegate.strokes.length != strokes.length ||
        oldDelegate.brushSettings != brushSettings;
  }
}

/// Subtle grid overlay
class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF).withOpacity(0.03)
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