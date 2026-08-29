// ignore_for_file: avoid_print, unused_local_variable
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:air_canvas/models/input_event.dart';
import 'package:air_canvas/services/secure_channel.dart';

// পুরনো XOR `crypt()` সরিয়ে দেওয়া হয়েছে — সার্ভার এখন কেবল Secure Channel v2
// ফ্রেম নেয় (AES-256-CBC + HMAC-SHA256)। প্লেইন বা XOR প্যাকেট ড্রপ হবে।

void main(List<String> args) async {
  print('====================================================');
  print('  AirCanvas Live End-to-End Drawing Simulator');
  print('====================================================');

  // PIN এখন প্রতিবার সার্ভার স্টার্টে র‍্যান্ডম, তাই hardcode করা যায় না।
  // ব্যবহার: dart run test_live_drawing_e2e.dart <6-digit-pin>
  if (args.isEmpty || (args.first.length != 6 && args.first.length != 4)) {
    print('❌ Usage: dart run test_live_drawing_e2e.dart <4-or-6-digit-pin>');
    print('   সার্ভার উইন্ডোর "🔑 Pairing PIN" থেকে PIN টা নিন, অথবা 1234 ব্যবহার করুন।');
    exit(64);
  }
  final pin = args.first;

  // 1. Test UDP Discovery Broadcast
  print('Testing UDP WiFi Discovery on port 9091...');
  final udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  udpSocket.broadcastEnabled = true;

  final discoveryMsg = jsonEncode({
    'type': 'aircanvas_discovery',
    'version': '1.0',
  });

  final discoveryCompleter = Completer<Map<String, dynamic>>();

  udpSocket.listen((event) {
    if (event == RawSocketEvent.read) {
      final datagram = udpSocket.receive();
      if (datagram != null) {
        final text = utf8.decode(datagram.data);
        print('  [UDP Response Received] $text from ${datagram.address.address}:${datagram.port}');
        try {
          final json = jsonDecode(text) as Map<String, dynamic>;
          if (json['type'] == 'aircanvas_response' && !discoveryCompleter.isCompleted) {
            discoveryCompleter.complete(json);
          }
        } catch (_) {}
      }
    }
  });

  // Send discovery to localhost and broadcast
  udpSocket.send(utf8.encode(discoveryMsg), InternetAddress('127.0.0.1'), 9091);
  udpSocket.send(utf8.encode(discoveryMsg), InternetAddress('255.255.255.255'), 9091);

  final discovered = await discoveryCompleter.future.timeout(
    const Duration(seconds: 3),
    onTimeout: () => {'error': 'timeout'},
  );

  if (discovered.containsKey('name')) {
    print('✅ WiFi Discovery Successful: Device "${discovered['name']}" at ${discovered['ip']}:${discovered['port']}');
  } else {
    print('⚠️ Discovery timed out (Manual IP mode will be tested)');
  }
  udpSocket.close();

  const serverUrl = 'ws://127.0.0.1:9090';

  print('Connecting to $serverUrl ...');
  final socket = await WebSocket.connect(serverUrl);
  print('✅ WebSocket Connected!');

  SecureChannel? channel;
  bool authenticated = false;
  bool configReceived = false;
  ServerConfig? serverConfig;

  final authCompleter = Completer<bool>();

  socket.listen(
    (dynamic data) {
      try {
        String? text;
        if (data is String) {
          // handshake-পর্বের প্লেইনটেক্সট। auth এর পর সার্ভার আর টেক্সট পাঠায় না।
          if (channel != null) {
            print('⚠️ Dropped unsealed text frame after auth');
            return;
          }
          text = data;
        } else if (data is List<int>) {
          if (channel == null) {
            print('⚠️ Dropped binary frame before handshake finished');
            return;
          }
          final opened = channel!.open(data);
          if (opened == null) {
            print('⚠️ Dropped invalid frame (MAC/replay)');
            return;
          }
          text = utf8.decode(opened);
        }

        if (text != null) {
          print('[Server -> Client] $text');
          final json = jsonDecode(text) as Map<String, dynamic>;
          final type = json['type'] as String?;

          if (type == 'auth_challenge') {
            print('Sending auth_response with PIN: $pin');
            socket.add(jsonEncode({'type': 'auth_response', 'pin': pin}));
          } else if (type == 'auth_success') {
            if (json['kx'] != 'v2' ||
                json['salt'] == null ||
                json['wrapped_key'] == null) {
              print('❌ সার্ভারটি পুরনো v1 handshake ব্যবহার করছে — বাতিল।');
              if (!authCompleter.isCompleted) authCompleter.complete(false);
              return;
            }
            final salt = base64Decode(json['salt'] as String);
            final iterations =
                (json['iterations'] as num?)?.toInt() ??
                    SecureChannel.pbkdf2Iterations;
            final sessionKey = unwrapSessionKey(
              base64Decode(json['wrapped_key'] as String),
              pin,
              salt,
              iterations: iterations,
            );
            if (sessionKey == null) {
              print('❌ session key খোলা গেল না (PIN ভুল?)');
              if (!authCompleter.isCompleted) authCompleter.complete(false);
              return;
            }
            authenticated = true;
            channel = SecureChannel(sessionKey, isServer: false);
            print('Session key unwrapped! (${sessionKey.length} bytes, '
                'PBKDF2 iterations=$iterations)');

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
            print('Sending sealed device_info...');
            final raw = utf8.encode(jsonEncode(deviceInfo));
            socket.add(channel!.seal(raw));
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

    // auth এর পর সবকিছুই sealed — channel না থাকলে পাঠানোর মানে নেই।
    final ch = channel;
    if (ch == null) {
      print('⚠️ channel নেই, প্যাকেট পাঠানো হলো না');
      return;
    }
    socket.add(ch.seal(raw));
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
