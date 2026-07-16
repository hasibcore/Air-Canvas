import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:superdisplay_clone/main.dart';
import 'package:superdisplay_clone/services/connection_provider.dart';
import 'package:superdisplay_clone/services/drawing_provider.dart';

void main() {
  testWidgets('App renders HomeScreen without crash', (WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ConnectionProvider()),
          ChangeNotifierProvider(create: (_) => DrawingProvider()),
        ],
        child: const SuperDisplayApp(),
      ),
    );
    await tester.pumpAndSettle();
    // হোম স্ক্রিনে টাইটেল থাকা উচিত
    expect(find.text('SuperDisplay Clone'), findsOneWidget);
    // Server ও Client tab থাকা উচিত
    expect(find.text('SERVER (PC)'), findsOneWidget);
    expect(find.text('CLIENT (Mobile)'), findsOneWidget);
    // Start Server button থাকা উচিত
    expect(find.text('Start Server'), findsOneWidget);
  });
}