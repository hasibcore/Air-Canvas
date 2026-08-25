import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:air_canvas/models/input_event.dart';
import 'package:air_canvas/services/connection_provider.dart';

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

    test('ServerConfig supports binary and custom port configuration', () {
      const config = ServerConfig(
        port: 9090,
        useBinaryProtocol: true,
        enablePressureSmoothing: true,
        enablePrediction: true,
      );

      final json = config.toJson();
      final restored = ServerConfig.fromJson(json);

      expect(restored.port, equals(9090));
      expect(restored.useBinaryProtocol, isTrue);
      expect(restored.enablePressureSmoothing, isTrue);
      expect(restored.enablePrediction, isTrue);
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
}
