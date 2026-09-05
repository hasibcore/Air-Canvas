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
      final phoneRatio = phoneConstraintsW / phoneConstraintsH;
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
      final normalizedXSpan = circleDiameter / canvasW;
      final normalizedYSpan = circleDiameter / canvasH;

      final pcXSpan = normalizedXSpan * pcWidth;
      final pcYSpan = normalizedYSpan * pcHeight;

      // In stretched mode, width and height are significantly mismatched (~22% distortion)
      expect((pcXSpan - pcYSpan).abs(), greaterThan(10.0));
      expect(pcXSpan / pcYSpan, isNot(closeTo(1.0, 0.05)));
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
      final fastPoint = const Offset(200.0, 200.0);
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
  });
}
