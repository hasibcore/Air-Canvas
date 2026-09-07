// ড্রয়িং স্ক্রিন - পুরো স্ক্রিন ড্রয়িং ক্যানভাস
//
// এই স্ক্রিন মোবাইল/ট্যাবে পুরো স্ক্রিন জুড়ে একটি ড্রয়িং এরিয়া দেখায়।
// টাচ ইনপুট ক্যাপচার করে WebSocket এর মাধ্যমে সার্ভারে পাঠায়।
// স্টাইলাস সাপোর্ট সহ pressure-sensitive ড্রয়িং।

import 'dart:async';
import 'dart:math' as math;
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

  // Graphics Tablet Mode: true = 100% full screen edge-to-edge (Software aspect ratio compensation guarantees perfect shapes)
  bool _fullScreenTabletMode = true;

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
          // Drawing Canvas with Graphics Tablet Surface (Full Width or PC Aspect Ratio Match)
          Positioned.fill(
            child: Consumer<ConnectionProvider>(
              builder: (context, connection, _) {
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final serverCfg = connection.serverConfig;
                    final targetRatio = (serverCfg.screenWidth > 0 && serverCfg.screenHeight > 0)
                        ? (serverCfg.screenWidth.toDouble() / serverCfg.screenHeight.toDouble())
                        : (16.0 / 9.0);

                    double canvasW = constraints.maxWidth;
                    double canvasH = constraints.maxHeight;

                    // If not in 100% full screen mode, preserve PC monitor aspect ratio
                    if (!_fullScreenTabletMode) {
                      final screenRatio = constraints.maxWidth / constraints.maxHeight;
                      if (screenRatio > targetRatio) {
                        canvasH = constraints.maxHeight;
                        canvasW = canvasH * targetRatio;
                      } else {
                        canvasW = constraints.maxWidth;
                        canvasH = canvasW / targetRatio;
                      }
                    }

                    if (_lastWidth != canvasW || _lastHeight != canvasH) {
                      _lastWidth = canvasW;
                      _lastHeight = canvasH;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          final drawing = context.read<DrawingProvider>();
                          drawing.updateCanvasSize(canvasW, canvasH);
                          if (serverCfg.screenWidth > 0 && serverCfg.screenHeight > 0) {
                            drawing.updateServerAspectRatio(serverCfg.screenWidth.toDouble() / serverCfg.screenHeight.toDouble());
                          }
                        }
                      });
                    }

                    return Center(
                      child: SizedBox(
                        width: canvasW,
                        height: canvasH,
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: _onPointerDown,
                          onPointerMove: _onPointerMove,
                          onPointerUp: _onPointerUp,
                          onPointerCancel: _onPointerCancel,
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF0A0A12),
                              borderRadius: !_fullScreenTabletMode ? BorderRadius.circular(8) : null,
                              border: !_fullScreenTabletMode
                                  ? Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.6), width: 1.5)
                                  : null,
                              boxShadow: !_fullScreenTabletMode
                                  ? [
                                      BoxShadow(
                                        color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                                        blurRadius: 16,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: CustomPaint(
                              painter: DrawingPainter(
                                drawingProvider: context.read<DrawingProvider>(),
                              ),
                              size: Size.infinite,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
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
                    canUndo: drawing.canUndo,
                    palmRejection: drawing.palmRejection,
                    onPalmRejectionChanged: (value) =>
                        drawing.palmRejection = value,
                    fullScreenMode: _fullScreenTabletMode,
                    onFullScreenModeChanged: (val) {
                      setState(() => _fullScreenTabletMode = val);
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            val
                                ? 'Tablet Mode: Full Screen (Stretched to phone - shapes may distort)'
                                : 'Tablet Mode: 1:1 Match PC (${connection.serverConfig.screenWidth}x${connection.serverConfig.screenHeight} - Perfect Shapes, Zero Distortion)',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          duration: const Duration(seconds: 2),
                          backgroundColor: const Color(0xFF1A1A2E),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    directTabletMode: drawing.directTabletMode,
                    onDirectTabletModeChanged: (val) {
                      drawing.directTabletMode = val;
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            val
                                ? '⚡ High-Performance 0-Lag Mode: ON (Crystal-clear handwriting for online classes)'
                                : 'Smoothing Stabilizer: ON (For slow artistic curves)',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          duration: const Duration(seconds: 2),
                          backgroundColor: const Color(0xFF1A1A2E),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    precisionMode: drawing.precisionMode,
                    onPrecisionModeChanged: (mode) =>
                        drawing.precisionMode = mode,
                    pressureCurve: drawing.pressureCurve,
                    onPressureCurveChanged: (curve) =>
                        drawing.pressureCurve = curve,
                    writingScale: drawing.writingScale,
                    onWritingScaleChanged: (scale) =>
                        drawing.writingScale = scale,
                    writingAnchor: drawing.writingAnchor,
                    onWritingAnchorChanged: (anchor) =>
                        drawing.writingAnchor = anchor,
                    onClassAction: (action) {
                      connection.sendAction(action);
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Triggered: $action on PC'),
                          duration: const Duration(milliseconds: 1200),
                          backgroundColor: const Color(0xFF1A1A2E),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    customBoxEnabled: drawing.customBoxEnabled,
                    onCustomBoxEnabledChanged: (val) {
                      drawing.customBoxEnabled = val;
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            val
                                ? '🎯 নির্দিষ্ট ড্রয়িং বক্স: ON (শুধুমাত্র বক্সের ভেতরে আঁকা হবে)'
                                : '🖥️ ফুল স্ক্রিন মোড: ON (পুরো স্ক্রিন জুড়ে ড্রয়িং চালু)',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          duration: const Duration(seconds: 2),
                          backgroundColor: const Color(0xFF1A1A2E),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    isEditingCustomBox: drawing.isEditingCustomBox,
                    onEditCustomBoxChanged: (val) => drawing.isEditingCustomBox = val,
                    onCustomBoxPresetSelected: (preset) => drawing.setCustomBoxPreset(preset),
                    boxMapsToFullScreen: drawing.boxMapsToFullScreen,
                    onBoxMapsToFullScreenChanged: (val) => drawing.boxMapsToFullScreen = val,
                  );
                },
              ),
            ),

          // Custom Drawing Box interactive drag & resize editor
          Consumer<DrawingProvider>(
            builder: (context, drawing, _) {
              if (!drawing.isEditingCustomBox) return const SizedBox.shrink();
              return const _CustomBoxEditorOverlay();
            },
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

    double tiltX = 0.0;
    double tiltY = 0.0;
    if (event.tilt > 0) {
      tiltX = (event.tilt * math.cos(event.orientation)) * (180 / math.pi);
      tiltY = (event.tilt * math.sin(event.orientation)) * (180 / math.pi);
    }

    drawing.onPointerDown(
      // `position` গ্লোবাল স্ক্রিন কো-অর্ডিনেট, কিন্তু নরমালাইজেশন হয় ক্যানভাসের
      // মাপ দিয়ে। এখন ক্যানভাস স্ক্রিনের (0,0) থেকেই শুরু হয় তাই দুটো এক, কিন্তু
      // ভবিষ্যতে AppBar/padding যোগ হলেই স্ট্রোক সরে যেত। `localPosition`
      // সব সময় Listener এর ভেতরের কো-অর্ডিনেট, তাই এটাই সঠিক।
      event.localPosition,
      pressure: pressure,
      pointerType: pointerType,
      pointerId: event.pointer,
      tiltX: tiltX,
      tiltY: tiltY,
      buttons: event.buttons,
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

    double tiltX = 0.0;
    double tiltY = 0.0;
    if (event.tilt > 0) {
      tiltX = (event.tilt * math.cos(event.orientation)) * (180 / math.pi);
      tiltY = (event.tilt * math.sin(event.orientation)) * (180 / math.pi);
    }

    drawing.onPointerMove(
      event.localPosition, // down এর মতোই — ক্যানভাস-লোকাল কো-অর্ডিনেট
      pressure: pressure,
      pointerType: pointerType,
      pointerId: event.pointer,
      tiltX: tiltX,
      tiltY: tiltY,
      buttons: event.buttons,
    );
  }

  void _onPointerUp(PointerUpEvent event) {
    final drawing = context.read<DrawingProvider>();
    final pointerType = _getPointerType(event.kind);
    drawing.onPointerUp(
      pointerType: pointerType,
      pointerId: event.pointer,
      buttons: event.buttons,
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
    // 1. Draw custom drawing box frame and dimmed exterior if enabled
    if (drawingProvider.customBoxEnabled) {
      _drawCustomBoxOverlay(canvas, size);
    }

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

  void _drawCustomBoxOverlay(Canvas canvas, Size size) {
    final norm = drawingProvider.customBoxNormalized;
    final boxRect = Rect.fromLTRB(
      norm.left * size.width,
      norm.top * size.height,
      norm.right * size.width,
      norm.bottom * size.height,
    );

    // 1. Dim the inactive area outside the box to protect from accidental touches
    final dimPaint = Paint()..color = Colors.black.withValues(alpha: 0.50);
    // Top
    if (boxRect.top > 0) {
      canvas.drawRect(Rect.fromLTRB(0, 0, size.width, boxRect.top), dimPaint);
    }
    // Bottom
    if (boxRect.bottom < size.height) {
      canvas.drawRect(Rect.fromLTRB(0, boxRect.bottom, size.width, size.height), dimPaint);
    }
    // Left
    if (boxRect.left > 0) {
      canvas.drawRect(Rect.fromLTRB(0, boxRect.top, boxRect.left, boxRect.bottom), dimPaint);
    }
    // Right
    if (boxRect.right < size.width) {
      canvas.drawRect(Rect.fromLTRB(boxRect.right, boxRect.top, size.width, boxRect.bottom), dimPaint);
    }

    // 2. Cyan glowing border for the active box
    final borderPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(boxRect, borderPaint);

    // 3. Four corner L-brackets
    final cornerPaint = Paint()
      ..color = const Color(0xFF00E5FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    const cLen = 18.0;
    // Top-Left
    canvas.drawLine(boxRect.topLeft, boxRect.topLeft + const Offset(cLen, 0), cornerPaint);
    canvas.drawLine(boxRect.topLeft, boxRect.topLeft + const Offset(0, cLen), cornerPaint);
    // Top-Right
    canvas.drawLine(boxRect.topRight, boxRect.topRight + const Offset(-cLen, 0), cornerPaint);
    canvas.drawLine(boxRect.topRight, boxRect.topRight + const Offset(0, cLen), cornerPaint);
    // Bottom-Left
    canvas.drawLine(boxRect.bottomLeft, boxRect.bottomLeft + const Offset(cLen, 0), cornerPaint);
    canvas.drawLine(boxRect.bottomLeft, boxRect.bottomLeft + const Offset(0, -cLen), cornerPaint);
    // Bottom-Right
    canvas.drawLine(boxRect.bottomRight, boxRect.bottomRight + const Offset(-cLen, 0), cornerPaint);
    canvas.drawLine(boxRect.bottomRight, boxRect.bottomRight + const Offset(0, -cLen), cornerPaint);
  }

  void _drawStroke(Canvas canvas, Stroke stroke, Size size) {
    if (stroke.points.isEmpty) return;
    if (stroke.points.length == 1) {
      final point = stroke.points.first;
      final settings = stroke.settings;
      final width = settings.baseWidth * (0.3 + point.pressure * 0.7 * settings.pressureSensitivity);
      canvas.drawCircle(
        point.position,
        width / 2,
        Paint()
          ..color = settings.mode == BrushMode.eraser
              ? const Color(0xFF0A0A12)
              : settings.color.withValues(alpha: settings.opacity.clamp(0.0, 1.0))
          ..strokeWidth = 1
          ..style = PaintingStyle.fill,
      );
      return;
    }
    canvas.drawPath(stroke.path, stroke.paint);
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

/// Interactive Custom Box Editor Overlay for live dragging & resizing on screen
class _CustomBoxEditorOverlay extends StatefulWidget {
  const _CustomBoxEditorOverlay();

  @override
  State<_CustomBoxEditorOverlay> createState() => _CustomBoxEditorOverlayState();
}

class _CustomBoxEditorOverlayState extends State<_CustomBoxEditorOverlay> {
  int _dragHandle = 0; // 1: center move
  Offset? _dragStartPos;
  Rect? _initialRect;

  @override
  Widget build(BuildContext context) {
    final drawing = context.watch<DrawingProvider>();
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final norm = drawing.customBoxNormalized;
        final boxRect = Rect.fromLTRB(
          norm.left * w,
          norm.top * h,
          norm.right * w,
          norm.bottom * h,
        );

        return Stack(
          children: [
            // Dark touch barrier
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Container(
                  color: Colors.black.withValues(alpha: 0.55),
                ),
              ),
            ),

            // Draggable & Resizable Active Box
            Positioned(
              left: boxRect.left,
              top: boxRect.top,
              width: boxRect.width,
              height: boxRect.height,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) {
                  _dragHandle = 1;
                  _dragStartPos = details.globalPosition;
                  _initialRect = boxRect;
                },
                onPanUpdate: (details) {
                  if (_dragHandle == 1 && _dragStartPos != null && _initialRect != null) {
                    final delta = details.globalPosition - _dragStartPos!;
                    double newLeft = (_initialRect!.left + delta.dx).clamp(0.0, w - _initialRect!.width);
                    double newTop = (_initialRect!.top + delta.dy).clamp(0.0, h - _initialRect!.height);
                    final newRect = Rect.fromLTWH(newLeft, newTop, _initialRect!.width, _initialRect!.height);
                    drawing.setCustomBoxNormalized(Rect.fromLTRB(
                      newRect.left / w,
                      newRect.top / h,
                      newRect.right / w,
                      newRect.bottom / h,
                    ));
                  }
                },
                onPanEnd: (_) => _dragHandle = 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                    border: Border.all(color: const Color(0xFF00E5FF), width: 2.5),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.open_with, color: Color(0xFF00E5FF), size: 30),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'মাঝে ধরে সরান (Drag to Move)',
                            style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // 4 Corner Handles for intuitive resizing
            _buildHandle(
              left: boxRect.left - 16,
              top: boxRect.top - 16,
              onPanUpdate: (d) {
                final newLeft = (boxRect.left + d.delta.dx).clamp(0.0, boxRect.right - 60);
                final newTop = (boxRect.top + d.delta.dy).clamp(0.0, boxRect.bottom - 60);
                drawing.setCustomBoxNormalized(Rect.fromLTRB(
                  newLeft / w,
                  newTop / h,
                  boxRect.right / w,
                  boxRect.bottom / h,
                ));
              },
            ),
            _buildHandle(
              left: boxRect.right - 16,
              top: boxRect.top - 16,
              onPanUpdate: (d) {
                final newRight = (boxRect.right + d.delta.dx).clamp(boxRect.left + 60, w);
                final newTop = (boxRect.top + d.delta.dy).clamp(0.0, boxRect.bottom - 60);
                drawing.setCustomBoxNormalized(Rect.fromLTRB(
                  boxRect.left / w,
                  newTop / h,
                  newRight / w,
                  boxRect.bottom / h,
                ));
              },
            ),
            _buildHandle(
              left: boxRect.left - 16,
              top: boxRect.bottom - 16,
              onPanUpdate: (d) {
                final newLeft = (boxRect.left + d.delta.dx).clamp(0.0, boxRect.right - 60);
                final newBottom = (boxRect.bottom + d.delta.dy).clamp(boxRect.top + 60, h);
                drawing.setCustomBoxNormalized(Rect.fromLTRB(
                  newLeft / w,
                  boxRect.top / h,
                  boxRect.right / w,
                  newBottom / h,
                ));
              },
            ),
            _buildHandle(
              left: boxRect.right - 16,
              top: boxRect.bottom - 16,
              onPanUpdate: (d) {
                final newRight = (boxRect.right + d.delta.dx).clamp(boxRect.left + 60, w);
                final newBottom = (boxRect.bottom + d.delta.dy).clamp(boxRect.top + 60, h);
                drawing.setCustomBoxNormalized(Rect.fromLTRB(
                  boxRect.left / w,
                  boxRect.top / h,
                  newRight / w,
                  newBottom / h,
                ));
              },
            ),

            // Top Floating Control Bar
            Positioned(
              top: 18,
              left: 20,
              right: 20,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B26),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.5)),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.7), blurRadius: 18),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.crop_free, color: Color(0xFF00E5FF), size: 18),
                      const SizedBox(width: 8),
                      const Text(
                        'ড্রয়িং বক্স সাজান (Adjust Box)',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E5FF),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('✓ সম্পন্ন (Done)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        onPressed: () {
                          drawing.isEditingCustomBox = false;
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHandle({
    required double left,
    required double top,
    required ValueChanged<DragUpdateDetails> onPanUpdate,
  }) {
    return Positioned(
      left: left,
      top: top,
      width: 32,
      height: 32,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: onPanUpdate,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF00E5FF),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black, width: 2.5),
            boxShadow: [
              BoxShadow(color: const Color(0xFF00E5FF).withValues(alpha: 0.6), blurRadius: 8),
            ],
          ),
          child: const Center(
            child: Icon(Icons.drag_handle, size: 12, color: Colors.black),
          ),
        ),
      ),
    );
  }
}