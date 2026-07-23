import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:air_canvas/main.dart';
import 'package:air_canvas/services/connection_provider.dart';
import 'package:air_canvas/services/drawing_provider.dart';

void main() {
  testWidgets('App renders HomeScreen without crash in desktop mode', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ConnectionProvider()),
          ChangeNotifierProvider(create: (_) => DrawingProvider()),
        ],
        child: const AirCanvasApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Air Canvas'), findsOneWidget);
    expect(find.text('SERVER (PC)'), findsOneWidget);
    expect(find.text('CLIENT (Mobile)'), findsOneWidget);
    expect(find.text('Start Server'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });
}