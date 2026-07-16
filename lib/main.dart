import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/connection_provider.dart';
import 'services/drawing_provider.dart';
import 'screens/home_screen.dart';
import 'screens/drawing_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ConnectionProvider()),
        ChangeNotifierProvider(create: (_) => DrawingProvider()),
      ],
      child: const SuperDisplayApp(),
    ),
  );
}

class SuperDisplayApp extends StatelessWidget {
  const SuperDisplayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SuperDisplay Clone',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Inter',
      ),
      home: const HomeScreen(),
      routes: {
        '/drawing': (context) => const DrawingScreen(),
      },
    );
  }
}