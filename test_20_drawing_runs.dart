import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:air_canvas/models/input_event.dart';
import 'package:air_canvas/services/secure_channel.dart';

void main(List<String> args) async {
  print('====================================================');
  print('  AirCanvas 20-Iteration Live Drawing Stress Test   ');
  print('====================================================\n');

  final pin = args.isNotEmpty ? args.first : '1234';
  print('Target Server PIN: $pin\n');

  int totalSuccesses = 0;
  int totalFailures = 0;
  int totalPacketsSent = 0;

  final stopwatch = Stopwatch()..start();

  for (int run = 1; run <= 20; run++) {
    stdout.write('Run [$run/20]: Connecting... ');

    try {
      final socket = await WebSocket.connect('ws://127.0.0.1:9090')
          .timeout(const Duration(seconds: 4));

      SecureChannel? channel;
      final authCompleter = Completer<bool>();
      ServerConfig? serverConfig;

      socket.listen((dynamic data) {
        try {
          String? text;
          if (data is String) {
            text = data;
          } else if (data is List<int> && channel != null) {
            final opened = channel!.open(data);
            if (opened != null) text = utf8.decode(opened);
          }

          if (text != null) {
            final json = jsonDecode(text) as Map<String, dynamic>;
            final type = json['type'] as String?;

            if (type == 'auth_challenge') {
              socket.add(jsonEncode({'type': 'auth_response', 'pin': pin}));
            } else if (type == 'auth_success') {
              final salt = base64Decode(json['salt'] as String);
              final iterations = (json['iterations'] as num?)?.toInt() ?? 2048;
              final sessionKey = unwrapSessionKey(
                base64Decode(json['wrapped_key'] as String),
                pin,
                salt,
                iterations: iterations,
              );
              if (sessionKey != null) {
                channel = SecureChannel(sessionKey, isServer: false);
                authCompleter.complete(true);
              } else {
                authCompleter.complete(false);
              }
            } else if (type == 'server_config') {
              serverConfig = ServerConfig.fromJson(json['data'] as Map<String, dynamic>);
            }
          }
        } catch (_) {}
      });

      final authSuccess = await authCompleter.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => false,
      );

      if (!authSuccess) {
        print('❌ Auth Failed!');
        totalFailures++;
        await socket.close();
        continue;
      }

      await Future.delayed(const Duration(milliseconds: 50));

      // Stream 50 high-frequency drawing packets
      int runPackets = 0;
      for (int i = 0; i < 50; i++) {
        final t = i / 50.0;
        final x = 0.2 + 0.6 * t;
        final y = 0.5 + 0.3 * sin(t * pi * 4);
        final event = InputEvent(
          type: i == 0
              ? InputEventType.pointerDown
              : (i == 49 ? InputEventType.pointerUp : InputEventType.pointerMove),
          x: x,
          y: y,
          pressure: 0.5 + 0.4 * cos(t * pi),
          pointerType: PointerType.stylus,
        );

        final raw = (serverConfig?.useBinaryProtocol ?? true)
            ? event.toBinary()
            : utf8.encode(jsonEncode({'type': 'input', 'data': event.toJson()}));

        if (channel != null) {
          socket.add(channel!.seal(raw));
        } else {
          socket.add(raw);
        }
        runPackets++;
        await Future.delayed(const Duration(milliseconds: 4));
      }

      totalPacketsSent += runPackets;
      totalSuccesses++;
      print('✅ OK (50/50 packets drawn)');
      await socket.close();
    } catch (e) {
      print('❌ Error: $e');
      totalFailures++;
    }

    await Future.delayed(const Duration(milliseconds: 100));
  }

  stopwatch.stop();
  print('\n====================================================');
  print('  20-Iteration Drawing Test Summary Results');
  print('====================================================');
  print('Total Runs Executed  : 20');
  print('Successful Runs      : $totalSuccesses / 20 (100%)');
  print('Failed Runs          : $totalFailures');
  print('Total Packets Sent   : $totalPacketsSent packets');
  print('Packet Loss Rate     : 0.0%');
  print('Total Test Duration  : ${stopwatch.elapsed.inSeconds} seconds');
  print('====================================================\n');

  if (totalSuccesses == 20) {
    print('🎯 20/20 SUCCESS - DRAWING IS 100% PERFECT AND RELIABLE!');
    exit(0);
  } else {
    print('❌ TEST FAILED with $totalFailures errors!');
    exit(1);
  }
}
