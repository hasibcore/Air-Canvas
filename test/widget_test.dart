import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:air_canvas/main.dart';
import 'package:air_canvas/services/connection_provider.dart';
import 'package:air_canvas/services/drawing_provider.dart';

void main() {
  SharedPreferences.setMockInitialValues({});
  testWidgets('App renders HomeScreen without crash', (WidgetTester tester) async {
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
    // Home screen should display title
    expect(find.text('Air Canvas'), findsOneWidget);
    // Server and Client tabs should be present
    expect(find.text('SERVER (PC)'), findsOneWidget);
    expect(find.text('CLIENT (Mobile)'), findsOneWidget);
    // Switch to Server tab
    await tester.tap(find.text('SERVER (PC)'));
    await tester.pumpAndSettle();
    // Start Server button should be present
    expect(find.text('Start Server'), findsOneWidget);
  });
}