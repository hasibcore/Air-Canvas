// ignore_for_file: avoid_print
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:air_canvas/models/input_event.dart';
import 'package:air_canvas/services/connection_provider.dart';
import 'package:air_canvas/services/drawing_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('AIRCanvas Checkpoint Validations', () {
    late DrawingProvider drawing;
    late List<InputEvent> emittedEvents;

    setUp(() {
      drawing = DrawingProvider();
      emittedEvents = <InputEvent>[];
      drawing.onInputGenerated = (e) => emittedEvents.add(e);
      // Simulate standard phone screen: 1080 x 2400
      drawing.updateCanvasSize(1080.0, 2400.0);
    });

    test('CHECKPOINT A & B: Mobile Left, Quarter, Center, Three-Quarter, Right produce exact normalized 0.0, 0.25, 0.50, 0.75, 1.0', () {
      expect(drawing.writingScale, equals(1.0), reason: 'Default writing scale MUST be 1.0 (Full Screen Tablet Mode)');

      // Test Far Left: X = 0.0
      drawing.onPointerDown(const Offset(0.0, 1200.0), pointerId: 1);
      expect(emittedEvents.last.x, closeTo(0.0, 0.001), reason: 'Mobile X=0.0 MUST map to normalized X=0.0 (Far Left)');
      drawing.onPointerUp(pointerId: 1);

      // Test Quarter: X = 270.0 (270 / 1080 = 0.25)
      drawing.onPointerDown(const Offset(270.0, 1200.0), pointerId: 2);
      expect(emittedEvents.last.x, closeTo(0.25, 0.001), reason: 'Mobile X=0.25 MUST map to normalized X=0.25');
      drawing.onPointerUp(pointerId: 2);

      // Test Center: X = 540.0 (540 / 1080 = 0.50)
      drawing.onPointerDown(const Offset(540.0, 1200.0), pointerId: 3);
      expect(emittedEvents.last.x, closeTo(0.50, 0.001), reason: 'Mobile X=0.50 MUST map to normalized X=0.50 (Center)');
      drawing.onPointerUp(pointerId: 3);

      // Test Three-Quarter: X = 810.0 (810 / 1080 = 0.75)
      drawing.onPointerDown(const Offset(810.0, 1200.0), pointerId: 4);
      expect(emittedEvents.last.x, closeTo(0.75, 0.001), reason: 'Mobile X=0.75 MUST map to normalized X=0.75');
      drawing.onPointerUp(pointerId: 4);

      // Test Far Right: X = 1080.0 (1080 / 1080 = 1.0)
      drawing.onPointerDown(const Offset(1080.0, 1200.0), pointerId: 5);
      expect(emittedEvents.last.x, closeTo(1.0, 0.001), reason: 'Mobile X=1.0 MUST map to normalized X=1.0 (Far Right)');
      drawing.onPointerUp(pointerId: 5);
    });

    test('CHECKPOINT A & E: All 4 Corners and Full Canvas Reachability', () {
      // Top-Left Corner (0, 0)
      drawing.onPointerDown(const Offset(0.0, 0.0), pointerId: 10);
      expect(emittedEvents.last.x, closeTo(0.0, 0.001));
      expect(emittedEvents.last.y, closeTo(0.0, 0.001));
      drawing.onPointerUp(pointerId: 10);

      // Top-Right Corner (1080, 0)
      drawing.onPointerDown(const Offset(1080.0, 0.0), pointerId: 11);
      expect(emittedEvents.last.x, closeTo(1.0, 0.001));
      expect(emittedEvents.last.y, closeTo(0.0, 0.001));
      drawing.onPointerUp(pointerId: 11);

      // Bottom-Left Corner (0, 2400)
      drawing.onPointerDown(const Offset(0.0, 2400.0), pointerId: 12);
      expect(emittedEvents.last.x, closeTo(0.0, 0.001));
      expect(emittedEvents.last.y, closeTo(1.0, 0.001));
      drawing.onPointerUp(pointerId: 12);

      // Bottom-Right Corner (1080, 2400)
      drawing.onPointerDown(const Offset(1080.0, 2400.0), pointerId: 13);
      expect(emittedEvents.last.x, closeTo(1.0, 0.001));
      expect(emittedEvents.last.y, closeTo(1.0, 0.001));
      drawing.onPointerUp(pointerId: 13);
    });

    test('CHECKPOINT F: Continuous fast strokes without gaps or dropped points', () {
      drawing.onPointerDown(const Offset(100.0, 100.0), pointerId: 20);
      expect(drawing.isDrawing, isTrue);
      expect(drawing.penState, equals(PenState.down));

      // Fast stroke: 50 rapid moves
      for (int i = 1; i <= 50; i++) {
        drawing.onPointerMove(Offset(100.0 + i * 5.0, 100.0 + i * 8.0), pointerId: 20);
      }

      expect(drawing.penState, equals(PenState.moving));
      // 1 down + 50 moves = 51 events
      expect(emittedEvents.length, equals(51));
      expect(emittedEvents.where((e) => e.type == InputEventType.pointerMove).length, equals(50));

      drawing.onPointerUp(pointerId: 20);
      expect(emittedEvents.length, equals(52));
      expect(emittedEvents.last.type, equals(InputEventType.pointerUp));
      expect(drawing.isDrawing, isFalse);
      expect(drawing.penState, equals(PenState.idle));
    });

    test('CHECKPOINT G: PointerUp and Cancel always release state', () {
      // Normal up
      drawing.onPointerDown(const Offset(200.0, 200.0), pointerId: 30);
      expect(drawing.isDrawing, isTrue);
      drawing.onPointerUp(pointerId: 30);
      expect(drawing.isDrawing, isFalse);
      expect(drawing.penState, equals(PenState.idle));

      // Cancel
      drawing.onPointerDown(const Offset(300.0, 300.0), pointerId: 31);
      expect(drawing.isDrawing, isTrue);
      drawing.onPointerCancel(pointerId: 31);
      expect(drawing.isDrawing, isFalse);
      expect(drawing.penState, equals(PenState.idle));
    });

    test('CHECKPOINT H: Disconnect/Reconnect reset session cleanly', () {
      // Simulate stroke interrupted by disconnect
      drawing.onPointerDown(const Offset(400.0, 400.0), pointerId: 40);
      drawing.onPointerMove(const Offset(410.0, 410.0), pointerId: 40);
      expect(drawing.isDrawing, isTrue);

      // Disconnect occurs: invoke resetDrawingSession
      drawing.resetDrawingSession();
      expect(drawing.isDrawing, isFalse);
      expect(drawing.penState, equals(PenState.idle));
      expect(drawing.activePointerCount, equals(0));

      // Next stroke after reconnect works immediately
      emittedEvents.clear();
      drawing.onPointerDown(const Offset(500.0, 500.0), pointerId: 41);
      expect(drawing.isDrawing, isTrue);
      expect(emittedEvents.length, equals(1));
      expect(emittedEvents.first.type, equals(InputEventType.pointerDown));
      drawing.onPointerUp(pointerId: 41);
      expect(drawing.isDrawing, isFalse);
    });

    test('CHECKPOINT I: Drawing options (WritingScale, PrecisionMode, BrushSettings) propagate', () {
      // Test Writing Scale presets
      drawing.setWritingScalePreset(WritingScalePreset.compact);
      expect(drawing.writingScale, equals(0.50));
      expect(drawing.currentScalePreset, equals(WritingScalePreset.compact));

      drawing.setWritingScalePreset(WritingScalePreset.medium);
      expect(drawing.writingScale, equals(0.75));
      expect(drawing.currentScalePreset, equals(WritingScalePreset.medium));

      drawing.setWritingScalePreset(WritingScalePreset.full);
      expect(drawing.writingScale, equals(1.0));
      expect(drawing.currentScalePreset, equals(WritingScalePreset.full));

      // Test Precision Mode
      drawing.precisionMode = PrecisionMode.rawDirect;
      expect(drawing.precisionMode, equals(PrecisionMode.rawDirect));

      drawing.precisionMode = PrecisionMode.proAdaptive;
      expect(drawing.precisionMode, equals(PrecisionMode.proAdaptive));

      // Test Brush Settings
      final newBrush = drawing.brushSettings.copyWith(
        color: const Color(0xFFFF5252),
        baseWidth: 7.5,
        mode: BrushMode.eraser,
      );
      drawing.updateBrush(newBrush);
      expect(drawing.brushSettings.color, equals(const Color(0xFFFF5252)));
      expect(drawing.brushSettings.baseWidth, equals(7.5));
      expect(drawing.brushSettings.mode, equals(BrushMode.eraser));
    });

    test('CHECKPOINT C & D: Live Socket transmission against running AirCanvas.exe', () async {
      final connection = ConnectionProvider();
      final connected = await connection.connectToServer(
        '127.0.0.1',
        port: 9090,
        pin: '1234',
        onPinRequired: () async => '1234',
      );
      expect(connected, isTrue, reason: 'Must connect to running AirCanvas.exe on port 9090');

      drawing.onInputGenerated = (event) {
        connection.sendInputEvent(event);
      };

      // Send brush update
      connection.sendBrushUpdate(tool: 'pen', colorHex: '#ff5252', strokeWidth: 5.0);

      // Transmit Far-Left point (0.0)
      drawing.onPointerDown(const Offset(0.0, 1000.0), pointerId: 50);
      await Future.delayed(const Duration(milliseconds: 30));
      drawing.onPointerUp(pointerId: 50);

      // Transmit Center point (0.50)
      drawing.onPointerDown(const Offset(540.0, 1000.0), pointerId: 51);
      await Future.delayed(const Duration(milliseconds: 30));
      drawing.onPointerUp(pointerId: 51);

      // Transmit Far-Right point (1.0)
      drawing.onPointerDown(const Offset(1080.0, 1000.0), pointerId: 52);
      await Future.delayed(const Duration(milliseconds: 30));
      drawing.onPointerUp(pointerId: 52);

      await Future.delayed(const Duration(milliseconds: 100));
      await connection.disconnect();
    });
  });
}
