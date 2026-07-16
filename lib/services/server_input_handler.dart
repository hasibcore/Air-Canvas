// Server-side input receiver service
//
// সার্ভার (PC) তে ইনপুট ইভেন্ট রিসিভ করে প্রসেস করে:
// 1. Windows: Native API তে ইনজেক্ট করে (বাস্তব ট্যাবলেট ইনপুট)
// 2. Debug mode: লোকাল ক্যানভাসে ভিজুয়ালাইজ করে

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/input_event.dart';
import '../services/connection_provider.dart';
import 'windows_input_injection.dart';

class ServerInputHandler {
  final ConnectionProvider _connection;
  bool _nativeInjectionAvailable = false;
  final List<InputEvent> _recentEvents = [];
  static const int _maxRecentEvents = 100;

  // Callbacks for UI updates
  void Function(InputEvent)? onEventReceived;

  ServerInputHandler(this._connection) {
    _setupCallbacks();
    _initializeNativeInjection();
  }

  void _setupCallbacks() {
    _connection.onInputEventReceived = _handleInputEvent;
    _connection.onClientConnected = _onClientConnected;
    _connection.onClientDisconnected = _onClientDisconnected;
  }

  Future<void> _initializeNativeInjection() async {
    if (Platform.isWindows) {
      _nativeInjectionAvailable = await WindowsInputInjection.initialize();
      if (_nativeInjectionAvailable) {
        debugPrint('[InputHandler] Windows native injection সক্রিয়');
      } else {
        debugPrint('[InputHandler] Native injection পাওয়া যায়নি, debug mode ব্যবহার হবে');
      }
    }
  }

  void _onClientConnected() {
    final deviceInfo = _connection.remoteDeviceInfo;
    if (deviceInfo != null) {
      // ক্লায়েন্ট স্ক্রিন রেজুলেশন অনুযায়ী Windows স্ক্রিন ম্যাপিং সেট করা
      if (Platform.isWindows && _nativeInjectionAvailable) {
        WindowsInputInjection.setScreenResolution(
          deviceInfo.screenWidth.toInt(),
          deviceInfo.screenHeight.toInt(),
        );
      }
    }
  }

  void _onClientDisconnected() {
    _recentEvents.clear();
  }

  void _handleInputEvent(InputEvent event) {
    // ইভেন্ট লগ/বাফার
    _recentEvents.add(event);
    if (_recentEvents.length > _maxRecentEvents) {
      _recentEvents.removeAt(0);
    }

    // UI callback (debug canvas)
    onEventReceived?.call(event);

    // Native injection (Windows only)
    if (_nativeInjectionAvailable && Platform.isWindows) {
      WindowsInputInjection.injectEvent(event);
    }
  }

  List<InputEvent> get recentEvents => List.unmodifiable(_recentEvents);

  void dispose() {
    if (Platform.isWindows) {
      WindowsInputInjection.dispose();
    }
  }
}