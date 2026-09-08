// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:air_canvas/models/input_event.dart';
import 'package:air_canvas/screens/drawing_screen.dart';
import 'package:air_canvas/services/connection_provider.dart';
import 'package:air_canvas/services/drawing_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  testWidgets('DrawingScreen receives real touch gestures and emits events', (WidgetTester tester) async {
    final connection = ConnectionProvider();
    final drawing = DrawingProvider();

    final emittedEvents = <InputEvent>[];

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ConnectionProvider>.value(value: connection),
          ChangeNotifierProvider<DrawingProvider>.value(value: drawing),
        ],
        child: const MaterialApp(
          home: DrawingScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    // Verify callback was registered
    expect(drawing.onInputGenerated, isNotNull);

    // Override or intercept onInputGenerated to verify emissions
    final originalCallback = drawing.onInputGenerated;
    drawing.onInputGenerated = (event) {
      emittedEvents.add(event);
      originalCallback?.call(event);
    };

    // Perform gesture at center of DrawingScreen
    final center = tester.getCenter(find.byType(DrawingScreen));
    print('DrawingScreen center: $center');

    final gesture = await tester.startGesture(center, pointer: 1);
    await tester.pump();

    print('Emitted events after startGesture: ${emittedEvents.length}');
    print('drawing.isDrawing: ${drawing.isDrawing}, penState: ${drawing.penState}');

    expect(drawing.isDrawing, isTrue, reason: 'Drawing should be active after startGesture');
    expect(emittedEvents.isNotEmpty, isTrue, reason: 'Should have emitted pointerDown');
    expect(emittedEvents.first.type, equals(InputEventType.pointerDown));

    // Move
    for (int i = 1; i <= 5; i++) {
      await gesture.moveTo(center + Offset(i * 10.0, i * 10.0));
      await tester.pump();
    }

    print('Emitted events after moves: ${emittedEvents.length}');
    expect(emittedEvents.length, equals(6), reason: '1 down + 5 moves');

    // Up
    await gesture.up();
    await tester.pump();

    print('Emitted events after up: ${emittedEvents.length}');
    print('drawing.isDrawing: ${drawing.isDrawing}, penState: ${drawing.penState}');
    expect(drawing.isDrawing, isFalse);
    expect(drawing.penState, equals(PenState.idle));
    expect(emittedEvents.length, equals(7), reason: '1 down + 5 moves + 1 up');
    expect(emittedEvents.last.type, equals(InputEventType.pointerUp));

    print('✅ DrawingScreen widget test passed!');
  });
}
