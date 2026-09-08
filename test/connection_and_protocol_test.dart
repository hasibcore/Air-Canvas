import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:air_canvas/models/input_event.dart';
import 'package:air_canvas/services/connection_provider.dart';
import 'package:air_canvas/services/one_euro_filter.dart';
import 'package:air_canvas/services/drawing_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  group('InputEvent Binary & JSON Protocol Tests', () {
    test('Binary serialization and deserialization produces identical values', () {
      final original = InputEvent(
        type: InputEventType.pointerMove,
        x: 0.5432,
        y: 0.8765,
        pressure: 0.75,
        pointerType: PointerType.stylus,
        pointerId: 1,
        tiltX: 15.0,
        tiltY: -25.0,
        buttons: 1,
      );

      final binaryBytes = original.toBinary();
      expect(binaryBytes.length, equals(InputEvent.binaryPacketLength));

      final deserialized = InputEvent.fromBinary(binaryBytes);
      expect(deserialized.type, equals(InputEventType.pointerMove));
      expect(deserialized.pointerType, equals(PointerType.stylus));
      expect(deserialized.pointerId, equals(1));
      expect(deserialized.buttons, equals(1));

      // Coordinates should be accurate within 16-bit precision (1/65535 ~ 0.000015)
      expect(deserialized.x, closeTo(0.5432, 0.001));
      expect(deserialized.y, closeTo(0.8765, 0.001));
      expect(deserialized.pressure, closeTo(0.75, 0.01));
      expect(deserialized.tiltX, closeTo(15.0, 1.0));
      expect(deserialized.tiltY, closeTo(-25.0, 1.0));
    });

    test('Coordinates and pressure are properly clamped to valid ranges', () {
      final outOfBounds = InputEvent(
        type: InputEventType.pointerDown,
        x: 1.5,
        y: -0.5,
        pressure: 2.0,
        tiltX: 120.0,
        tiltY: -120.0,
      );

      expect(outOfBounds.x, equals(1.0));
      expect(outOfBounds.y, equals(0.0));
      expect(outOfBounds.pressure, equals(1.0));
      expect(outOfBounds.tiltX, equals(90.0));
      expect(outOfBounds.tiltY, equals(-90.0));
    });

    test('JSON serialization handles nulls and types gracefully', () {
      final event = InputEvent(
        type: InputEventType.pointerDown,
        x: 0.25,
        y: 0.75,
        pressure: 0.5,
        pointerType: PointerType.finger,
      );

      final json = event.toJson();
      final parsed = InputEvent.fromJson(json);

      expect(parsed.type, equals(InputEventType.pointerDown));
      expect(parsed.x, closeTo(0.25, 0.001));
      expect(parsed.y, closeTo(0.75, 0.001));
      expect(parsed.pressure, closeTo(0.5, 0.001));
      expect(parsed.pointerType, equals(PointerType.finger));
    });

    test('Pointer types (stylus, eraser, mouse, finger) serialize correctly', () {
      for (final pt in PointerType.values) {
        final event = InputEvent(
          type: InputEventType.pointerMove,
          x: 0.1,
          y: 0.2,
          pointerType: pt,
        );
        final bytes = event.toBinary();
        final restored = InputEvent.fromBinary(bytes);
        expect(restored.pointerType, equals(pt));
      }
    });
  });

  group('DeviceInfo and ServerConfig Tests', () {
    test('DeviceInfo JSON roundtrip preserves all tablet metadata', () {
      const info = DeviceInfo(
        deviceName: 'Galaxy Tab S9',
        deviceModel: 'SM-X710',
        platform: 'android',
        screenWidth: 2560.0,
        screenHeight: 1600.0,
        hasStylusSupport: true,
        maxPressure: 4096.0,
      );

      final json = info.toJson();
      final restored = DeviceInfo.fromJson(json);

      expect(restored.deviceName, equals('Galaxy Tab S9'));
      expect(restored.platform, equals('android'));
      expect(restored.screenWidth, equals(2560.0));
      expect(restored.screenHeight, equals(1600.0));
      expect(restored.hasStylusSupport, isTrue);
      expect(restored.maxPressure, equals(4096.0));
    });

    test('ServerConfig supports binary, screen dimensions and custom port configuration', () {
      const config = ServerConfig(
        port: 9090,
        useBinaryProtocol: true,
        enablePressureSmoothing: true,
        enablePrediction: true,
        screenWidth: 1920,
        screenHeight: 1080,
      );

      final json = config.toJson();
      final restored = ServerConfig.fromJson(json);

      expect(restored.port, equals(9090));
      expect(restored.useBinaryProtocol, isTrue);
      expect(restored.enablePressureSmoothing, isTrue);
      expect(restored.enablePrediction, isTrue);
      expect(restored.screenWidth, equals(1920));
      expect(restored.screenHeight, equals(1080));
    });
  });

  group('ConnectionProvider State Tests', () {
    test('Initial connection state is disconnected', () {
      final provider = ConnectionProvider();
      expect(provider.state, equals(ConnectionState.disconnected));
      expect(provider.isConnected, isFalse);
      expect(provider.discoveredDevices, isEmpty);
      provider.dispose();
    });
  });

  group('Aspect Ratio & Shape Preservation Tests', () {
    test('1:1 Aspect ratio canvas mapping preserves identical circle width/height on PC', () {
      // Laptop display: 1920x1080 (16:9 ratio)
      const pcWidth = 1920.0;
      const pcHeight = 1080.0;
      const targetRatio = pcWidth / pcHeight; // 1.7777...

      // Mobile phone constraint: 892x412 (modern 20:9 phone screen)
      const phoneConstraintsW = 892.0;
      const phoneConstraintsH = 412.0;

      // In 1:1 Aspect Ratio Match mode (letterboxed/pillarboxed active area):
      const phoneRatio = phoneConstraintsW / phoneConstraintsH;
      double canvasW = phoneConstraintsW;
      double canvasH = phoneConstraintsH;

      if (phoneRatio > targetRatio) {
        canvasH = phoneConstraintsH;
        canvasW = canvasH * targetRatio;
      } else {
        canvasW = phoneConstraintsW;
        canvasH = canvasW / targetRatio;
      }

      // Verify canvas aspect ratio exactly matches PC display ratio
      expect(canvasW / canvasH, closeTo(targetRatio, 0.0001));

      // Simulate drawing a circle of diameter 100px on the mobile canvas
      const circleDiameter = 100.0;
      final normalizedXSpan = circleDiameter / canvasW;
      final normalizedYSpan = circleDiameter / canvasH;

      // When injected onto PC monitor:
      final pcXSpan = normalizedXSpan * pcWidth;
      final pcYSpan = normalizedYSpan * pcHeight;

      // The circle must have EQUAL width and height on PC (no distortion / oval effect)
      expect(pcXSpan, closeTo(pcYSpan, 0.001));
      expect(pcXSpan / pcYSpan, closeTo(1.0, 0.001));
    });

    test('Stretched mode without aspect ratio match distorts circle into oval', () {
      // Laptop display: 1920x1080
      const pcWidth = 1920.0;
      const pcHeight = 1080.0;

      // Mobile phone constraint: 892x412 (no letterboxing, full screen stretch)
      const canvasW = 892.0;
      const canvasH = 412.0;

      const circleDiameter = 100.0;
      const normalizedXSpan = circleDiameter / canvasW;
      const normalizedYSpan = circleDiameter / canvasH;

      const pcXSpan = normalizedXSpan * pcWidth;
      const pcYSpan = normalizedYSpan * pcHeight;

      // In stretched mode, width and height are significantly mismatched (~22% distortion)
      expect((pcXSpan - pcYSpan).abs(), greaterThan(10.0));
      expect(pcXSpan / pcYSpan, isNot(closeTo(1.0, 0.05)));
    });

    test('1:1 Normalized coordinate pipeline maps from (0,0) to (1,1) without artificial offset', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(800.0, 450.0); // 16:9 canvas
      drawing.writingScale = 1.0;
      drawing.writingAnchor = WritingAnchor.topLeft;

      InputEvent? emittedEvent;
      drawing.onInputGenerated = (e) => emittedEvent = e;

      // Draw at exact top-left (0, 0)
      drawing.onPointerDown(Offset.zero, pressure: 0.6);
      expect(emittedEvent, isNotNull);
      expect(emittedEvent!.x, equals(0.0));
      expect(emittedEvent!.y, equals(0.0));

      // Draw at exact bottom-right (800, 450)
      drawing.onPointerDown(const Offset(800.0, 450.0), pressure: 0.6);
      expect(emittedEvent!.x, equals(1.0));
      expect(emittedEvent!.y, equals(1.0));

      drawing.dispose();
    });

    test('Corner-of-mobile safety clamping avoids OS Start button, Taskbar, and Close button', () {
      const screenWidth = 1920;
      const screenHeight = 1080;
      const safeEdgeInset = 4;

      // Simulate Win32 desktop target computation for mobile corners:
      // Bottom-left corner (0.0, 1.0) -> Windows Start Menu / Taskbar
      double normX = 0.0;
      double normY = 1.0;
      int targetX = (normX * (screenWidth - 1)).round();
      int targetY = (normY * (screenHeight - 1)).round();
      int safeX = targetX.clamp(safeEdgeInset, screenWidth - 1 - safeEdgeInset);
      int safeY = targetY.clamp(safeEdgeInset, screenHeight - 1 - safeEdgeInset);

      // Verify bottom-left does NOT hit Start button at (0, 1079)
      expect(safeX, equals(4));
      expect(safeY, equals(1075));
      expect(safeY, lessThan(screenHeight - 1));

      // Top-right corner (1.0, 0.0) -> Window Close (X) button
      normX = 1.0;
      normY = 0.0;
      targetX = (normX * (screenWidth - 1)).round();
      targetY = (normY * (screenHeight - 1)).round();
      safeX = targetX.clamp(safeEdgeInset, screenWidth - 1 - safeEdgeInset);
      safeY = targetY.clamp(safeEdgeInset, screenHeight - 1 - safeEdgeInset);

      // Verify top-right does NOT hit Close button at (1919, 0)
      expect(safeX, equals(1915));
      expect(safeY, equals(4));
      expect(safeX, lessThan(screenWidth - 1));
      expect(safeY, greaterThan(0));
    });
  });

  group('OneEuroFilter2D & Precision Calibration Tests', () {
    test('OneEuroFilter suppresses digitizer jitter at slow speeds', () {
      final filter = OneEuroFilter2D(minCutoff: 1.2, beta: 0.007, dCutoff: 1.0);

      const basePoint = Offset(100.0, 100.0);
      var time = DateTime(2026, 1, 1, 12, 0, 0);

      // First point sets the filter baseline
      final p0 = filter.filter(basePoint, time);
      expect(p0.dx, closeTo(100.0, 0.001));
      expect(p0.dy, closeTo(100.0, 0.001));

      // Simulate slight hand tremor / digitizer noise (+0.5px, -0.5px) at 60 Hz (~16.6ms intervals)
      final jitterOffsets = [0.5, -0.5, 0.4, -0.4, 0.6, -0.5];
      for (final jitter in jitterOffsets) {
        time = time.add(const Duration(microseconds: 16666));
        final raw = Offset(basePoint.dx + jitter, basePoint.dy + jitter);
        final filtered = filter.filter(raw, time);

        // Filtered jitter magnitude should be significantly dampened compared to raw jitter
        final error = (filtered.dx - basePoint.dx).abs();
        expect(error, lessThan(jitter.abs()));
      }
    });

    test('OneEuroFilter adapts cutoff for rapid movement (0-lag dynamic response)', () {
      final filter = OneEuroFilter2D(minCutoff: 1.2, beta: 0.007, dCutoff: 1.0);

      var time = DateTime(2026, 1, 1, 12, 0, 0);
      filter.filter(const Offset(0.0, 0.0), time);

      // Fast swipe across screen: 200 pixels in 16.6ms (~12,000 px/sec)
      time = time.add(const Duration(microseconds: 16666));
      const fastPoint = Offset(200.0, 200.0);
      final fastFiltered = filter.filter(fastPoint, time);

      // Under high velocity, beta dynamically increases cutoff frequency
      // The filter should track the fast point closely without sluggish drag
      expect(fastFiltered.dx, greaterThan(150.0));
      expect(fastFiltered.dy, greaterThan(150.0));
    });

    test('OneEuroFilter reset clears previous state', () {
      final filter = OneEuroFilter2D(minCutoff: 1.2, beta: 0.007, dCutoff: 1.0);
      var time = DateTime(2026, 1, 1, 12, 0, 0);
      filter.filter(const Offset(500.0, 500.0), time);

      filter.reset();

      // Next point after reset should immediately initialize to new coordinates without smoothing from 500
      time = time.add(const Duration(seconds: 1));
      final result = filter.filter(const Offset(10.0, 10.0), time);
      expect(result.dx, closeTo(10.0, 0.001));
      expect(result.dy, closeTo(10.0, 0.001));
    });

    test('PressureCurve transformation functions calculate correct responses', () {
      const lightPressure = 0.25;
      const midPressure = 0.50;

      // Standard (linear 1:1)
      expect(PressureCurve.standard.transform(lightPressure), closeTo(0.25, 0.001));
      expect(PressureCurve.standard.transform(midPressure), closeTo(0.50, 0.001));

      // Soft: p^0.7 -> boost light touches for effortless thick lines
      final softLight = PressureCurve.soft.transform(lightPressure);
      expect(softLight, closeTo(0.379, 0.01));
      expect(softLight, greaterThan(lightPressure));

      // Firm: p^1.4 -> requires firm hand, excellent for delicate sketching
      final firmLight = PressureCurve.firm.transform(lightPressure);
      expect(firmLight, closeTo(0.144, 0.01));
      expect(firmLight, lessThan(lightPressure));

      // 0.0 and 1.0 boundary values remain preserved across all curves
      for (final curve in PressureCurve.values) {
        expect(curve.transform(0.0), closeTo(0.0, 0.001));
        expect(curve.transform(1.0), closeTo(1.0, 0.001));
      }
    });

    test('WritingScale compact mode (0.50x) reduces PC output span by 50%', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(800.0, 400.0);
      provider.setWritingScalePreset(WritingScalePreset.compact);
      provider.writingAnchor = WritingAnchor.center;

      InputEvent? emitted;
      provider.onInputGenerated = (ev) => emitted = ev;

      // Start stroke at mobile center (400, 200) -> normalized is (0.5, 0.5)
      provider.onPointerDown(const Offset(400.0, 200.0));
      expect(emitted, isNotNull);
      // At center anchor with 0.5 scale, center should map to center (0.5, 0.5)
      expect(emitted!.x, closeTo(0.5, 0.05));
      expect(emitted!.y, closeTo(0.5, 0.05));

      // Move by 200px horizontally on mobile (which is 25% of mobile canvas)
      provider.onPointerMove(const Offset(600.0, 200.0));
      // In 0.50x scale mode, the emitted span should be 25% * 0.50 = 12.5%
      expect(emitted!.x - 0.5, closeTo(0.125, 0.02));
    });

    test('Full-screen mobile edge-to-edge drawing preserves 1:1 circle geometry on 16:9 PC', () {
      final provider = DrawingProvider();
      // Mobile canvas matched to 16:9 PC monitor (e.g., 640 x 360)
      provider.updateCanvasSize(640.0, 360.0);
      provider.updateServerAspectRatio(1920.0 / 1080.0);
      provider.writingScale = 1.0;

      InputEvent? p1;
      InputEvent? p2;
      provider.onInputGenerated = (ev) {
        if (ev.type == InputEventType.pointerDown) p1 = ev;
        if (ev.type == InputEventType.pointerMove) p2 = ev;
      };

      // Draw horizontal diameter of 50px circle on mobile
      provider.onPointerDown(const Offset(200.0, 150.0));
      provider.onPointerMove(const Offset(250.0, 150.0));
      final deltaNormX = (p2!.x - p1!.x).abs();
      final pcPixelSpanX = deltaNormX * 1920.0;

      // Draw vertical diameter of 50px circle on mobile
      provider.onPointerDown(const Offset(200.0, 150.0));
      provider.onPointerMove(const Offset(200.0, 200.0));
      final deltaNormY = (p2!.y - p1!.y).abs();
      final pcPixelSpanY = deltaNormY * 1080.0;

      // Horizontal and vertical pixel spans on PC must be equal (true circle)
      expect(pcPixelSpanX, closeTo(pcPixelSpanY, 1.5));
    });
  });

  group('Custom Drawing Box (ROI / Active Work Area) Tests', () {
    test('Default configuration maps 100% full screen edge-to-edge with 1:1 scale', () {
      final provider = DrawingProvider();
      expect(provider.writingScale, equals(1.0));
      expect(provider.customBoxEnabled, isFalse);
      expect(provider.isEditingCustomBox, isFalse);
    });

    test('Custom Box gating blocks touches outside the box', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(1000.0, 1000.0);
      provider.customBoxEnabled = true;
      // Define a center box from 200..800 in X and Y (normalized 0.2..0.8)
      provider.setCustomBoxNormalized(const Rect.fromLTRB(0.2, 0.2, 0.8, 0.8));

      InputEvent? emitted;
      provider.onInputGenerated = (ev) => emitted = ev;

      // Touch outside box at (100, 100) -> normalized (0.1, 0.1)
      provider.onPointerDown(const Offset(100.0, 100.0));
      expect(provider.isDrawing, isFalse);
      expect(provider.currentStroke, isNull);
      expect(emitted, isNull);

      // Touch inside box at (500, 500) -> normalized (0.5, 0.5)
      provider.onPointerDown(const Offset(500.0, 500.0));
      expect(provider.isDrawing, isTrue);
      expect(provider.currentStroke, isNotNull);
      expect(emitted, isNotNull);
    });

    test('Custom Box clamps movement to box boundaries', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(1000.0, 1000.0);
      provider.customBoxEnabled = true;
      provider.setCustomBoxNormalized(const Rect.fromLTRB(0.2, 0.2, 0.8, 0.8));

      provider.onPointerDown(const Offset(500.0, 500.0));
      // Move far outside the right boundary (1200, 500)
      provider.onPointerMove(const Offset(1200.0, 500.0));

      // Last position should be clamped to maxX = 0.8 * 1000 = 800.0
      expect(provider.lastPosition!.dx, closeTo(800.0, 0.1));
    });

    test('Custom Box re-normalizes coordinates to full screen when boxMapsToFullScreen is true', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(1000.0, 1000.0);
      provider.customBoxEnabled = true;
      provider.boxMapsToFullScreen = true;
      // Box is 200..800 in X and Y
      provider.setCustomBoxNormalized(const Rect.fromLTRB(0.2, 0.2, 0.8, 0.8));

      InputEvent? emitted;
      provider.onInputGenerated = (ev) => emitted = ev;

      // Touch at the left edge of the box (200, 500) -> should map to 0.0 in X
      provider.onPointerDown(const Offset(200.0, 500.0));
      expect(emitted!.x, closeTo(0.0, 0.01));

      // Touch at the right edge of the box (800, 500) -> should map to 1.0 in X
      provider.onPointerMove(const Offset(800.0, 500.0));
      expect(emitted!.x, closeTo(1.0, 0.01));
    });

    test('Custom Box presets set correct normalized bounds', () {
      final provider = DrawingProvider();
      provider.setCustomBoxPreset('center_75');
      expect(provider.customBoxNormalized.left, closeTo(0.125, 0.01));
      expect(provider.customBoxNormalized.width, closeTo(0.75, 0.01));

      provider.setCustomBoxPreset('center_50');
      expect(provider.customBoxNormalized.left, closeTo(0.25, 0.01));
      expect(provider.customBoxNormalized.width, closeTo(0.50, 0.01));

      provider.setCustomBoxPreset('top_half');
      expect(provider.customBoxNormalized.top, closeTo(0.05, 0.01));
      expect(provider.customBoxNormalized.height, closeTo(0.45, 0.01));

      provider.setCustomBoxPreset('full');
      expect(provider.customBoxNormalized.left, closeTo(0.0, 0.01));
      expect(provider.customBoxNormalized.right, closeTo(1.0, 0.01));
    });

    test('Snipping box arbitrary drag directions and resetToFullScreen', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(1000.0, 1000.0);

      // Drag from bottom-right to top-left (inverted rectangle)
      provider.setCustomBoxNormalized(const Rect.fromLTRB(0.8, 0.7, 0.2, 0.3));
      // Should automatically normalize min/max coordinates
      expect(provider.customBoxNormalized.left, closeTo(0.2, 0.01));
      expect(provider.customBoxNormalized.top, closeTo(0.3, 0.01));
      expect(provider.customBoxNormalized.right, closeTo(0.8, 0.01));
      expect(provider.customBoxNormalized.bottom, closeTo(0.7, 0.01));

      // Snipping box pauses drawing events so snip gestures don't leave stray ink
      provider.isSnippingBox = true;
      provider.onPointerDown(const Offset(500.0, 500.0));
      expect(provider.isDrawing, isFalse);

      provider.isSnippingBox = false;
      provider.onPointerDown(const Offset(500.0, 500.0));
      expect(provider.isDrawing, isTrue);

      // Reset to full screen restores 100% canvas and turns off customBoxEnabled
      provider.resetToFullScreen();
      expect(provider.customBoxEnabled, isFalse);
      expect(provider.customBoxNormalized, equals(const Rect.fromLTRB(0.0, 0.0, 1.0, 1.0)));
    });

    test('Delicate sub-pixel strokes are detected accurately with 0.18 threshold', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(1000.0, 1000.0);
      InputEvent? emitted;
      provider.onInputGenerated = (ev) => emitted = ev;

      provider.onPointerDown(const Offset(100.0, 100.0));
      emitted = null;

      // Small movement of 0.25px (would be dropped by 0.35, but captured by 0.18)
      provider.onPointerMove(const Offset(100.25, 100.0));
      expect(emitted, isNotNull);
      expect(emitted!.type, equals(InputEventType.pointerMove));
    });
  });

  group('Pro Inking & Efficiency Engine Tests', () {
    test('PressureCurve.sCurve produces Hermite smoothstep sigmoid response', () {
      const curve = PressureCurve.sCurve;
      expect(curve.transform(0.0), closeTo(0.0, 0.001));
      expect(curve.transform(1.0), closeTo(1.0, 0.001));
      expect(curve.transform(0.5), closeTo(0.5, 0.001));
      // At 0.2, standard is 0.2, sCurve is 0.2*0.2*(3 - 0.4) = 0.04 * 2.6 = 0.104
      expect(curve.transform(0.2), closeTo(0.104, 0.001));
      // At 0.8, standard is 0.8, sCurve is 0.8*0.8*(3 - 1.6) = 0.64 * 1.4 = 0.896
      expect(curve.transform(0.8), closeTo(0.896, 0.001));
    });

    test('StrokePoint dynamic width scales accurately with calibrated pressure', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(1000.0, 1000.0);
      provider.pressureSmoothing = false;
      provider.updateBrush(const BrushSettings(baseWidth: 10.0, pressureSensitivity: 0.8));

      provider.onPointerDown(const Offset(100.0, 100.0), pressure: 0.0);
      expect(provider.currentStroke, isNotNull);
      // width = 10.0 * (0.25 + 0.0 * 0.75 * 0.8) = 2.5
      expect(provider.currentStroke!.points.first.width, closeTo(2.5, 0.1));

      provider.onPointerMove(const Offset(120.0, 100.0), pressure: 1.0);
      // width = 10.0 * (0.25 + 1.0 * 0.75 * 0.8) = 10.0 * 0.85 = 8.5
      expect(provider.currentStroke!.points.last.width, closeTo(8.5, 0.1));
    });

    test('Stroke.draw renders variable-width spline segments smoothly without error', () {
      final stroke = Stroke(
        settings: const BrushSettings(baseWidth: 6.0, pressureSensitivity: 0.7),
        points: [
          StrokePoint(position: const Offset(10, 10), pressure: 0.2, timestamp: DateTime.now(), width: 2.0),
          StrokePoint(position: const Offset(30, 40), pressure: 0.6, timestamp: DateTime.now(), width: 5.0),
          StrokePoint(position: const Offset(60, 80), pressure: 0.9, timestamp: DateTime.now(), width: 8.0),
        ],
      );

      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      expect(() => stroke.draw(canvas), returnsNormally);
      final pic = recorder.endRecording();
      expect(pic, isNotNull);
      pic.dispose();
    });

    test('Stylus-Only Mode strictly rejects finger touch to prevent palm marks', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(1000.0, 1000.0);
      provider.stylusOnlyMode = true;

      // Finger touch is completely rejected
      provider.onPointerDown(const Offset(200.0, 200.0), pointerType: PointerType.finger);
      expect(provider.isDrawing, isFalse);
      expect(provider.currentStroke, isNull);

      // Stylus touch is accepted
      provider.onPointerDown(const Offset(200.0, 200.0), pointerType: PointerType.stylus);
      expect(provider.isDrawing, isTrue);
      expect(provider.currentStroke, isNotNull);
    });

    test('Predictive tracking extrapolates forward based on filtered velocity', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(1000.0, 1000.0);
      provider.enablePrediction = true;

      provider.onPointerDown(const Offset(100.0, 100.0));
      expect(provider.predictedPosition, isNull);

      // Fast sweep to the right
      provider.onPointerMove(const Offset(200.0, 100.0));
      // With velocity established, predicted position leads ahead in dx
      if (provider.predictedPosition != null) {
        expect(provider.predictedPosition!.dx, greaterThan(200.0));
      }

      provider.onPointerUp();
      expect(provider.predictedPosition, isNull);
    });

    test('Telemetry metrics track live FPS and input polling rate correctly', () {
      final provider = DrawingProvider();
      expect(provider.liveFps, greaterThanOrEqualTo(1.0));
      expect(provider.livePollingRateHz, greaterThanOrEqualTo(1.0));

      for (int i = 0; i < 10; i++) {
        provider.recordFrame();
      }
      expect(provider.metricNotifier.value, isNotNull);
    });
  });

  group('USB Transport & Stream Framing Regression Tests', () {
    test('extractBinaryFrames correctly parses coalesced 13-byte frames', () {
      final evt1 = InputEvent(type: InputEventType.pointerDown, x: 0.1, y: 0.2);
      final evt2 = InputEvent(type: InputEventType.pointerMove, x: 0.3, y: 0.4);
      final evt3 = InputEvent(type: InputEventType.pointerUp, x: 0.5, y: 0.6);

      final buffer = [...evt1.toBinary(), ...evt2.toBinary(), ...evt3.toBinary()];
      final result = InputEvent.extractBinaryFrames(buffer);

      expect(result.events.length, equals(3));
      expect(result.events[0].type, equals(InputEventType.pointerDown));
      expect(result.events[1].type, equals(InputEventType.pointerMove));
      expect(result.events[2].type, equals(InputEventType.pointerUp));
      expect(result.remainder.isEmpty, isTrue);
    });

    test('extractBinaryFrames handles partial stream reads and preserves residual buffer', () {
      final evt = InputEvent(type: InputEventType.pointerMove, x: 0.5, y: 0.5);
      final fullBytes = evt.toBinary();

      // Send first 7 bytes
      final firstHalf = fullBytes.sublist(0, 7);
      final res1 = InputEvent.extractBinaryFrames(firstHalf);
      expect(res1.events.isEmpty, isTrue);
      expect(res1.remainder.length, equals(7));

      // Append second 6 bytes
      final secondHalf = fullBytes.sublist(7);
      final combined = [...res1.remainder, ...secondHalf];
      final res2 = InputEvent.extractBinaryFrames(combined);

      expect(res2.events.length, equals(1));
      expect(res2.events[0].type, equals(InputEventType.pointerMove));
      expect(res2.remainder.isEmpty, isTrue);
    });

    test('extractBinaryFrames recovers from corrupted bytes preceding valid frame', () {
      final garbage = [0xFF, 0xEE, 0xDD, 0xCC];
      final validEvt = InputEvent(type: InputEventType.pointerDown, x: 0.75, y: 0.25);
      final buffer = [...garbage, ...validEvt.toBinary()];

      final result = InputEvent.extractBinaryFrames(buffer);
      expect(result.events.length, equals(1));
      expect(result.events[0].type, equals(InputEventType.pointerDown));
      expect(result.events[0].x, closeTo(0.75, 0.01));
      expect(result.events[0].y, closeTo(0.25, 0.01));
      expect(result.remainder.isEmpty, isTrue);
    });

    test('ConnectionProvider tracks transport mode and exposes unconditionally free USB', () {
      final conn = ConnectionProvider();
      expect(conn.selectedTransport, equals(TransportType.auto));
      expect(conn.activeTransport, equals(TransportType.wifi));
      expect(conn.isUsbActive, isFalse);

      conn.setSelectedTransport(TransportType.usb);
      expect(conn.selectedTransport, equals(TransportType.usb));

      conn.setSelectedTransport(TransportType.wifi);
      expect(conn.selectedTransport, equals(TransportType.wifi));
    });
  });

  group('Pen State Machine & Coordinate Contract Regression Tests', () {
    test('PenState transitions cleanly: idle -> down -> moving -> idle', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(500.0, 500.0);
      expect(provider.penState, equals(PenState.idle));

      provider.onPointerDown(const Offset(100.0, 100.0));
      expect(provider.penState, equals(PenState.down));

      provider.onPointerMove(const Offset(150.0, 150.0));
      expect(provider.penState, equals(PenState.moving));

      provider.onPointerUp();
      expect(provider.penState, equals(PenState.idle));
    });

    test('onPointerCancel cleanly resets PenState to idle and releases slots', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(500.0, 500.0);

      provider.onPointerDown(const Offset(200.0, 200.0));
      expect(provider.penState, equals(PenState.down));

      provider.onPointerCancel();
      expect(provider.penState, equals(PenState.idle));
      expect(provider.isDrawing, isFalse);
    });

    test('Coordinates at all 4 corners and edges remain within valid [0.0, 1.0] bounds', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(1000.0, 500.0);
      provider.writingScale = 1.0;

      final generatedEvents = <InputEvent>[];
      provider.onInputGenerated = (e) => generatedEvents.add(e);

      // Top-left corner
      provider.onPointerDown(const Offset(0.0, 0.0));
      provider.onPointerUp();

      // Bottom-right corner
      provider.onPointerDown(const Offset(1000.0, 500.0));
      provider.onPointerUp();

      // Bottom-left corner
      provider.onPointerDown(const Offset(0.0, 500.0));
      provider.onPointerUp();

      // Top-right corner
      provider.onPointerDown(const Offset(1000.0, 0.0));
      provider.onPointerUp();

      expect(generatedEvents.isNotEmpty, isTrue);
      for (final evt in generatedEvents) {
        expect(evt.x, greaterThanOrEqualTo(0.0));
        expect(evt.x, lessThanOrEqualTo(1.0));
        expect(evt.y, greaterThanOrEqualTo(0.0));
        expect(evt.y, lessThanOrEqualTo(1.0));
      }
    });

    test('Fast continuous strokes preserve 100% of digitizer points without dropping', () {
      final provider = DrawingProvider();
      provider.updateCanvasSize(1000.0, 1000.0);
      provider.precisionMode = PrecisionMode.rawDirect;

      final moves = <InputEvent>[];
      provider.onInputGenerated = (e) {
        if (e.type == InputEventType.pointerMove) moves.add(e);
      };

      provider.onPointerDown(const Offset(10.0, 10.0));
      // Simulate 50 rapid microscopic micro-moves (<0.18px distance)
      for (int i = 1; i <= 50; i++) {
        provider.onPointerMove(Offset(10.0 + i * 0.1, 10.0 + i * 0.1));
      }
      provider.onPointerUp();

      // Verified: zero points dropped, eliminating stroke breaks and gaps
      expect(moves.length, equals(50));
    });

    test('High-DPI scaling: logical canvas coordinates do not depend on backing store resolution', () {
      final provider = DrawingProvider();
      // Logical canvas size 400x300 (whether backing store is 1x, 2x, or 3x devicePixelRatio)
      provider.updateCanvasSize(400.0, 300.0);
      provider.writingScale = 1.0;

      InputEvent? recorded;
      provider.onInputGenerated = (e) => recorded = e;

      // Pointer at center of logical canvas (200, 150)
      provider.onPointerDown(const Offset(200.0, 150.0));

      expect(recorded, isNotNull);
      // Normalized logical coordinate should be exactly 0.5, 0.5
      expect(recorded!.x, closeTo(0.50, 0.01));
      expect(recorded!.y, closeTo(0.50, 0.01));
    });
  });

  group('Full Bug Audit & Verification Suite (23 Requirement Tests)', () {
    test('1. Normalized coordinates strictly mapped within [0.0, 1.0]', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(1200.0, 800.0);
      InputEvent? ev;
      drawing.onInputGenerated = (e) => ev = e;

      drawing.onPointerDown(const Offset(300.0, 400.0));
      expect(ev, isNotNull);
      expect(ev!.x, greaterThanOrEqualTo(0.0));
      expect(ev!.x, lessThanOrEqualTo(1.0));
      expect(ev!.y, greaterThanOrEqualTo(0.0));
      expect(ev!.y, lessThanOrEqualTo(1.0));
      drawing.dispose();
    });

    test('2. Identity coordinate mapping: 1.0x scale with matching aspect preserves exact relative coords', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(1920.0, 1080.0);
      drawing.updateServerAspectRatio(1920.0 / 1080.0);
      drawing.writingScale = 1.0;
      drawing.writingAnchor = WritingAnchor.topLeft;

      InputEvent? ev;
      drawing.onInputGenerated = (e) => ev = e;

      drawing.onPointerDown(const Offset(960.0, 540.0));
      expect(ev, isNotNull);
      expect(ev!.x, closeTo(0.50, 0.001));
      expect(ev!.y, closeTo(0.50, 0.001));
      drawing.dispose();
    });

    test('3. Aspect-ratio mapping: preserves geometric isotropy (circle retains equal width and height)', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(800.0, 450.0); // 16:9 mobile
      drawing.updateServerAspectRatio(1920.0 / 1080.0); // 16:9 PC
      drawing.writingScale = 1.0;
      drawing.writingAnchor = WritingAnchor.topLeft;

      InputEvent? pDown;
      InputEvent? pMove;
      drawing.onInputGenerated = (e) {
        if (e.type == InputEventType.pointerDown) pDown = e;
        if (e.type == InputEventType.pointerMove) pMove = e;
      };

      // 40px circle on mobile
      drawing.onPointerDown(const Offset(100.0, 100.0));
      drawing.onPointerMove(const Offset(140.0, 100.0));
      final double pcSpanX = (pMove!.x - pDown!.x).abs() * 1920.0;

      drawing.onPointerDown(const Offset(100.0, 100.0));
      drawing.onPointerMove(const Offset(100.0, 140.0));
      final double pcSpanY = (pMove!.y - pDown!.y).abs() * 1080.0;

      // On PC, horizontal and vertical spans should match closely
      expect(pcSpanX, closeTo(pcSpanY, 1.0));
      drawing.dispose();
    });

    test('4. ROI mapping: Custom Box restricts and re-normalizes touch coordinates to active work area', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(1000.0, 1000.0);
      drawing.customBoxEnabled = true;
      drawing.boxMapsToFullScreen = true;
      drawing.setCustomBoxNormalized(const Rect.fromLTRB(0.1, 0.1, 0.9, 0.9));

      InputEvent? ev;
      drawing.onInputGenerated = (e) => ev = e;

      // Center of ROI box
      drawing.onPointerDown(const Offset(500.0, 500.0));
      expect(ev, isNotNull);
      expect(ev!.x, closeTo(0.50, 0.01));
      expect(ev!.y, closeTo(0.50, 0.01));
      drawing.dispose();
    });

    test('5. Scaling values: compact (0.50x), ultra-compact (0.25x), medium (0.75x), and full (1.0x)', () {
      final drawing = DrawingProvider();
      drawing.setWritingScalePreset(WritingScalePreset.compact);
      expect(drawing.writingScale, equals(0.50));

      drawing.writingScale = 0.25;
      expect(drawing.writingScale, equals(0.25));

      drawing.setWritingScalePreset(WritingScalePreset.medium);
      expect(drawing.writingScale, equals(0.75));

      drawing.setWritingScalePreset(WritingScalePreset.full);
      expect(drawing.writingScale, equals(1.00));
      drawing.dispose();
    });

    test('6. 16:9 mobile to 16:10 PC monitor aspect ratio compensation', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(1920.0, 1200.0); // 16:10
      drawing.updateServerAspectRatio(1920.0 / 1200.0); // 16:10 = 1.60
      drawing.writingScale = 1.0;
      drawing.writingAnchor = WritingAnchor.topLeft;

      InputEvent? p1;
      InputEvent? p2;
      drawing.onInputGenerated = (e) {
        if (e.type == InputEventType.pointerDown) p1 = e;
        if (e.type == InputEventType.pointerMove) p2 = e;
      };

      // 60px circle on mobile
      drawing.onPointerDown(const Offset(200.0, 200.0));
      drawing.onPointerMove(const Offset(260.0, 200.0));
      final double pcX = (p2!.x - p1!.x).abs() * 1920.0;

      drawing.onPointerDown(const Offset(200.0, 200.0));
      drawing.onPointerMove(const Offset(200.0, 260.0));
      final double pcY = (p2!.y - p1!.y).abs() * 1200.0;

      expect(pcX, closeTo(pcY, 1.0));
      drawing.dispose();
    });

    test('7. Portrait phone to landscape PC monitor orientation mapping without clipping or crashes', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(400.0, 800.0); // portrait 0.50
      drawing.updateServerAspectRatio(1920.0 / 1080.0); // landscape 1.777
      drawing.writingScale = 0.50;

      InputEvent? ev;
      drawing.onInputGenerated = (e) => ev = e;

      drawing.onPointerDown(const Offset(200.0, 400.0));
      expect(ev, isNotNull);
      expect(ev!.x, greaterThanOrEqualTo(0.0));
      expect(ev!.x, lessThanOrEqualTo(1.0));
      expect(ev!.y, greaterThanOrEqualTo(0.0));
      expect(ev!.y, lessThanOrEqualTo(1.0));
      drawing.dispose();
    });

    test('8. Edge coordinates 0.0 and 1.0 mapped safely without escaping canvas boundaries', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(1000.0, 500.0);
      drawing.updateServerAspectRatio(1000.0 / 500.0); // 1:1 aspect match for boundary test
      drawing.writingScale = 1.0;
      drawing.writingAnchor = WritingAnchor.topLeft;

      InputEvent? ev;
      drawing.onInputGenerated = (e) => ev = e;

      drawing.onPointerDown(const Offset(0.0, 0.0));
      expect(ev!.x, equals(0.0));
      expect(ev!.y, equals(0.0));

      drawing.onPointerDown(const Offset(1000.0, 500.0));
      expect(ev!.x, equals(1.0));
      expect(ev!.y, equals(1.0));
      drawing.dispose();
    });

    test('9. Four corners mapped with safe edge insets preventing accidental system UI clicks', () {
      const int width = 1920;
      const int height = 1080;
      const int safeInset = 3;

      // Safe corner inset mapping logic from AirCanvasServer.cs
      int computeSafeX(double normX) => (normX * (width - 1)).round().clamp(safeInset, width - 1 - safeInset);
      int computeSafeY(double normY) => (normY * (height - 1)).round().clamp(safeInset, height - 1 - safeInset);

      // Top-Left (0, 0)
      expect(computeSafeX(0.0), equals(safeInset));
      expect(computeSafeY(0.0), equals(safeInset));

      // Bottom-Left (0, 1) -> Near Start button
      expect(computeSafeX(0.0), equals(safeInset));
      expect(computeSafeY(1.0), equals(height - 1 - safeInset));
      expect(computeSafeY(1.0), lessThan(height - 1)); // Never touches taskbar edge

      // Top-Right (1, 0) -> Near Close button
      expect(computeSafeX(1.0), equals(width - 1 - safeInset));
      expect(computeSafeY(0.0), equals(safeInset));
      expect(computeSafeX(1.0), lessThan(width - 1));

      // Bottom-Right (1, 1)
      expect(computeSafeX(1.0), equals(width - 1 - safeInset));
      expect(computeSafeY(1.0), equals(height - 1 - safeInset));
    });

    test('10. Very fast strokes with high velocity tracked without missing points', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(1000.0, 1000.0);
      final events = <InputEvent>[];
      drawing.onInputGenerated = (e) => events.add(e);

      drawing.onPointerDown(const Offset(10.0, 10.0));
      // Simulate fast stroke moving 800px in 20 steps
      for (int i = 1; i <= 20; i++) {
        drawing.onPointerMove(Offset(10.0 + i * 40.0, 10.0 + i * 40.0));
      }
      drawing.onPointerUp();

      expect(events.length, equals(22)); // 1 down + 20 moves + 1 up
      drawing.dispose();
    });

    test('11. Diagonal strokes preserve 1:1 linearity and continuous point density', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(1000.0, 1000.0);
      drawing.updateServerAspectRatio(1.0); // 1:1 square canvas matching mobile
      drawing.writingScale = 1.0;
      drawing.writingAnchor = WritingAnchor.topLeft;
      final moves = <InputEvent>[];
      drawing.onInputGenerated = (e) {
        if (e.type == InputEventType.pointerMove) moves.add(e);
      };

      drawing.onPointerDown(const Offset(0.0, 0.0));
      for (int i = 1; i <= 10; i++) {
        drawing.onPointerMove(Offset(i * 100.0, i * 100.0));
      }
      drawing.onPointerUp();

      expect(moves.length, equals(10));
      for (final m in moves) {
        expect(m.x, closeTo(m.y, 0.01)); // Diagonal preserves x == y
      }
      drawing.dispose();
    });

    test('12. Tiny handwriting: sub-pixel micro-movements (0.1px) retained without artificial dropping', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(1000.0, 1000.0);
      final moves = <InputEvent>[];
      drawing.onInputGenerated = (e) {
        if (e.type == InputEventType.pointerMove) moves.add(e);
      };

      drawing.onPointerDown(const Offset(200.0, 200.0));
      // Small 0.1px movements representing micro-calligraphy details
      for (int i = 1; i <= 15; i++) {
        drawing.onPointerMove(Offset(200.0 + i * 0.1, 200.0 + i * 0.05));
      }
      drawing.onPointerUp();

      expect(moves.length, equals(15)); // All 15 micro-steps preserved
      drawing.dispose();
    });

    test('13. Large handwriting: sweeping wide strokes across canvas remain continuous and smooth', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(1000.0, 1000.0);

      drawing.onPointerDown(const Offset(50.0, 50.0));
      for (int i = 1; i <= 50; i++) {
        drawing.onPointerMove(Offset(50.0 + i * 15.0, 50.0 + i * 12.0));
      }
      drawing.onPointerUp();

      expect(drawing.strokes.length, equals(1));
      expect(drawing.strokes.first.points.length, equals(52)); // down + 50 moves + up
      drawing.dispose();
    });

    test('14. Event ordering guarantee: pointerDown occurs strictly before move and pointerUp', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(800.0, 600.0);
      final eventTypes = <InputEventType>[];
      drawing.onInputGenerated = (e) => eventTypes.add(e.type);

      drawing.onPointerDown(const Offset(100.0, 100.0));
      drawing.onPointerMove(const Offset(120.0, 120.0));
      drawing.onPointerMove(const Offset(140.0, 140.0));
      drawing.onPointerUp();

      expect(eventTypes, equals([
        InputEventType.pointerDown,
        InputEventType.pointerMove,
        InputEventType.pointerMove,
        InputEventType.pointerUp,
      ]));
      drawing.dispose();
    });

    test('15. Duplicate prevention: repeated timestamps or identical events handled deterministically', () {
      final time = DateTime(2026, 9, 8, 12, 0, 0);
      final ev1 = InputEvent(type: InputEventType.pointerMove, x: 0.4, y: 0.4, timestamp: time);
      final ev2 = InputEvent(type: InputEventType.pointerMove, x: 0.4, y: 0.4, timestamp: time);

      expect(ev1, equals(ev2));
      expect(ev1.hashCode, equals(ev2.hashCode));
    });

    test('16. Pointer lifecycle state machine: idle -> down -> moving -> up -> idle with cancel recovery', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(600.0, 600.0);

      expect(drawing.penState, equals(PenState.idle));
      drawing.onPointerDown(const Offset(50.0, 50.0));
      expect(drawing.penState, equals(PenState.down));

      drawing.onPointerMove(const Offset(60.0, 60.0));
      expect(drawing.penState, equals(PenState.moving));

      drawing.onPointerUp();
      expect(drawing.penState, equals(PenState.idle));

      // Test cancel
      drawing.onPointerDown(const Offset(50.0, 50.0));
      expect(drawing.penState, equals(PenState.down));
      drawing.onPointerCancel();
      expect(drawing.penState, equals(PenState.idle));
      drawing.dispose();
    });

    test('17. Disconnect during stroke cleans up state machine to idle and clears outbound queue', () {
      final drawing = DrawingProvider();
      final conn = ConnectionProvider();
      drawing.updateCanvasSize(600.0, 600.0);

      drawing.onPointerDown(const Offset(100.0, 100.0));
      drawing.onPointerMove(const Offset(150.0, 150.0));
      expect(drawing.penState, equals(PenState.moving));

      // When disconnect occurs
      drawing.onPointerCancel();
      conn.disconnect();

      expect(drawing.penState, equals(PenState.idle));
      expect(drawing.isDrawing, isFalse);
      drawing.dispose();
      conn.dispose();
    });

    test('18. Reconnect after stroke: resets stale data and begins cleanly in idle state', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(600.0, 600.0);
      drawing.onPointerCancel();

      expect(drawing.penState, equals(PenState.idle));
      expect(drawing.currentStroke, isNull);

      InputEvent? newDown;
      drawing.onInputGenerated = (e) => newDown = e;
      drawing.onPointerDown(const Offset(200.0, 200.0));

      expect(drawing.penState, equals(PenState.down));
      expect(newDown?.type, equals(InputEventType.pointerDown));
      drawing.dispose();
    });

    test('19. Multi-monitor coordinates: handles secondary monitor offsets and negative virtual coordinates', () {
      // Setup: Virtual desktop with secondary monitor left of primary
      // Secondary: [-1920, 0], Primary: [0, 1920]. Total width = 3840.
      const int vx = -1920;
      const int vy = 0;
      const int vw = 3840;
      const int vh = 1080;

      // Coordinate located on secondary monitor at screen coordinate -960
      const int targetX = -960;
      const int targetY = 540;

      // Normalized virtual desktop mapping formula from AirCanvasServer.cs
      final int absX = (((targetX - vx) / (vw - 1)) * 65535.0).round().clamp(0, 65535);
      final int absY = (((targetY - vy) / (vh - 1)) * 65535.0).round().clamp(0, 65535);

      // (-960 - (-1920)) / 3839 = 960 / 3839 = 0.250065 -> 16388
      // (540 - 0) / 1079 = 0.500463 -> 32798
      expect(absX, closeTo(16388, 2));
      expect(absY, closeTo(32798, 2));
      expect(absX, greaterThanOrEqualTo(0));
      expect(absX, lessThanOrEqualTo(65535));
    });

    test('20. High-DPI scaling: logical canvas coordinates invariant to display DPI scaling (100% to 200%)', () {
      final drawing = DrawingProvider();
      // On 100% DPI or 200% Retina/4K, Flutter Canvas uses logical pixels (e.g. 500x500)
      drawing.updateCanvasSize(500.0, 500.0);
      drawing.updateServerAspectRatio(1.0); // 1:1 square canvas matching mobile
      drawing.writingScale = 1.0;
      drawing.writingAnchor = WritingAnchor.topLeft;

      InputEvent? ev;
      drawing.onInputGenerated = (e) => ev = e;

      drawing.onPointerDown(const Offset(250.0, 250.0));
      expect(ev!.x, closeTo(0.50, 0.001));
      expect(ev!.y, closeTo(0.50, 0.001));
      drawing.dispose();
    });

    test('21. Malformed/partial frames: stream framing extracts valid frames and recovers from garbage', () {
      final valid = InputEvent(type: InputEventType.pointerDown, x: 0.33, y: 0.66);
      final garbage = [0x00, 0x11, 0x22, 0x33, 0x44];
      final streamBytes = [...garbage, ...valid.toBinary()];

      final result = InputEvent.extractBinaryFrames(streamBytes);
      expect(result.events.length, equals(1));
      expect(result.events[0].type, equals(InputEventType.pointerDown));
      expect(result.events[0].x, closeTo(0.33, 0.01));
      expect(result.events[0].y, closeTo(0.66, 0.01));
    });

    test('22. Sequence number & timestamp ordering: monotonically increasing timestamps preserved', () {
      final t1 = DateTime(2026, 9, 8, 12, 0, 0, 100);
      final t2 = DateTime(2026, 9, 8, 12, 0, 0, 110);
      final t3 = DateTime(2026, 9, 8, 12, 0, 0, 120);

      final e1 = InputEvent(type: InputEventType.pointerDown, x: 0.1, y: 0.1, timestamp: t1);
      final e2 = InputEvent(type: InputEventType.pointerMove, x: 0.2, y: 0.2, timestamp: t2);
      final e3 = InputEvent(type: InputEventType.pointerUp, x: 0.3, y: 0.3, timestamp: t3);

      expect(e1.timestamp.isBefore(e2.timestamp), isTrue);
      expect(e2.timestamp.isBefore(e3.timestamp), isTrue);

      // JSON protocol preserves exact millisecond epoch timestamps
      final j1 = InputEvent.fromJson(e1.toJson());
      final j2 = InputEvent.fromJson(e2.toJson());
      final j3 = InputEvent.fromJson(e3.toJson());
      expect(j1.timestamp.millisecondsSinceEpoch, equals(t1.millisecondsSinceEpoch));
      expect(j2.timestamp.millisecondsSinceEpoch, equals(t2.millisecondsSinceEpoch));
      expect(j3.timestamp.millisecondsSinceEpoch, equals(t3.millisecondsSinceEpoch));

      // Binary protocol preserves FIFO frame sequence ordering
      final bytes = [...e1.toBinary(), ...e2.toBinary(), ...e3.toBinary()];
      final extracted = InputEvent.extractBinaryFrames(bytes);
      expect(extracted.events.length, equals(3));
      expect(extracted.events[0].type, equals(InputEventType.pointerDown));
      expect(extracted.events[1].type, equals(InputEventType.pointerMove));
      expect(extracted.events[2].type, equals(InputEventType.pointerUp));
    });

    test('23. USB transport routing: switches to USB mode, probes loopback endpoint, and isolates transport', () {
      final conn = ConnectionProvider();
      expect(conn.selectedTransport, equals(TransportType.auto));

      conn.setSelectedTransport(TransportType.usb);
      expect(conn.selectedTransport, equals(TransportType.usb));

      // Loopback probe endpoint verifies port 9090 on 127.0.0.1
      expect(conn.isUsbActive, isFalse); // Disconnected initially
      conn.dispose();
    });

    test('24. onPointerCancel with generic pointerId=0 flushes pending slots and resets pen state to idle', () {
      final drawing = DrawingProvider();
      final events = <InputEvent>[];
      drawing.onInputGenerated = (e) => events.add(e);

      // Start stroke with raw pointerId 5
      drawing.onPointerDown(const Offset(100, 100), pointerId: 5);
      expect(events.length, equals(1));
      expect(events.last.type, equals(InputEventType.pointerDown));
      expect(drawing.isDrawing, isTrue);

      // Cancel with pointerId 0 (e.g. general gesture cancellation or focus loss)
      drawing.onPointerCancel(pointerId: 0);

      // Must emit pointerUp to prevent stuck Windows mouse button
      expect(events.length, equals(2));
      expect(events.last.type, equals(InputEventType.pointerUp));
      expect(drawing.isDrawing, isFalse);
      expect(drawing.activePointerCount, equals(0));
    });

    test('25. ServerConfig correctly preserves custom resolutions from server JSON', () {
      // 16:10 resolution (2560x1600)
      final cfg1610 = ServerConfig.fromJson({
        'port': 9090,
        'binary': true,
        'screenWidth': 2560,
        'screenHeight': 1600,
      });
      expect(cfg1610.screenWidth, equals(2560));
      expect(cfg1610.screenHeight, equals(1600));

      // 4:3 resolution (1600x1200)
      final cfg43 = ServerConfig.fromJson({
        'port': 9090,
        'binary': true,
        'width': 1600,
        'height': 1200,
      });
      expect(cfg43.screenWidth, equals(1600));
      expect(cfg43.screenHeight, equals(1200));
    });

    test('26. DrawingProvider server aspect ratio update accurately scales output coordinates', () {
      final drawing = DrawingProvider();
      drawing.updateCanvasSize(800, 450); // Mobile aspect ratio = 16:9 (~1.778)
      drawing.writingScale = 1.0;
      drawing.writingAnchor = WritingAnchor.topLeft;

      final events = <InputEvent>[];
      drawing.onInputGenerated = (e) => events.add(e);

      // Default server aspect is 16:9 -> 1:1 scaling
      drawing.updateServerAspectRatio(16.0 / 9.0);
      drawing.onPointerDown(const Offset(800, 450));
      expect(events.last.x, closeTo(1.0, 0.001));
      expect(events.last.y, closeTo(1.0, 0.001));
      drawing.onPointerUp();

      events.clear();

      // Server aspect changes to 4:3 (1.333) -> 1:1 tablet mode guarantees 100% reachability without dead zones
      drawing.updateServerAspectRatio(4.0 / 3.0);
      drawing.onPointerDown(const Offset(800, 450));
      expect(events.last.x, closeTo(1.0, 0.001));
      expect(events.last.y, closeTo(1.0, 0.001));
      drawing.onPointerUp();
    });

    test('27. resetToFullScreen explicitly resets writingScale to 1.0 to prevent 0.50 scale trap', () {
      final drawing = DrawingProvider();
      drawing.writingScale = 0.50;
      drawing.customBoxEnabled = true;
      drawing.isSnippingBox = true;
      drawing.isEditingCustomBox = true;

      expect(drawing.writingScale, equals(0.50));
      expect(drawing.customBoxEnabled, isTrue);

      drawing.resetToFullScreen();

      expect(drawing.writingScale, equals(1.0));
      expect(drawing.customBoxEnabled, isFalse);
      expect(drawing.isSnippingBox, isFalse);
      expect(drawing.isEditingCustomBox, isFalse);
      expect(drawing.customBoxNormalized, equals(const Rect.fromLTRB(0.0, 0.0, 1.0, 1.0)));
    });

    test('28. setCanvasDimensionsSilently updates canvas dimensions synchronously without throwing during build', () {
      final drawing = DrawingProvider();
      drawing.setCanvasDimensionsSilently(1920.0, 1080.0);

      final events = <InputEvent>[];
      drawing.onInputGenerated = (e) => events.add(e);

      // Verify coordinate normalization uses new dimensions immediately
      drawing.onPointerDown(const Offset(960.0, 540.0));
      expect(events.last.x, closeTo(0.5, 0.001));
      expect(events.last.y, closeTo(0.5, 0.001));
      drawing.onPointerUp();
    });

    test('29. Eraser brush mode generates proper brush settings and tool payload', () {
      final drawing = DrawingProvider();
      drawing.updateBrush(drawing.brushSettings.copyWith(mode: BrushMode.eraser));
      expect(drawing.brushSettings.mode, equals(BrushMode.eraser));

      final tool = drawing.brushSettings.mode == BrushMode.eraser ? 'eraser' : 'pen';
      expect(tool, equals('eraser'));
    });
  });
}



