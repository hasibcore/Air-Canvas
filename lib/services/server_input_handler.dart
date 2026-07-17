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

  // AC-025 & AC-026: Pending events during initialization
  final List<InputEvent> _pendingInitEvents = [];
  static const int _maxPendingInitEvents = 50;

  // AC-027: Injection backpressure tracking
  int _inFlightInjections = 0;
  static const int _maxInFlightInjections = 10;

  // AC-028: Rate-limited error logging
  DateTime? _lastLogTime;
  static const Duration _logRateLimit = Duration(seconds: 1);

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

    if (Platform.isWindows) {
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

    // AC-026: Flush pending init events if native injection is ready
    if (_nativeInjectionAvailable && _pendingInitEvents.isNotEmpty) {
      final eventsToFlush = List<InputEvent>.from(_pendingInitEvents);
      _pendingInitEvents.clear();
      for (final event in eventsToFlush) {
        _injectNativeEvent(event);
      }
    } else {
      _pendingInitEvents.clear();
    }

    return _nativeInjectionAvailable;
  }

  /// Wait for initialization to finish (useful for callers that need to
  /// ensure native injection is ready before sending events). (Bug 132)
  Future<bool> ensureInitialized() {
    return _initCompleter?.future ?? Future.value(false);
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
    _pendingInitEvents.clear();
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

    // AC-025 & AC-026: If init is still in progress, queue event
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      if (_pendingInitEvents.length < _maxPendingInitEvents) {
        _pendingInitEvents.add(event);
      }
      return;
    }

    // Native injection (Windows only)
    if (_nativeInjectionAvailable && Platform.isWindows) {
      _injectNativeEvent(event);
    }
  }

  // AC-027 & AC-028: Inject event with backpressure check and rate-limited logging
  void _injectNativeEvent(InputEvent event) {
    if (_inFlightInjections >= _maxInFlightInjections) {
      // Drop excess move events under high backpressure
      if (event.type == InputEventType.pointerMove) {
        return;
      }
    }

    _inFlightInjections++;
    unawaited(
      WindowsInputInjection.injectEvent(event).then((success) {
        if (!success && kDebugMode) {
          _logRateLimited('[InputHandler] Injection failed for event: ${event.type.name}');
        }
      }).catchError((Object e, StackTrace stackTrace) {
        _logRateLimited('[InputHandler] Injection exception: $e\n$stackTrace');
      }).whenComplete(() {
        _inFlightInjections = (_inFlightInjections - 1).clamp(0, 100);
      }),
    );
  }

  void _logRateLimited(String message) {
    final now = DateTime.now();
    if (_lastLogTime == null || now.difference(_lastLogTime!) >= _logRateLimit) {
      _lastLogTime = now;
      debugPrint(message);
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
    _pendingInitEvents.clear();

    if (Platform.isWindows && _nativeInjectionAvailable) {
      await WindowsInputInjection.dispose();
    }
  }
}