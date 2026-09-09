import 'package:flutter_test/flutter_test.dart';
import 'package:air_canvas/models/input_event.dart';
import 'package:air_canvas/services/drawing_provider.dart';

void main() {
  group('Windows Synthetic Pen & Protocol v2 Tests', () {
    test('Protocol v1 produces 13 bytes and decodes accurately', () {
      final event = InputEvent(
        type: InputEventType.pointerDown,
        x: 0.5,
        y: 0.25,
        pressure: 0.75,
        pointerType: PointerType.stylus,
        pointerId: 1,
        tiltX: 20.0,
        tiltY: -30.0,
        buttons: 1,
        sequenceNumber: 42,
        timestamp: DateTime.now(),
      );

      final v1Bytes = event.toBinary(v2: false);
      expect(v1Bytes.length, equals(13));
      expect(v1Bytes[0], equals(InputEventType.pointerDown.index));
      expect(v1Bytes[11], equals(1)); // protocolVersion = 1

      final decoded = InputEvent.fromBinary(v1Bytes);
      expect(decoded.type, equals(InputEventType.pointerDown));
      expect((decoded.x - 0.5).abs(), lessThan(0.001));
      expect((decoded.y - 0.25).abs(), lessThan(0.001));
      expect((decoded.pressure - 0.75).abs(), lessThan(0.01));
      expect(decoded.pointerType, equals(PointerType.stylus));
    });

    test('Protocol v2 produces 17 bytes with sequence number and tilt', () {
      final event = InputEvent(
        type: InputEventType.pointerMove,
        x: 0.8,
        y: 0.4,
        pressure: 0.9,
        pointerType: PointerType.stylus,
        pointerId: 2,
        tiltX: 45.0,
        tiltY: -45.0,
        buttons: 1,
        sequenceNumber: 123456,
        timestamp: DateTime.now(),
      );

      final v2Bytes = event.toBinary(v2: true);
      expect(v2Bytes.length, equals(17));
      expect(v2Bytes[11], equals(2)); // protocolVersionV2 = 2

      // Check sequence number bytes 12..15
      final seqDecoded = ((v2Bytes[12] & 0xFF) << 24) |
          ((v2Bytes[13] & 0xFF) << 16) |
          ((v2Bytes[14] & 0xFF) << 8) |
          (v2Bytes[15] & 0xFF);
      expect(seqDecoded, equals(123456));

      // Verify deserialization
      final decoded = InputEvent.fromBinary(v2Bytes);
      expect(decoded.type, equals(InputEventType.pointerMove));
      expect(decoded.sequenceNumber, equals(123456));
      expect((decoded.tiltX - 45.0).abs(), lessThan(1.5));
      expect((decoded.tiltY - (-45.0)).abs(), lessThan(1.5));
      expect((decoded.pressure - 0.9).abs(), lessThan(0.01));
    });

    test('DrawingProvider increments sequence counter monotonically', () {
      final provider = DrawingProvider();
      final sequenceNumbers = <int>[];

      provider.onInputGenerated = (event) {
        sequenceNumbers.add(event.sequenceNumber);
      };

      provider.updateCanvasSize(1920, 1080);
      provider.onPointerDown(const Offset(100, 100));
      provider.onPointerMove(const Offset(110, 110));
      provider.onPointerMove(const Offset(120, 120));
      provider.onPointerUp();

      expect(sequenceNumbers.length, equals(4));
      expect(sequenceNumbers[0], equals(1));
      expect(sequenceNumbers[1], equals(2));
      expect(sequenceNumbers[2], equals(3));
      expect(sequenceNumbers[3], equals(4));
    });

    test('DrawingProvider emits hover events when stylus is in proximity', () {
      final provider = DrawingProvider();
      InputEvent? capturedEvent;

      provider.onInputGenerated = (event) {
        capturedEvent = event;
      };

      provider.updateCanvasSize(1000, 1000);
      provider.onPointerHover(
        const Offset(500, 500),
        pointerType: PointerType.stylus,
        tiltX: 15.0,
        tiltY: -10.0,
      );

      expect(capturedEvent, isNotNull);
      expect(capturedEvent!.type, equals(InputEventType.hover));
      expect(capturedEvent!.pressure, equals(0.0));
      expect(capturedEvent!.pointerType, equals(PointerType.stylus));
      expect((capturedEvent!.x - 0.5).abs(), lessThan(0.01));
      expect((capturedEvent!.y - 0.5).abs(), lessThan(0.01));
      expect((capturedEvent!.tiltX - 15.0).abs(), lessThan(0.1));
      expect((capturedEvent!.tiltY - (-10.0)).abs(), lessThan(0.1));
    });

    test('DrawingProvider ignores hover while actively inking a stroke', () {
      final provider = DrawingProvider();
      final events = <InputEvent>[];

      provider.onInputGenerated = (event) {
        events.add(event);
      };

      provider.updateCanvasSize(1000, 1000);
      provider.onPointerDown(const Offset(100, 100));
      // Attempt hover while drawing
      provider.onPointerHover(const Offset(200, 200));
      provider.onPointerUp();

      // Should only have down and up, no hover event while drawing
      expect(events.any((e) => e.type == InputEventType.hover), isFalse);
      expect(events.length, equals(2));
    });
  });
}
