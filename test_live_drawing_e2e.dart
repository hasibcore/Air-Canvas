import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:air_canvas/models/input_event.dart';

List<int> crypt(List<int> data, List<int> key) {
  final result = List<int>.filled(data.length, 0);
  for (int i = 0; i < data.length; i++) {
    result[i] = data[i] ^ key[i % key.length];
  }
  return result;
}

void main() async {
  print('====================================================');
  print('  AirCanvas Live End-to-End Drawing Simulator');
  print('====================================================');

  const serverUrl = 'ws://127.0.0.1:9090';
  const pin = '1234';

  print('Connecting to $serverUrl ...');
  final socket = await WebSocket.connect(serverUrl);
  print('✅ WebSocket Connected!');

  List<int>? encryptionKey;
  bool authenticated = false;
  bool configReceived = false;
  ServerConfig? serverConfig;

  final authCompleter = Completer<bool>();

  socket.listen(
    (dynamic data) {
      try {
        dynamic decryptedData = data;
        if (encryptionKey != null && data is List<int>) {
          decryptedData = crypt(data, encryptionKey!);
        }

        String? text;
        if (decryptedData is String) {
          text = decryptedData;
        } else if (decryptedData is List<int>) {
          text = utf8.decode(decryptedData);
        }

        if (text != null) {
          print('[Server -> Client] $text');
          final json = jsonDecode(text) as Map<String, dynamic>;
          final type = json['type'] as String?;

          if (type == 'auth_challenge') {
            print('Sending auth_response with PIN: $pin');
            socket.add(jsonEncode({'type': 'auth_response', 'pin': pin}));
            encryptionKey = utf8.encode(pin);
          } else if (type == 'auth_success') {
            authenticated = true;
            if (json.containsKey('session_key')) {
              encryptionKey = base64Decode(json['session_key'] as String);
              print('Session key received and applied! (${encryptionKey!.length} bytes)');
            } else {
              encryptionKey = utf8.encode(pin);
            }

            // Send device_info
            final deviceInfo = {
              'type': 'device_info',
              'data': {
                'deviceName': 'Simulated Samsung Galaxy Tab S9 Ultra',
                'deviceModel': 'SM-X910',
                'platform': 'android',
                'screenWidth': 2960.0,
                'screenHeight': 1848.0,
                'hasStylusSupport': true,
                'maxPressure': 4096.0,
              }
            };
            print('Sending encrypted device_info...');
            final raw = utf8.encode(jsonEncode(deviceInfo));
            socket.add(crypt(raw, encryptionKey!));
            authCompleter.complete(true);
          } else if (type == 'server_config') {
            configReceived = true;
            serverConfig = ServerConfig.fromJson(json['data'] as Map<String, dynamic>);
            print('Server Config Received: binary=${serverConfig?.useBinaryProtocol}, port=${serverConfig?.port}');
          }
        }
      } catch (e) {
        print('Message parse error: $e');
      }
    },
    onError: (e) => print('Socket error: $e'),
    onDone: () => print('Socket disconnected'),
  );

  final authOk = await authCompleter.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => false,
  );

  if (!authOk) {
    print('Authentication failed or timed out!');
    exit(1);
  }

  // Wait a moment for server_config
  await Future.delayed(const Duration(milliseconds: 300));

  print('\n----------------------------------------------------');
  print('  Starting Real-Time Drawing Stroke Generation');
  print('----------------------------------------------------');

  void sendStrokePoint(InputEvent event) {
    final List<int> raw;
    if (serverConfig?.useBinaryProtocol ?? true) {
      raw = event.toBinary();
    } else {
      raw = utf8.encode(jsonEncode({'type': 'input', 'data': event.toJson()}));
    }

    if (encryptionKey != null) {
      socket.add(crypt(raw, encryptionKey!));
    } else {
      socket.add(raw);
    }
  }

  // Stroke 1: Draw a 5-pointed Star in the Center
  print('Drawing Star Shape...');
  final starPoints = <Point<double>>[];
  const numPoints = 5;
  const outerR = 0.25;
  const innerR = 0.10;
  const cx = 0.5;
  const cy = 0.45;

  for (int i = 0; i <= numPoints * 2; i++) {
    final angle = i * pi / numPoints - pi / 2;
    final r = (i % 2 == 0) ? outerR : innerR;
    starPoints.add(Point(cx + r * cos(angle), cy + r * sin(angle)));
  }

  // Pointer Down
  sendStrokePoint(InputEvent(
    type: InputEventType.pointerDown,
    x: starPoints[0].x,
    y: starPoints[0].y,
    pressure: 0.8,
    pointerType: PointerType.stylus,
  ));
  await Future.delayed(const Duration(milliseconds: 16));

  // Pointer Moves
  for (int i = 1; i < starPoints.length; i++) {
    final p0 = starPoints[i - 1];
    final p1 = starPoints[i];
    const steps = 15;
    for (int step = 1; step <= steps; step++) {
      final t = step / steps;
      final x = p0.x + (p1.x - p0.x) * t;
      final y = p0.y + (p1.y - p0.y) * t;
      final pressure = 0.4 + 0.5 * sin(t * pi);
      sendStrokePoint(InputEvent(
        type: InputEventType.pointerMove,
        x: x,
        y: y,
        pressure: pressure,
        pointerType: PointerType.stylus,
      ));
      await Future.delayed(const Duration(milliseconds: 12));
    }
  }

  // Pointer Up
  sendStrokePoint(InputEvent(
    type: InputEventType.pointerUp,
    x: starPoints.last.x,
    y: starPoints.last.y,
    pressure: 0.0,
    pointerType: PointerType.stylus,
  ));
  await Future.delayed(const Duration(milliseconds: 200));

  // Stroke 2: Draw a Spiral
  print('Drawing Spiral Shape...');
  const spiralCenterX = 0.5;
  const spiralCenterY = 0.45;
  const totalTurns = 3;
  const maxSpiralR = 0.35;
  const spiralSteps = 120;

  sendStrokePoint(InputEvent(
    type: InputEventType.pointerDown,
    x: spiralCenterX,
    y: spiralCenterY,
    pressure: 0.3,
    pointerType: PointerType.stylus,
  ));

  for (int i = 1; i <= spiralSteps; i++) {
    final t = i / spiralSteps;
    final angle = t * totalTurns * 2 * pi;
    final r = t * maxSpiralR;
    final x = spiralCenterX + r * cos(angle);
    final y = spiralCenterY + r * sin(angle);
    final pressure = 0.3 + 0.6 * t;

    sendStrokePoint(InputEvent(
      type: InputEventType.pointerMove,
      x: x,
      y: y,
      pressure: pressure,
      pointerType: PointerType.stylus,
    ));
    await Future.delayed(const Duration(milliseconds: 10));
  }

  sendStrokePoint(InputEvent(
    type: InputEventType.pointerUp,
    x: spiralCenterX + maxSpiralR * cos(totalTurns * 2 * pi),
    y: spiralCenterY + maxSpiralR * sin(totalTurns * 2 * pi),
    pressure: 0.0,
    pointerType: PointerType.stylus,
  ));

  print('Drawing Complete! 250+ packets successfully transmitted.');
  await Future.delayed(const Duration(seconds: 1));
  await socket.close();
  print('Test Finished Successfully!');
  exit(0);
}
