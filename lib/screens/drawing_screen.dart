// Drawing Screen - Full Screen Drawing Canvas
//
// Displays a full screen drawing canvas on mobile/tablet.
// Captures pointer input and streams to PC server over WebSocket.
// Supports pressure-sensitive stylus and touch drawing.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
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
  double? _lastServerAspect;

  // Track if stylus support has already been registered (Bug 92)
  bool _stylusSupportDetected = false;

  // Default fallback pressure constant (Bug 93)
  static const double _defaultPressure = 0.5;

  @override
  void initState() {
    super.initState();
    _initWakelock(); // Await safely (Bug 85)

    // Landscape orientation
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // Full screen
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Configure input event callback on DrawingProvider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final drawing = context.read<DrawingProvider>();
      final connection = context.read<ConnectionProvider>();
      drawing.onInputGenerated = (event) {
        connection.sendInputEvent(event);
      };
      final settings = drawing.brushSettings;
      connection.sendBrushUpdate(
        tool: settings.mode == BrushMode.eraser ? 'eraser' : 'pen',
        colorHex: '#${settings.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
        strokeWidth: settings.baseWidth,
      );
    });

    // Auto-hide toolbar
    _resetToolbarTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final drawing = context.read<DrawingProvider>();
    final connection = context.read<ConnectionProvider>();
    drawing.onInputGenerated = (event) {
      connection.sendInputEvent(event);
    };
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
    try {
      context.read<DrawingProvider>().resetDrawingSession();
    } catch (_) {}
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
        fit: StackFit.expand,
        children: [
          // Drawing Canvas with Graphics Tablet Surface (Full Width or PC Aspect Ratio Match)
          Positioned.fill(
            child: Consumer2<ConnectionProvider, DrawingProvider>(
              builder: (context, connection, drawing, _) {
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final serverCfg = connection.serverConfig;
                    final targetRatio = (serverCfg.screenWidth > 0 && serverCfg.screenHeight > 0)
                        ? (serverCfg.screenWidth.toDouble() / serverCfg.screenHeight.toDouble())
                        : (16.0 / 9.0);

                    double canvasW = constraints.maxWidth;
                    double canvasH = constraints.maxHeight;

                    // If not in 100% full screen mode, preserve PC monitor aspect ratio (16:9 PC Fit Mode)
                    if (!drawing.fullScreenTabletMode) {
                      final screenRatio = constraints.maxWidth / constraints.maxHeight;
                      if (screenRatio > targetRatio) {
                        canvasH = constraints.maxHeight;
                        canvasW = canvasH * targetRatio;
                      } else {
                        canvasW = constraints.maxWidth;
                        canvasH = canvasW / targetRatio;
                      }
                    }

                    final double currentServerAspect = (serverCfg.screenWidth > 0 && serverCfg.screenHeight > 0)
                        ? (serverCfg.screenWidth.toDouble() / serverCfg.screenHeight.toDouble())
                        : (16.0 / 9.0);

                    drawing.setCanvasDimensionsSilently(canvasW, canvasH);

                    if (_lastWidth != canvasW || _lastHeight != canvasH || _lastServerAspect != currentServerAspect) {
                      _lastWidth = canvasW;
                      _lastHeight = canvasH;
                      _lastServerAspect = currentServerAspect;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          drawing.updateCanvasSize(canvasW, canvasH);
                          drawing.updateServerAspectRatio(currentServerAspect);
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
                              borderRadius: !drawing.fullScreenTabletMode ? BorderRadius.circular(8) : null,
                              border: !drawing.fullScreenTabletMode
                                  ? Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.6), width: 1.5)
                                  : null,
                              boxShadow: !drawing.fullScreenTabletMode
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
                                drawingProvider: drawing,
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
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) {}, // Prevents UI interactions from triggering canvas strokes
                child: Consumer2<DrawingProvider, ConnectionProvider>(
                  builder: (context, drawing, connection, child) {
                    return ToolbarWidget(
                    brushSettings: drawing.brushSettings,
                    onBrushChanged: (settings) {
                      drawing.updateBrush(settings);
                      connection.sendBrushUpdate(
                        tool: settings.mode == BrushMode.eraser ? 'eraser' : 'pen',
                        colorHex: '#${settings.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
                        strokeWidth: settings.baseWidth,
                      );
                    },
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
                    fullScreenMode: drawing.fullScreenTabletMode,
                    onFullScreenModeChanged: (val) {
                      drawing.fullScreenTabletMode = val;
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
                                ? '🎯 Custom Drawing Box: ON (Drawing restricted inside box)'
                                : '🖥️ Full Screen Mode: ON (Full screen drawing enabled)',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          duration: const Duration(seconds: 2),
                          backgroundColor: const Color(0xFF1A1A2E),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    isEditingCustomBox: drawing.isSnippingBox,
                    onEditCustomBoxChanged: (val) => drawing.isSnippingBox = val,
                    onCustomBoxPresetSelected: (preset) => drawing.setCustomBoxPreset(preset),
                    boxMapsToFullScreen: drawing.boxMapsToFullScreen,
                    onBoxMapsToFullScreenChanged: (val) => drawing.boxMapsToFullScreen = val,
                  );
                },
              ),
            ),
          ),

          // Pro Real-time Performance & Telemetry HUD (Top Left)
          Positioned(
            top: 14,
            left: 14,
            child: Selector<DrawingProvider, bool>(
              selector: (_, d) => d.isDrawing,
              builder: (_, isDrawing, child) => IgnorePointer(
                ignoring: isDrawing,
                child: child,
              ),
              child: const _ProPerformanceHUD(),
            ),
          ),

          // Floating Box Selector Bubble (Screen recorder style floating dot)
          Positioned.fill(
            child: Selector<DrawingProvider, bool>(
              selector: (_, d) => d.isDrawing,
              builder: (_, isDrawing, child) => IgnorePointer(
                ignoring: isDrawing,
                child: child,
              ),
              child: const _FloatingBoxSelectorBubble(),
            ),
          ),

          // Laptop Screenshot (Snipping Tool) Drag-to-Select Box Overlay
          Positioned.fill(
            child: Consumer<DrawingProvider>(
              builder: (context, drawing, _) {
                if (!drawing.isSnippingBox) return const SizedBox.shrink();
                return const _SnippingBoxSelectorOverlay();
              },
            ),
          ),

          // Canvas Ratio Mode Badge Chip (16:9 PC Fit vs Full Screen toggle)
          Positioned(
            top: 16,
            right: 124,
            child: Selector<DrawingProvider, bool>(
              selector: (_, d) => d.isDrawing,
              builder: (_, isDrawing, child) => IgnorePointer(
                ignoring: isDrawing,
                child: child,
              ),
              child: Consumer<DrawingProvider>(
                builder: (context, drawing, _) {
                  final isFull = drawing.fullScreenTabletMode;
                  return Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (_) {},
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        drawing.fullScreenTabletMode = !isFull;
                        ScaffoldMessenger.of(context).clearSnackBars();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              !isFull
                                  ? '📱 Full Phone Mode: Canvas fills phone screen (Stretched)'
                                  : '🖥️ 16:9 PC Fit: 1:1 Laptop Aspect Ratio (Zero Distortion, Perfect Circles)',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            duration: const Duration(seconds: 2),
                            backgroundColor: const Color(0xFF1E293B),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      child: Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: isFull
                              ? const Color(0xFF7C3AED).withValues(alpha: 0.3)
                              : const Color(0xFF00E5FF).withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(19),
                          border: Border.all(
                            color: isFull
                                ? const Color(0xFFA78BFA)
                                : const Color(0xFF00E5FF),
                            width: 1.3,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: (isFull
                                      ? const Color(0xFF7C3AED)
                                      : const Color(0xFF00E5FF))
                                  .withValues(alpha: 0.3),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isFull
                                  ? Icons.smartphone
                                  : Icons.laptop_chromebook,
                              color: isFull
                                  ? const Color(0xFFA78BFA)
                                  : const Color(0xFF00E5FF),
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isFull ? 'Full Phone' : '16:9 PC Fit',
                              style: TextStyle(
                                color: isFull
                                    ? const Color(0xFFA78BFA)
                                    : const Color(0xFF00E5FF),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // Connection floating indicator (wrapped in granular Consumer to prevent whole screen rebuilds) (Bug 89)
          Positioned(
            top: 16,
            right: 16,
            child: Selector<DrawingProvider, bool>(
              selector: (_, d) => d.isDrawing,
              builder: (_, isDrawing, child) => IgnorePointer(
                ignoring: isDrawing,
                child: child,
              ),
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) {}, // Prevents tap on connection button from leaking down to canvas
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
            ),
          ),

          // Toolbar restore handle when hidden
          if (!_showToolbar)
            Positioned(
              bottom: 12,
              left: 0,
              right: 0,
              child: Selector<DrawingProvider, bool>(
                selector: (_, d) => d.isDrawing,
                builder: (_, isDrawing, child) => IgnorePointer(
                  ignoring: isDrawing,
                  child: child,
                ),
                child: Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() => _showToolbar = true);
                      _resetToolbarTimer();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B).withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.4), width: 1.0),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.keyboard_arrow_up, color: Color(0xFF00E5FF), size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Show Toolbar',
                            style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
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
      // Use localPosition to accurately map Listener-relative canvas coordinates
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
      event.localPosition, // Canvas-local coordinate matching pointerDown
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
    final pointerType = _getPointerType(event.kind);

    drawing.onPointerCancel(
      pointerType: pointerType,
      pointerId: event.pointer,
      buttons: event.buttons,
    );
  }
}

// ==================== CUSTOM PAINTERS ====================

/// Drawing Renderer - Hardware Picture Caching and Pro Variable-Width Spline Inking
class DrawingPainter extends CustomPainter {
  final DrawingProvider drawingProvider;

  // Cached hardware picture of completed strokes (Blits in 0.05ms even for thousands of strokes)
  static ui.Picture? _cachedCompletedPicture;
  static int _cachedStrokeCount = -1;
  static Size? _cachedSize;

  DrawingPainter({
    required this.drawingProvider,
  }) : super(repaint: drawingProvider.canvasNotifier);

  @override
  void paint(Canvas canvas, Size size) {
    // Record VSync frame for real-time FPS telemetry
    drawingProvider.recordFrame();

    // 1. Draw custom drawing box frame and dimmed exterior if enabled
    if (drawingProvider.customBoxEnabled) {
      _drawCustomBoxOverlay(canvas, size);
    }

    // 2. Hardware-accelerated blitting of completed strokes
    final completedStrokes = drawingProvider.strokes;
    if (_cachedCompletedPicture == null ||
        _cachedStrokeCount != completedStrokes.length ||
        _cachedSize != size) {
      _cachedCompletedPicture?.dispose();
      final recorder = ui.PictureRecorder();
      final recordCanvas = Canvas(recorder, Rect.fromLTWH(0, 0, size.width, size.height));
      for (final stroke in completedStrokes) {
        stroke.draw(recordCanvas);
      }
      _cachedCompletedPicture = recorder.endRecording();
      _cachedStrokeCount = completedStrokes.length;
      _cachedSize = size;
    }

    if (_cachedCompletedPicture != null) {
      canvas.drawPicture(_cachedCompletedPicture!);
    }

    // 3. Active in-progress stroke with variable-width quadratic Bézier curves
    final currentStroke = drawingProvider.currentStroke;
    if (currentStroke != null && currentStroke.points.isNotEmpty) {
      currentStroke.draw(canvas);

      // Predictive Lead-Point Inking: Eliminates visual digitizer/display scanout lag
      if (drawingProvider.enablePrediction &&
          drawingProvider.predictedPosition != null &&
          currentStroke.points.length >= 2) {
        final predPos = drawingProvider.predictedPosition!;
        final lastPt = currentStroke.points.last;
        final leadPaint = Paint()
          ..color = currentStroke.settings.mode == BrushMode.eraser
              ? const Color(0xFF0A0A12)
              : currentStroke.settings.color.withValues(
                  alpha: (currentStroke.settings.opacity.clamp(0.0, 1.0) * 0.85),
                )
          ..strokeWidth = math.max(1.0, lastPt.width * 0.9)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke;
        canvas.drawLine(lastPt.position, predPos, leadPaint);
      }
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

/// Pro Real-Time Performance & Telemetry HUD
class _ProPerformanceHUD extends StatefulWidget {
  const _ProPerformanceHUD();

  @override
  State<_ProPerformanceHUD> createState() => _ProPerformanceHUDState();
}

class _ProPerformanceHUDState extends State<_ProPerformanceHUD> {
  bool _minimized = true;

  @override
  Widget build(BuildContext context) {
    final drawing = context.watch<DrawingProvider>();
    final connection = context.watch<ConnectionProvider>();

    if (!drawing.showPerformanceHUD) return const SizedBox.shrink();

    return ValueListenableBuilder<int>(
      valueListenable: drawing.metricNotifier,
      builder: (context, _, __) {
        final fps = drawing.liveFps.toStringAsFixed(0);
        final pollingRate = drawing.livePollingRateHz.toStringAsFixed(0);
        final latency = connection.latencyMs.toString();
        final isConnected = connection.isConnected;

        return GestureDetector(
          onTap: () => setState(() => _minimized = !_minimized),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: _minimized
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: isConnected ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$fps FPS',
                        style: const TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: isConnected ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: isConnected
                                  ? const Color(0xFF22C55E).withValues(alpha: 0.6)
                                  : const Color(0xFFEF4444).withValues(alpha: 0.6),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // FPS
                      _buildMetric('FPS', fps, const Color(0xFF00E5FF)),
                      _buildDivider(),
                      // Latency
                      _buildMetric('LAT', '${latency}ms', isConnected && connection.latencyMs < 10 ? const Color(0xFF22C55E) : const Color(0xFFF59E0B)),
                      _buildDivider(),
                      // Polling rate
                      _buildMetric('POLL', '${pollingRate}Hz', const Color(0xFFA855F7)),
                      _buildDivider(),
                      // Stylus mode badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: drawing.stylusOnlyMode
                              ? const Color(0xFF00E5FF).withValues(alpha: 0.18)
                              : Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: drawing.stylusOnlyMode
                                ? const Color(0xFF00E5FF).withValues(alpha: 0.6)
                                : Colors.white24,
                            width: 0.8,
                          ),
                        ),
                        child: Text(
                          drawing.stylusOnlyMode ? 'STYLUS ONLY' : 'TOUCH+PEN',
                          style: TextStyle(
                            color: drawing.stylusOnlyMode ? const Color(0xFF00E5FF) : Colors.white70,
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _buildMetric(String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 7.5,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _buildDivider() {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 7),
      color: Colors.white12,
    );
  }
}

/// Screen Recorder Style Floating Bubble (Small floating control point)
/// Allows user to tap/drag to configure active drawing area and trigger laptop screenshot style box selection
class _FloatingBoxSelectorBubble extends StatefulWidget {
  const _FloatingBoxSelectorBubble();

  @override
  State<_FloatingBoxSelectorBubble> createState() => _FloatingBoxSelectorBubbleState();
}

class _FloatingBoxSelectorBubbleState extends State<_FloatingBoxSelectorBubble> {
  Offset _pos = const Offset(-1, -1);
  bool _isMenuOpen = false;
  double _panDistance = 0.0;

  @override
  Widget build(BuildContext context) {
    final drawing = context.watch<DrawingProvider>();
    // Don't show floating bubble while user is actively snipping a box
    if (drawing.isSnippingBox) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenW = constraints.maxWidth;
        final screenH = constraints.maxHeight;

        // Default initial placement: right edge, 38% from top
        if (_pos.dx < 0 || _pos.dy < 0) {
          _pos = Offset(screenW - 58, screenH * 0.38);
        }

        final maxX = math.max(6.0, screenW - 54.0);
        final maxY = math.max(50.0, screenH - 110.0);
        final clampedX = _pos.dx.clamp(6.0, maxX);
        final clampedY = _pos.dy.clamp(50.0, maxY);
        final isRightSide = clampedX > screenW / 2;

        return Stack(
          children: [
            // Touch outside dismisses menu
            if (_isMenuOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => setState(() => _isMenuOpen = false),
                  child: Container(color: Colors.transparent),
                ),
              ),

            // Draggable Floating Bubble & Mini Actions Menu
            Positioned(
              left: isRightSide ? null : clampedX,
              right: isRightSide ? (screenW - clampedX - 48) : null,
              top: clampedY,
              child: Column(
                crossAxisAlignment: isRightSide ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The Screen Recorder style floating bubble dot
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (details) {
                      _panDistance = 0.0;
                    },
                    onPanUpdate: (details) {
                      _panDistance += details.delta.distance;
                      setState(() {
                        _pos += details.delta;
                      });
                    },
                    onPanEnd: (details) {
                      if (_panDistance < 8.0) {
                        setState(() {
                          _isMenuOpen = !_isMenuOpen;
                        });
                      }
                    },
                    onTap: () {
                      setState(() {
                        _isMenuOpen = !_isMenuOpen;
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: drawing.customBoxEnabled
                            ? const Color(0xFF00E5FF).withValues(alpha: 0.22)
                            : const Color(0xFF141C2B).withValues(alpha: 0.88),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: drawing.customBoxEnabled
                              ? const Color(0xFF00E5FF)
                              : Colors.white.withValues(alpha: 0.4),
                          width: drawing.customBoxEnabled ? 2.2 : 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: (drawing.customBoxEnabled ? const Color(0xFF00E5FF) : Colors.black)
                                .withValues(alpha: 0.45),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: Center(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Icon(
                              drawing.customBoxEnabled ? Icons.crop : Icons.crop_free,
                              color: drawing.customBoxEnabled ? const Color(0xFF00E5FF) : Colors.white,
                              size: 22,
                            ),
                            Positioned(
                              top: 2,
                              right: 2,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: drawing.customBoxEnabled ? const Color(0xFF00E5FF) : const Color(0xFF22C55E),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.black, width: 1.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Mini Quick Actions Popup Menu
                  if (_isMenuOpen) ...[
                    const SizedBox(height: 6),
                    Container(
                      width: 250,
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111827).withValues(alpha: 0.96),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.45), width: 1.2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.75),
                            blurRadius: 22,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Quick Color Swatches Row
                          Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                for (final c in const [
                                  Colors.white,
                                  Color(0xFF00E5FF),
                                  Color(0xFFFF5252),
                                  Color(0xFFFFD700),
                                  Color(0xFF8B5CF6),
                                ])
                                  GestureDetector(
                                    onTap: () {
                                      final newSettings = drawing.brushSettings.copyWith(color: c);
                                      drawing.updateBrush(newSettings);
                                      context.read<ConnectionProvider>().sendBrushUpdate(
                                        tool: newSettings.mode == BrushMode.eraser ? 'eraser' : 'pen',
                                        colorHex: '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
                                        strokeWidth: newSettings.baseWidth,
                                      );
                                    },
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 150),
                                      width: 26,
                                      height: 26,
                                      decoration: BoxDecoration(
                                        color: c,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: drawing.brushSettings.color == c ? Colors.white : Colors.black45,
                                          width: drawing.brushSettings.color == c ? 2.5 : 1.2,
                                        ),
                                        boxShadow: drawing.brushSettings.color == c
                                            ? [
                                                BoxShadow(
                                                  color: c.withValues(alpha: 0.8),
                                                  blurRadius: 8,
                                                )
                                              ]
                                            : null,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // Quick Stroke Width Row
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                for (final w in const [2.0, 5.0, 12.0])
                                  GestureDetector(
                                    onTap: () {
                                      final newSettings = drawing.brushSettings.copyWith(baseWidth: w);
                                      drawing.updateBrush(newSettings);
                                      context.read<ConnectionProvider>().sendBrushUpdate(
                                        tool: newSettings.mode == BrushMode.eraser ? 'eraser' : 'pen',
                                        colorHex: '#${newSettings.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
                                        strokeWidth: w,
                                      );
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: (drawing.brushSettings.baseWidth - w).abs() < 0.5
                                            ? const Color(0xFF00E5FF).withValues(alpha: 0.22)
                                            : Colors.white.withValues(alpha: 0.06),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: (drawing.brushSettings.baseWidth - w).abs() < 0.5
                                              ? const Color(0xFF00E5FF)
                                              : Colors.white12,
                                        ),
                                      ),
                                      child: Text(
                                        w == 2.0 ? 'Fine' : (w == 5.0 ? 'Medium' : 'Bold'),
                                        style: TextStyle(
                                          color: (drawing.brushSettings.baseWidth - w).abs() < 0.5
                                              ? const Color(0xFF00E5FF)
                                              : Colors.white70,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const Divider(color: Colors.white12, height: 8),

                          // Stylus-Only Inking Mode toggle
                          _buildMenuItem(
                            icon: drawing.stylusOnlyMode ? Icons.edit : Icons.touch_app,
                            title: drawing.stylusOnlyMode ? 'Stylus Mode: Stylus Only ✓' : 'Stylus Mode: Stylus + Touch',
                            color: drawing.stylusOnlyMode ? const Color(0xFF00E5FF) : Colors.white60,
                            onTap: () {
                              drawing.stylusOnlyMode = !drawing.stylusOnlyMode;
                              ScaffoldMessenger.of(context).clearSnackBars();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    drawing.stylusOnlyMode
                                        ? '✍️ Stylus-Only Mode: Finger touch completely ignored!'
                                        : '👆 Touch and stylus drawing enabled.',
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  duration: const Duration(seconds: 2),
                                  backgroundColor: const Color(0xFF1F2937),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                          ),
                          const Divider(color: Colors.white12, height: 8),

                          // Performance HUD toggle
                          _buildMenuItem(
                            icon: Icons.speed,
                            title: drawing.showPerformanceHUD ? 'Performance HUD: Visible ✓' : 'Performance HUD: Hidden',
                            color: const Color(0xFF22C55E),
                            onTap: () {
                              drawing.showPerformanceHUD = !drawing.showPerformanceHUD;
                            },
                          ),
                          const Divider(color: Colors.white12, height: 8),

                          // Snipping box
                          _buildMenuItem(
                            icon: Icons.crop,
                            title: 'Select Box like Screenshot (Snipping Tool)',
                            color: const Color(0xFF00E5FF),
                            onTap: () {
                              setState(() => _isMenuOpen = false);
                              drawing.isSnippingBox = true;
                            },
                          ),
                          const Divider(color: Colors.white12, height: 8),

                          // Canvas Aspect Ratio Match Mode toggle
                          _buildMenuItem(
                            icon: !drawing.fullScreenTabletMode ? Icons.laptop_chromebook : Icons.smartphone,
                            title: !drawing.fullScreenTabletMode
                                ? 'Canvas Ratio: 16:9 PC Fit (Zero Distortion) ✓'
                                : 'Canvas Ratio: Full Phone (Stretched)',
                            color: !drawing.fullScreenTabletMode ? const Color(0xFF00E5FF) : const Color(0xFFA78BFA),
                            onTap: () {
                              drawing.fullScreenTabletMode = !drawing.fullScreenTabletMode;
                              ScaffoldMessenger.of(context).clearSnackBars();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    !drawing.fullScreenTabletMode
                                        ? '🖥️ 16:9 PC Fit Active: Perfect circles & proportions on laptop'
                                        : '📱 Full Phone Mode Active: Fills entire phone screen',
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  duration: const Duration(seconds: 2),
                                  backgroundColor: const Color(0xFF1F2937),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                          ),
                          const Divider(color: Colors.white12, height: 8),

                          // PC Note Writing Scale cycle (1.0x -> 0.75x -> 0.50x)
                          _buildMenuItem(
                            icon: Icons.format_size,
                            title: (drawing.writingScale - 0.50).abs() < 0.08
                                ? 'Writing Scale: 0.50x Notebook (OneNote) ✓'
                                : ((drawing.writingScale - 0.75).abs() < 0.08
                                    ? 'Writing Scale: 0.75x Medium (Slides) ✓'
                                    : 'Writing Scale: 1.0x Full Display ✓'),
                            color: const Color(0xFF4ADE80),
                            onTap: () {
                              if ((drawing.writingScale - 1.0).abs() < 0.08) {
                                drawing.writingScale = 0.75;
                              } else if ((drawing.writingScale - 0.75).abs() < 0.08) {
                                drawing.writingScale = 0.50;
                              } else {
                                drawing.writingScale = 1.0;
                              }
                              ScaffoldMessenger.of(context).clearSnackBars();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    (drawing.writingScale - 0.50).abs() < 0.08
                                        ? '📐 0.50x Notebook Mode: Perfect for neat notes in OneNote & PDF'
                                        : ((drawing.writingScale - 0.75).abs() < 0.08
                                            ? '📊 0.75x Medium Mode: Balanced for slides & diagrams'
                                            : '🖥️ 1.0x Full Display: Full screen graphics tablet reach'),
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  duration: const Duration(seconds: 2),
                                  backgroundColor: const Color(0xFF1F2937),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                              setState(() {});
                            },
                          ),
                          const Divider(color: Colors.white12, height: 8),

                          // Full screen
                          _buildMenuItem(
                            icon: Icons.fullscreen,
                            title: 'Full Screen (1:1 100% Display Scale)',
                            color: const Color(0xFF22C55E),
                            onTap: () {
                              setState(() => _isMenuOpen = false);
                              drawing.resetToFullScreen();
                              ScaffoldMessenger.of(context).clearSnackBars();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('🖥️ Full Screen Mode: 100% display coverage active', style: TextStyle(fontWeight: FontWeight.bold)),
                                  duration: Duration(seconds: 2),
                                  backgroundColor: Color(0xFF1F2937),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                          ),
                          const Divider(color: Colors.white12, height: 8),

                          // Box on/off
                          _buildMenuItem(
                            icon: drawing.customBoxEnabled ? Icons.visibility_off : Icons.visibility,
                            title: drawing.customBoxEnabled ? 'Disable Custom Box' : 'Enable Previous Custom Box',
                            color: const Color(0xFFF59E0B),
                            onTap: () {
                              setState(() => _isMenuOpen = false);
                              drawing.customBoxEnabled = !drawing.customBoxEnabled;
                            },
                          ),
                          const Divider(color: Colors.white12, height: 8),

                          // PC map
                          _buildMenuItem(
                            icon: Icons.laptop,
                            title: drawing.boxMapsToFullScreen ? 'Map to PC: Full Screen ✓' : 'Map to PC: Box Ratio',
                            color: const Color(0xFFA855F7),
                            onTap: () {
                              drawing.boxMapsToFullScreen = !drawing.boxMapsToFullScreen;
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String title,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 16),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Laptop Screenshot (Snipping Tool) Drag-to-Select Box Overlay
class _SnippingBoxSelectorOverlay extends StatefulWidget {
  const _SnippingBoxSelectorOverlay();

  @override
  State<_SnippingBoxSelectorOverlay> createState() => _SnippingBoxSelectorOverlayState();
}

class _SnippingBoxSelectorOverlayState extends State<_SnippingBoxSelectorOverlay> {
  Offset? _dragStart;
  Offset? _currentDrag;

  @override
  Widget build(BuildContext context) {
    final drawing = context.watch<DrawingProvider>();
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;

        Rect? selectionRect;
        if (_dragStart != null && _currentDrag != null) {
          final left = math.min(_dragStart!.dx, _currentDrag!.dx);
          final top = math.min(_dragStart!.dy, _currentDrag!.dy);
          final right = math.max(_dragStart!.dx, _currentDrag!.dx);
          final bottom = math.max(_dragStart!.dy, _currentDrag!.dy);
          selectionRect = Rect.fromLTRB(left, top, right, bottom);
        }

        return Stack(
          children: [
            // Gesture capture for dragging rectangular area
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) {
                  setState(() {
                    _dragStart = details.localPosition;
                    _currentDrag = details.localPosition;
                  });
                },
                onPanUpdate: (details) {
                  setState(() {
                    _currentDrag = details.localPosition;
                  });
                },
                onPanEnd: (details) {
                  if (selectionRect != null &&
                      selectionRect.width >= 35 &&
                      selectionRect.height >= 35) {
                    final normLeft = (selectionRect.left / w).clamp(0.0, 0.95);
                    final normTop = (selectionRect.top / h).clamp(0.0, 0.95);
                    final normRight = (selectionRect.right / w).clamp(normLeft + 0.05, 1.0);
                    final normBottom = (selectionRect.bottom / h).clamp(normTop + 0.05, 1.0);

                    drawing.setCustomBoxNormalized(
                      Rect.fromLTRB(normLeft, normTop, normRight, normBottom),
                    );
                    drawing.customBoxEnabled = true;
                    drawing.isSnippingBox = false;

                    ScaffoldMessenger.of(context).clearSnackBars();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          '🎯 Custom drawing box set! Drawing is now confined to this box.',
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        duration: Duration(seconds: 3),
                        backgroundColor: Color(0xFF00B4D8),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  } else {
                    setState(() {
                      _dragStart = null;
                      _currentDrag = null;
                    });
                  }
                },
                child: CustomPaint(
                  painter: _SnippingPainter(
                    selectionRect: selectionRect,
                    crosshairPoint: _currentDrag,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),

            // Top Helper Header with cancel button
            Positioned(
              top: 20,
              left: 16,
              right: 16,
              child: SafeArea(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D1522).withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.65), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.6),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.crop, color: Color(0xFF00E5FF), size: 18),
                        const SizedBox(width: 8),
                        const Text(
                          'Drag on screen to select drawing box',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        const SizedBox(width: 14),
                        GestureDetector(
                          onTap: () {
                            drawing.isSnippingBox = false;
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.22),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.close, color: Colors.redAccent, size: 14),
                                SizedBox(width: 4),
                                Text('Cancel', style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Custom painter for Snipping selection rectangle and crosshairs
class _SnippingPainter extends CustomPainter {
  final Rect? selectionRect;
  final Offset? crosshairPoint;

  _SnippingPainter({
    required this.selectionRect,
    required this.crosshairPoint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final darkPaint = Paint()..color = Colors.black.withValues(alpha: 0.55);

    if (selectionRect == null) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), darkPaint);
    } else {
      final box = selectionRect!;
      if (box.top > 0) {
        canvas.drawRect(Rect.fromLTRB(0, 0, size.width, box.top), darkPaint);
      }
      if (box.bottom < size.height) {
        canvas.drawRect(Rect.fromLTRB(0, box.bottom, size.width, size.height), darkPaint);
      }
      if (box.left > 0) {
        canvas.drawRect(Rect.fromLTRB(0, box.top, box.left, box.bottom), darkPaint);
      }
      if (box.right < size.width) {
        canvas.drawRect(Rect.fromLTRB(box.right, box.top, size.width, box.bottom), darkPaint);
      }

      // Highlight fill
      final fillPaint = Paint()..color = const Color(0xFF00E5FF).withValues(alpha: 0.08);
      canvas.drawRect(box, fillPaint);

      // Border
      final borderPaint = Paint()
        ..color = const Color(0xFF00E5FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRect(box, borderPaint);

      // Corner L-brackets
      final cornerPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round;

      const cLen = 16.0;
      canvas.drawLine(box.topLeft, box.topLeft + const Offset(cLen, 0), cornerPaint);
      canvas.drawLine(box.topLeft, box.topLeft + const Offset(0, cLen), cornerPaint);
      canvas.drawLine(box.topRight, box.topRight + const Offset(-cLen, 0), cornerPaint);
      canvas.drawLine(box.topRight, box.topRight + const Offset(0, cLen), cornerPaint);
      canvas.drawLine(box.bottomLeft, box.bottomLeft + const Offset(cLen, 0), cornerPaint);
      canvas.drawLine(box.bottomLeft, box.bottomLeft + const Offset(0, -cLen), cornerPaint);
      canvas.drawLine(box.bottomRight, box.bottomRight + const Offset(-cLen, 0), cornerPaint);
      canvas.drawLine(box.bottomRight, box.bottomRight + const Offset(0, -cLen), cornerPaint);

      // Dimension text badge (e.g. "820 × 540 px")
      final textSpan = TextSpan(
        text: ' ${box.width.toInt()} × ${box.height.toInt()} px ',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          backgroundColor: Color(0xFF161B26),
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      final badgePos = Offset(
        (box.center.dx - textPainter.width / 2).clamp(8.0, size.width - textPainter.width - 8.0),
        (box.top - 24).clamp(8.0, size.height - 30),
      );
      textPainter.paint(canvas, badgePos);
    }

    // Crosshairs following finger (laptop snipping tool style)
    if (crosshairPoint != null) {
      final linePaint = Paint()
        ..color = const Color(0xFF00E5FF).withValues(alpha: 0.45)
        ..strokeWidth = 1.0;

      canvas.drawLine(Offset(0, crosshairPoint!.dy), Offset(size.width, crosshairPoint!.dy), linePaint);
      canvas.drawLine(Offset(crosshairPoint!.dx, 0), Offset(crosshairPoint!.dx, size.height), linePaint);

      final dotPaint = Paint()..color = const Color(0xFF00E5FF);
      canvas.drawCircle(crosshairPoint!, 3.5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SnippingPainter oldDelegate) {
    return oldDelegate.selectionRect != selectionRect ||
        oldDelegate.crosshairPoint != crosshairPoint;
  }
}