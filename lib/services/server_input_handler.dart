// Server-side input receiver service
//
// সার্ভার (PC) তে ইনপুট ইভেন্ট রিসিভ করে প্রসেস করে:
// 1. Windows: Native API তে ইনজেক্ট করে (বাস্তব ট্যাবলেট ইনপুট)
// 2. Debug mode: লোকাল ক্যানভাসে ভিজুয়ালাইজ করে

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/input_event.dart';
import '../services/connection_provider.dart';
import 'windows_input_injection.dart';

class ServerInputHandler {
  final ConnectionProvider _connection;
  bool _nativeInjectionAvailable = false;

  // Bug 132: Track initialization completion
  Completer<bool>? _initCompleter;
  bool get isNativeReady => _nativeInjectionAvailable;

  // Bug 134: Ring buffer via Queue instead of List (O(1) remove from front)
  final Queue<InputEvent> _recentEvents = Queue<InputEvent>();
  static const int _maxRecentEvents = 100;

  // Callbacks for UI updates
  void Function(InputEvent)? onEventReceived;

  // Bug 135: Track disposed state
  bool _isDisposed = false;

  ServerInputHandler(this._connection) {
    _setupCallbacks();
    _initializeNativeInjection();
  }

  void _setupCallbacks() {
    _connection.onInputEventReceived = _handleInputEvent;
    _connection.onClientConnected = _onClientConnected;
    _connection.onClientDisconnected = _onClientDisconnected;
  }

  /// Bug 132: Initialization with Completer so callers can await readiness
  Future<bool> _initializeNativeInjection() async {
    if (_initCompleter != null) return _initCompleter!.future;
    _initCompleter = Completer<bool>();

    if (!kIsWeb && Platform.isWindows) {
      try {
        _nativeInjectionAvailable = await WindowsInputInjection.initialize();
        if (_nativeInjectionAvailable) {
          debugPrint('[InputHandler] Windows native injection সক্রিয়');
        } else {
          debugPrint('[InputHandler] Native injection পাওয়া যায়নি, debug mode ব্যবহার হবে');
        }
      } catch (e, stackTrace) {
        debugPrint('[InputHandler] Native init error: $e\n$stackTrace');
        _nativeInjectionAvailable = false;
      }
    }

    _initCompleter!.complete(_nativeInjectionAvailable);
    return _nativeInjectionAvailable;
  }

  /// Wait for initialization to finish (useful for callers that need to
  /// ensure native injection is ready before sending events). (Bug 132)
  Future<bool> ensureInitialized() {
    return _initCompleter?.future ?? Future.value(false);
  }

  void _onClientConnected() {
    // Note: ক্লায়েন্টের ইনপুট ইভেন্টগুলো (event.x, event.y) ইতিমধ্যেই 0.0 থেকে 1.0 এর মধ্যে
    // নরমালাইজড থাকে। Windows native injection স্বয়ংক্রিয়ভাবে সেটিকে ল্যাপটপের আসল
    // মনিটর রেজোলিউশনে (monitor_width, monitor_height) ম্যাপ করে।
    // এখানে ক্লায়েন্টের মোবাইল স্ক্রিন সাইজ ইনজেক্ট করলে ল্যাপটপে কার্সর বাম কোণে আটকে যেত
    // এবং শেপ বিকৃত হয়ে যেত, তাই এটি আর সেট করা হচ্ছে না।
  }

  void _onClientDisconnected() {
    _recentEvents.clear();
  }

  void _handleInputEvent(InputEvent event) {
    if (_isDisposed) return;

    // Bug 134: Ring buffer via Queue — O(1) removeFirst
    _recentEvents.add(event);
    while (_recentEvents.length > _maxRecentEvents) {
      _recentEvents.removeFirst();
    }

    // UI callback (debug canvas)
    try {
      onEventReceived?.call(event);
    } catch (e, stackTrace) {
      debugPrint('[InputHandler] onEventReceived callback error: $e\n$stackTrace');
    }

    // Native injection (Windows only)
    // Bug 131: Properly handle the Future with unawaited + error zone
    if (_nativeInjectionAvailable && !kIsWeb && Platform.isWindows) {
      unawaited(
        WindowsInputInjection.injectEvent(event).then((success) {
          if (!success && kDebugMode) {
            debugPrint('[InputHandler] Injection failed for event: ${event.type.name}');
          }
        }).catchError((Object e, StackTrace stackTrace) {
          debugPrint('[InputHandler] Injection exception: $e\n$stackTrace');
        }),
      );
    }
  }

  // Bug 134: Return unmodifiable List from Queue
  List<InputEvent> get recentEvents => List.unmodifiable(_recentEvents);

  // Bug 135: Properly await dispose and guard against double-dispose
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    // Clear callbacks
    _connection.onInputEventReceived = null;
    _connection.onClientConnected = null;
    _connection.onClientDisconnected = null;
    onEventReceived = null;

    _recentEvents.clear();

    if (!kIsWeb && Platform.isWindows && _nativeInjectionAvailable) {
      await WindowsInputInjection.dispose();
    }
  }
}