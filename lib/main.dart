import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'services/connection_provider.dart';
import 'services/drawing_provider.dart';
import 'screens/home_screen.dart';
import 'screens/drawing_screen.dart';

import 'services/server_input_handler.dart';

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    
    // Global Flutter error handler
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      debugPrint('[Global Error] ${details.exceptionAsString()}');
    };

    final connection = ConnectionProvider();
    // Instantiate ServerInputHandler so it registers its listeners to ConnectionProvider
    ServerInputHandler(connection);

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ConnectionProvider>.value(value: connection),
          ChangeNotifierProvider(create: (_) => DrawingProvider()),
        ],
        child: const AirCanvasApp(),
      ),
    );
  }, (Object error, StackTrace stackTrace) {
    debugPrint('[Async Error] Unhandled async error: $error\n$stackTrace');
  });
}

class AirCanvasApp extends StatelessWidget {
  const AirCanvasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Air Canvas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.interTextTheme(
          ThemeData.dark().textTheme,
        ),
      ),
      home: const HomeScreen(),
      routes: {
        '/drawing': (context) => const DrawingScreen(),
      },
      onUnknownRoute: (settings) {
        return MaterialPageRoute(
          builder: (context) => Scaffold(
            body: Center(
              child: Text(
                'Route "${settings.name}" not found.',
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ),
        );
      },
    );
  }
}
