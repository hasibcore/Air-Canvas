// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:air_canvas/models/input_event.dart';
import 'package:air_canvas/services/connection_provider.dart';
import 'package:air_canvas/services/drawing_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('Full Phone Touch Pipeline: Screen -> Provider -> Wire', () async {
    final connection = ConnectionProvider();
    final drawing = DrawingProvider();

    // 1. Set mobile canvas dimensions
    const mobileWidth = 1080.0;
    const mobileHeight = 2400.0;
    drawing.updateCanvasSize(mobileWidth, mobileHeight);
    drawing.updateServerAspectRatio(1920.0 / 1080.0);

    // 2. Connect to PC server (AirCanvas.exe running on 9090)
    print('Connecting to PC server at 127.0.0.1:9090...');
    final connected = await connection.connectToServer(
      '127.0.0.1',
      port: 9090,
      pin: '1234',
      onPinRequired: () async => '1234',
    );

    expect(connected, isTrue, reason: 'Must connect to server');
    print('✅ Connected to PC Server!');

    final generatedEvents = <InputEvent>[];
    drawing.onInputGenerated = (event) {
      generatedEvents.add(event);
      connection.sendInputEvent(event);
    };

    await Future.delayed(const Duration(milliseconds: 100));

    // STROKE 1: Tap with Finger (pointerId = 0)
    print('\n--- TEST 1: Single Phone Touch Tap (Finger, pointerId=0) ---');
    generatedEvents.clear();
    drawing.onPointerDown(
      const Offset(500, 1000),
      pressure: 0.5,
      pointerType: PointerType.finger,
      pointerId: 0,
    );

    expect(drawing.penState, equals(PenState.down));
    expect(drawing.isDrawing, isTrue);
    expect(generatedEvents.length, equals(1));
    expect(generatedEvents[0].type, equals(InputEventType.pointerDown));
    expect(generatedEvents[0].pointerType, equals(PointerType.finger));
    print('✅ Down event created and sent: norm=(${generatedEvents[0].x}, ${generatedEvents[0].y})');

    drawing.onPointerUp(
      pointerType: PointerType.finger,
      pointerId: 0,
    );

    expect(drawing.penState, equals(PenState.idle));
    expect(drawing.isDrawing, isFalse);
    expect(generatedEvents.length, equals(2));
    expect(generatedEvents[1].type, equals(InputEventType.pointerUp));
    print('✅ Up event created and sent');

    // STROKE 2: Continuous Stroke with Moves (Finger, pointerId = 1)
    print('\n--- TEST 2: Continuous Stroke with 10 Moves (Finger, pointerId=1) ---');
    generatedEvents.clear();
    const pId1 = 1;
    drawing.onPointerDown(
      const Offset(300, 600),
      pressure: 0.5,
      pointerType: PointerType.finger,
      pointerId: pId1,
    );
    expect(drawing.penState, equals(PenState.down));
    expect(generatedEvents.length, equals(1));

    for (int step = 1; step <= 10; step++) {
      drawing.onPointerMove(
        Offset(300.0 + step * 20.0, 600.0 + step * 15.0),
        pressure: 0.6,
        pointerType: PointerType.finger,
        pointerId: pId1,
      );
    }
    expect(drawing.penState, equals(PenState.moving));
    expect(generatedEvents.length, equals(11)); // 1 down + 10 moves
    print('✅ 10 move events generated continuously: count=${generatedEvents.length}');

    drawing.onPointerUp(
      pointerType: PointerType.finger,
      pointerId: pId1,
    );
    expect(drawing.penState, equals(PenState.idle));
    expect(generatedEvents.length, equals(12)); // 1 down + 10 moves + 1 up
    expect(generatedEvents.last.type, equals(InputEventType.pointerUp));
    print('✅ Stroke ended cleanly with pointerUp');

    // STROKE 3: Next Stroke (Finger, pointerId = 2)
    print('\n--- TEST 3: Stroke 3 (Finger, pointerId=2) ---');
    generatedEvents.clear();
    const pId2 = 2;
    drawing.onPointerDown(
      const Offset(200, 300),
      pressure: 0.5,
      pointerType: PointerType.finger,
      pointerId: pId2,
    );
    expect(drawing.penState, equals(PenState.down));
    expect(generatedEvents.length, equals(1));

    for (int step = 1; step <= 5; step++) {
      drawing.onPointerMove(
        Offset(200.0 + step * 10.0, 300.0 + step * 10.0),
        pressure: 0.5,
        pointerType: PointerType.finger,
        pointerId: pId2,
      );
    }
    expect(generatedEvents.length, equals(6));

    drawing.onPointerUp(
      pointerType: PointerType.finger,
      pointerId: pId2,
    );
    expect(drawing.penState, equals(PenState.idle));
    expect(generatedEvents.length, equals(7));
    print('✅ Stroke 3 completed successfully');

    await Future.delayed(const Duration(milliseconds: 200));
    await connection.disconnect();
    print('\n🎉 Full Phone Touch Pipeline Succeeded!');
  });
}
