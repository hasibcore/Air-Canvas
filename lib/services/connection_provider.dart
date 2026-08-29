// কানেকশন স্টেট ম্যানেজার
//
// এই প্রোভাইডার সমগ্র কানেকশন লাইফসাইকেল ম্যানেজ করে:
// 1. WiFi Discovery - UDP Broadcast দিয়ে সার্ভার খোঁজা
// 2. WebSocket Connection - সার্ভারে কানেক্ট করা
// 3. Handshake - ডিভাইস ইনফো ও কনফিগ এক্সচেঞ্জ
// 4. Reconnection - স্বয়ংক্রিয় রিকানেক্ট

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/input_event.dart';
import 'secure_channel.dart';

enum ConnectionMode { server, client }

enum ConnectionState {
  disconnected,
  discovering,
  connecting,
  connected,
  reconnecting,
  error,
}

class DiscoveredDevice {
  final String ip;
  final String name;
  final int port;
  final DateTime discoveredAt;

  DiscoveredDevice({
    required this.ip,
    required this.name,
    required this.port,
    DateTime? discoveredAt,
  }) : discoveredAt = discoveredAt ?? DateTime.now();
}

/// পেয়ারিং PIN-এর দৈর্ঘ্য। C# সার্ভারের GeneratePairingPin() এর সাথে একই মান রাখতে হবে।
/// ৪ থেকে ৬ করা হয়েছে কারণ ৪ ডিজিটে মাত্র ১০,০০০ সম্ভাবনা।
const int kPairingPinLength = 6;

class ConnectionProvider extends ChangeNotifier {
  static const int defaultServerPort = 9090;
  static const int defaultDiscoveryPort = 9091;

  // --- State ---
  ConnectionState _state = ConnectionState.disconnected;
  ConnectionMode _mode = ConnectionMode.client;
  String _localIp = '';
  String _serverIp = '';
  int _serverPort = defaultServerPort;
  String _errorMessage = '';
  String _connectedDeviceName = '';
  DeviceInfo? _remoteDeviceInfo;
  ServerConfig _serverConfig = const ServerConfig();
  final List<DiscoveredDevice> _discoveredDevices = [];
  int _latencyMs = 0;
  String? _pairingPin;
  bool _isAuthenticated = false;

  // --- Brute-force throttle (server mode) ---
  // পরপর কয়েকবার ভুল PIN এলে কিছুক্ষণ সব auth চেষ্টা প্রত্যাখ্যান করা হয়।
  int _consecutiveAuthFailures = 0;
  DateTime? _authLockoutUntil;
  static const int _authFailuresBeforeLockout = 5;
  static const Duration _authLockoutDuration = Duration(seconds: 30);

  // --- Settings ---
  bool _hasStylusSupportSetting = false;
  double _maxPressureSetting = 1.0;
  double _clientScreenWidth = 1080;
  double _clientScreenHeight = 1920;
  bool _isDisposed = false;

  // --- Network ---
  WebSocket? _socket;
  HttpServer? _httpServer;
  StreamSubscription? _socketSubscription;
  RawDatagramSocket? _serverUdpSocket;
  RawDatagramSocket? _clientUdpSocket;
  Timer? _discoveryTimer;
  Timer? _discoveryTimeoutTimer;
  Timer? _reconnectTimer;
  bool _reconnectInProgress = false;
  Timer? _pingTimer;
  int _lastReportedRejects = 0;

  /// secure channel না থাকায় যতগুলো ইনপুট প্যাকেট পাঠানো যায়নি।
  int _unsealedDropCount = 0;

  int _lastDataSentOrReceivedTime = 0;
  Completer<bool>? _authCompleter;
  Future<String?> Function()? _clientPinCallback;

  /// auth সফল হওয়ার পর এই চ্যানেল দিয়েই সব ফ্রেম যায়/আসে।
  /// null মানে এখনো handshake শেষ হয়নি — তখন কেবল প্লেইনটেক্সট auth মেসেজ চলে।
  /// আগে এখানে XOR key (`_encryptionKey`) ছিল, যা এনক্রিপশন নয় বরং obfuscation।
  SecureChannel? _channel;

  /// সার্ভার মোডে এই সেশনের জন্য তৈরি করা ৩২ বাইট session key।
  List<int>? _sessionKey;

  ConnectionProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _hasStylusSupportSetting = prefs.getBool('stylus_supported') ?? false;
      _maxPressureSetting = prefs.getDouble('max_pressure') ?? 1.0;
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading settings: $e');
    }
  }

  Future<void> setStylusSupport(bool val) async {
    if (_hasStylusSupportSetting != val) {
      _hasStylusSupportSetting = val;
      notifyListeners();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('stylus_supported', val);
      } catch (e) {
        debugPrint('Error saving stylus settings: $e');
      }
      _sendUpdatedDeviceInfo();
    }
  }

  Future<void> setMaxPressure(double val) async {
    if (_maxPressureSetting != val) {
      _maxPressureSetting = val;
      notifyListeners();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('max_pressure', val);
      } catch (e) {
        debugPrint('Error saving max pressure settings: $e');
      }
      _sendUpdatedDeviceInfo();
    }
  }

  void _sendUpdatedDeviceInfo() {
    if (isConnected && _mode == ConnectionMode.client) {
      final deviceInfo = DeviceInfo(
        deviceName: kIsWeb ? 'Web Browser' : Platform.localHostname,
        deviceModel: kIsWeb ? 'Web' : Platform.operatingSystem,
        platform: kIsWeb ? 'web' : (Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'windows')),
        screenWidth: _clientScreenWidth,
        screenHeight: _clientScreenHeight,
        hasStylusSupport: _hasStylusSupportSetting,
        maxPressure: _maxPressureSetting,
      );
      _sendToServer({
        'type': 'device_info',
        'data': deviceInfo.toJson(),
      });
    }
  }

  /// PIN তুলনা constant-time এ — timing দিয়ে ডিজিট-বাই-ডিজিট অনুমান আটকায়।
  /// C# সার্ভারের FixedTimeEquals এর সমতুল্য।
  bool _constantTimeEquals(String a, String b) =>
      SecureChannel.constantTimeEquals(utf8.encode(a), utf8.encode(b));

  // --- Callbacks ---
  void Function(InputEvent)? onInputEventReceived;
  void Function()? onClientConnected;
  void Function()? onClientDisconnected;
  void Function(DiscoveredDevice)? onDeviceDiscovered;

  // Getters
  ConnectionState get state => _state;
  ConnectionMode get mode => _mode;
  String get localIp => _localIp;
  String get serverIp => _serverIp;
  int get serverPort => _serverPort;
  String get errorMessage => _errorMessage;
  String get connectedDeviceName => _connectedDeviceName;
  DeviceInfo? get remoteDeviceInfo => _remoteDeviceInfo;
  ServerConfig get serverConfig => _serverConfig;
  List<DiscoveredDevice> get discoveredDevices => _discoveredDevices;
  int get latencyMs => _latencyMs;

  /// MAC/replay চেকে বাতিল হওয়া ফ্রেমের সংখ্যা। স্ট্রোক কেটে কেটে আসছে কেন —
  /// ক্রিপ্টো ফ্রেম ড্রপ হচ্ছে নাকি WiFi/রেন্ডারিং ধীর — সেটা আলাদা করতে কাজে লাগে।
  /// ০ থাকা মানে ড্রপের কারণ ক্রিপ্টো নয়।
  int get rejectedFrames => _channel?.rejectedFrames ?? 0;

  String? get pairingPin => _pairingPin;
  bool get isAuthenticated => _isAuthenticated;
  bool get isConnected => _state == ConnectionState.connected;
  bool get hasStylusSupportSetting => _hasStylusSupportSetting;
  double get maxPressureSetting => _maxPressureSetting;

  // ==================== SERVER MODE ====================

  /// পিসিতে সার্ভার শুরু করে - মোবাইল কানেক্ট করবে
  Future<bool> startServer({int port = defaultServerPort}) async {
    try {
      _mode = ConnectionMode.server;
      _serverPort = port;
      _setState(ConnectionState.discovering);
      _errorMessage = '';
      _isAuthenticated = false;
      _channel = null; // নতুন সেশনের জন্য পুরনো চ্যানেল রিসেট

      // প্রতিবার সার্ভার স্টার্টে নতুন র‍্যান্ডম ৬-ডিজিট PIN।
      // আগে hardcoded '1234' ছিল — পাবলিক রিপোতে কমিট করা মান কোনো secret নয়,
      // ফলে PIN যাচাই থাকলেও যে কেউ কানেক্ট করতে পারত।
      final rand = Random.secure();
      _pairingPin =
          List<int>.generate(kPairingPinLength, (_) => rand.nextInt(10)).join();
      _sessionKey = null; // প্রতিটি সফল auth-এ নতুন session key তৈরি হবে
      _consecutiveAuthFailures = 0;
      _authLockoutUntil = null;
      debugPrint('[Server] New pairing PIN generated (shown in UI)');

      // লোকাল IP বের করা
      _localIp = await _getLocalIpAddress();
      if (_localIp.isEmpty) {
        _localIp = '0.0.0.0';
      }

      // WebSocket Server শুরু করা
      _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _serverConfig = ServerConfig(port: port, useBinaryProtocol: true);

      // UDP Discovery Broadcast শুরু করা
      await _startDiscoveryBroadcast(port);

      // Incoming connections গ্রহণ
      _httpServer!.listen(_handleIncomingConnection);

      debugPrint('[Server] সার্ভার শুরু হয়েছে: $_localIp:$port');
      return true;
    } catch (e, stackTrace) {
      _errorMessage = 'সার্ভার শুরু করতে সমস্যা: $e';
      _setState(ConnectionState.error);
      debugPrint('[Server] Error starting server: $e\n$stackTrace');
      return false;
    }
  }

  void _handleIncomingConnection(HttpRequest request) {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      WebSocketTransformer.upgrade(request).then((WebSocket ws) {
        if (_socket != null) {
          debugPrint('[Server] Closing existing client connection to accept new one');
          _socket!.close();
          _socketSubscription?.cancel();
        }
        _socket = ws;
        _isAuthenticated = false;
        _channel = null; // নতুন ক্লায়েন্টের জন্য পুরনো চ্যানেল রিসেট
        debugPrint('[Server] ক্লায়েন্ট কানেক্টেড');

        // অথেন্টিকেশন চ্যালেঞ্জ পাঠানো
        _sendToClient({'type': 'auth_challenge'});

        // ইনকামিং ডেটা পড়া
        _socketSubscription = ws.listen(
          (data) => _handleServerReceive(data),
          onDone: () {
            debugPrint('[Server] ক্লায়েন্ট ডিসকানেক্টেড');
            _isAuthenticated = false;
            _channel = null; // ডিসকানেক্টে চ্যানেল রিসেট, নাহলে পরের ক্লায়েন্ট ভুল key পাবে
            _setState(ConnectionState.discovering);
            _connectedDeviceName = '';
            _remoteDeviceInfo = null;
            _stopLatencyMeasurement();
            onClientDisconnected?.call();
          },
          onError: (error) {
            debugPrint('[Server] কানেকশন ত্রুটি: $error');
            _setState(ConnectionState.discovering);
          },
        );

        onClientConnected?.call();
      });
    }
  }

  /// PIN মিলে যাওয়ার পর সার্ভার পাশের কাজ — নতুন session key বানিয়ে PIN-derived
  /// key এর নিচে মুড়ে ক্লায়েন্টকে পাঠানো, তারপর sealed চ্যানেল চালু করা।
  ///
  /// PBKDF2 অংশটা আলাদা isolate-এ, তাই এটা async। এই ফাঁকে ক্লায়েন্ট বদলে গেলে
  /// (নতুন ডিভাইস কানেক্ট) ফলাফল ফেলে দেওয়া হয়, নাহলে নতুন ক্লায়েন্টের চ্যানেল
  /// পুরনো key দিয়ে ওভাররাইট হয়ে যেত।
  Future<void> _completeServerHandshake() async {
    final socketAtStart = _socket;
    final pin = _pairingPin;
    if (socketAtStart == null || pin == null) return;

    final key = SecureChannel.generateSessionKey();
    final salt = SecureChannel.generateSalt();

    final Uint8List wrapped;
    try {
      wrapped = await wrapSessionKeyAsync(key, pin, salt);
    } catch (e) {
      debugPrint('[Server] Session key wrap failed: $e');
      _socket?.close(WebSocketStatus.internalServerError, 'Key exchange failed');
      return;
    }

    if (!identical(_socket, socketAtStart)) {
      debugPrint('[Server] Discarded handshake for a client that went away');
      return;
    }

    _sessionKey = key;
    _sendToClient({
      'type': 'auth_success',
      'kx': 'v2',
      'salt': base64Encode(salt),
      'iterations': SecureChannel.pbkdf2Iterations,
      'wrapped_key': base64Encode(wrapped),
    });

    // এর পর থেকে দুই দিকের সব ফ্রেম AES-256-CBC + HMAC-SHA256 দিয়ে
    _channel = SecureChannel(key, isServer: true);
    debugPrint('[Server] Client authenticated successfully');
    _startLatencyMeasurement();
  }

  void _handleServerReceive(dynamic data) {
    _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
    try {
      if (!_isAuthenticated) {
        // auth হওয়ার আগে কেবল auth_response গ্রহণযোগ্য।
        // অন্য যেকোনো ফ্রেম (বাইনারি ইনপুট প্যাকেট সহ) এলে কানেকশন বন্ধ —
        // C# সার্ভারের সাথে একই আচরণ।
        final lockedOut = _authLockoutUntil != null &&
            DateTime.now().isBefore(_authLockoutUntil!);

        if (!lockedOut && data is String) {
          Map<String, dynamic>? json;
          try {
            json = jsonDecode(data) as Map<String, dynamic>;
          } catch (_) {
            json = null;
          }
          if (json != null && json['type'] == 'auth_response') {
            final pin = json['pin'] as String?;
            if (pin != null && _pairingPin != null && _constantTimeEquals(pin, _pairingPin!)) {
              _isAuthenticated = true;
              _consecutiveAuthFailures = 0;
              _authLockoutUntil = null;

              // session key কখনো প্লেইনটেক্সটে যায় না। PIN + random salt থেকে
              // PBKDF2 দিয়ে wrapping key, তার নিচে key টা sealed হয়ে যায়।
              // আগে key টা কেবল PIN দিয়ে XOR করা হতো — মানে PIN জানলেই key,
              // আর PIN ছোট হওয়ায় আড়ি পাতা কেউ সেকেন্ডেই brute-force করতে পারত।
              //
              // প্রতিবার auth সফল হলে নতুন key — C# সার্ভারের মতোই। সার্ভার
              // স্টার্টের key পুনর্ব্যবহার করলে পুরনো সেশনের ফ্রেম নতুন সেশনে
              // replay করা যেত, কারণ নতুন চ্যানেলে seq কাউন্টার শূন্য থেকে শুরু।
              //
              // wrap করার PBKDF2-টা আলাদা isolate-এ, নাহলে ডেস্কটপ UI ওই
              // সময়টা জমে থাকে আর ইউজার ভাবে কানেক্ট হয়নি।
              unawaited(_completeServerHandshake());
              return;
            }
          }
        }

        if (lockedOut) {
          _sendToClient({
            'type': 'auth_fail',
            'reason': 'Too many failed attempts, try again later',
          });
        } else {
          // ভুল PIN বা auth-এর আগে অন্য কিছু পাঠানো — দুটোই reject
          _consecutiveAuthFailures++;
          if (_consecutiveAuthFailures >= _authFailuresBeforeLockout) {
            _authLockoutUntil = DateTime.now().add(_authLockoutDuration);
            _consecutiveAuthFailures = 0;
            debugPrint('[Server] Auth locked out for '
                '${_authLockoutDuration.inSeconds}s after repeated failures');
          }
          _sendToClient({'type': 'auth_fail', 'reason': 'Incorrect pairing PIN'});
          debugPrint('[Server] Client authentication rejected (pre-auth frame or wrong PIN)');
        }
        _socket?.close(WebSocketStatus.normalClosure, 'Auth failed');
        return;
      }

      // auth-এর পর সব বাইনারি ফ্রেম sealed — MAC না মিললে ভিতরে কী আছে দেখাই হয় না।
      if (data is List<int>) {
        if (_channel == null) return;
        final payload = _channel!.open(data);
        if (payload == null) {
          // tamper / replay / ভুল key — ফ্রেম ড্রপ, কানেকশন টেকে
          // (WiFi-তে নষ্ট ফ্রেম আসা স্বাভাবিক)
          return;
        }
        if (payload.length == InputEvent.binaryPacketLength) {
          onInputEventReceived?.call(InputEvent.fromBinary(payload));
        } else {
          try {
            _handleServerReceiveJson(
                jsonDecode(utf8.decode(payload)) as Map<String, dynamic>);
          } catch (e) {
            debugPrint('[Server] Failed to decode sealed payload: $e');
          }
        }
        return;
      }

      // auth-এর পর প্লেইনটেক্সট আর গ্রহণযোগ্য নয় — নাহলে যে কেউ MAC ছাড়াই
      // ইনপুট পাঠাতে পারত, অর্থাৎ এনক্রিপশনটাই optional হয়ে যেত।
      debugPrint('[Server] Dropped unsealed frame after authentication');
    } catch (e, stackTrace) {
      debugPrint('[Server] ডেটা পার্স ত্রুটি: $e\n$stackTrace');
    }
  }

  void _handleServerReceiveJson(Map<String, dynamic> json) {
    if (json.containsKey('type') && json['type'] is String) {
      final msgType = json['type'] as String;

      switch (msgType) {
        case 'device_info':
          if (json['data'] is Map<String, dynamic>) {
            _remoteDeviceInfo = DeviceInfo.fromJson(
              json['data'] as Map<String, dynamic>,
            );
            _connectedDeviceName = _remoteDeviceInfo!.deviceName;
            _setState(ConnectionState.connected);
            // কনফিগ পাঠানো (which will now be encrypted)
            _sendToClient({
              'type': 'server_config',
              'data': _serverConfig.toJson(),
            });
          }
          break;

        case 'input':
          if (json['data'] is Map<String, dynamic>) {
            final event = InputEvent.fromJson(json['data'] as Map<String, dynamic>);
            onInputEventReceived?.call(event);
          }
          break;

        case 'ping':
          _sendToClient({'type': 'pong', 'ts': json['ts']});
          break;

        case 'pong':
          // ক্লায়েন্ট থেকে pong পেলে সার্ভার-সাইড লেটেন্সি ক্যালকুলেট করুন
          if (json['ts'] is int) {
            _handlePong(json['ts'] as int);
          }
          break;
      }
    }
  }

  void _sendToClient(dynamic data) {
    if (_socket != null) {
      final encoded = data is String ? data : jsonEncode(data);
      try {
        if (_channel != null) {
          _socket!.add(_channel!.seal(utf8.encode(encoded)));
        } else {
          // কেবল handshake মেসেজ (auth_challenge / auth_fail / auth_success)
          _socket!.add(encoded);
        }
        _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
      } catch (e, stackTrace) {
        debugPrint('[Server] Socket write exception: $e\n$stackTrace');
      }
    }
  }

  // ==================== CLIENT MODE ====================

  /// সার্ভার খুঁজে বের করা (Hybrid Subnet TCP + UDP Discovery)
  Future<void> startDiscovery({int durationSeconds = 10}) async {
    _mode = ConnectionMode.client;
    _discoveredDevices.clear();
    _setState(ConnectionState.discovering);

    try {
      _localIp = await _getLocalIpAddress();

      // 1. Concurrent Subnet TCP Probe (Guaranteed 100% discovery even with UDP/router blocking)
      unawaited(_scanSubnetTcp(_localIp));

      // 2. UDP Broadcast Discovery
      _clientUdpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _clientUdpSocket!.broadcastEnabled = true;

      final discoveryMessage = jsonEncode({
        'type': 'aircanvas_discovery',
        'version': '1.0',
      });

      final subnetBroadcast = _getSubnetBroadcast(_localIp);

      _discoveryTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) {
          if (_clientUdpSocket != null) {
            try {
              // Subnet broadcast
              _clientUdpSocket!.send(
                utf8.encode(discoveryMessage),
                InternetAddress(subnetBroadcast),
                defaultDiscoveryPort,
              );
              // Global broadcast
              _clientUdpSocket!.send(
                utf8.encode(discoveryMessage),
                InternetAddress('255.255.255.255'),
                defaultDiscoveryPort,
              );
            } catch (e) {
              debugPrint('[Discovery] Error sending broadcast: $e');
            }
          }
        },
      );

      // Responses শোনা
      _clientUdpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _clientUdpSocket!.receive();
          if (datagram != null) {
            final message = utf8.decode(datagram.data);
            try {
              final json = jsonDecode(message) as Map<String, dynamic>;
              if (json['type'] == 'aircanvas_response') {
                String targetIp = datagram.address.address;
                final announcedIp = json['ip'] as String?;
                if (announcedIp != null &&
                    announcedIp.isNotEmpty &&
                    announcedIp != '0.0.0.0' &&
                    announcedIp != '127.0.0.1' &&
                    !announcedIp.startsWith('169.254.')) {
                  targetIp = announcedIp;
                }
                final device = DiscoveredDevice(
                  ip: targetIp,
                  name: json['name'] as String? ?? 'AirCanvas PC',
                  port: json['port'] as int? ?? defaultServerPort,
                );
                // Duplicate check on ip and port
                if (!_discoveredDevices.any((d) => d.ip == device.ip && d.port == device.port)) {
                  _discoveredDevices.add(device);
                  onDeviceDiscovered?.call(device);
                  notifyListeners();
                  debugPrint('[Discovery] ডিভাইস পাওয়া গেছে: ${device.ip}:${device.port} (${device.name})');
                }
              }
            } catch (e) {
              debugPrint('[Discovery] Parse exception: $e');
            }
          }
        }
      });

      // Duration শেষে discovery বন্ধ
      _discoveryTimeoutTimer = Timer(Duration(seconds: durationSeconds), () {
        stopDiscovery();
      });
    } catch (e, stackTrace) {
      _errorMessage = 'Discovery শুরু করতে সমস্যা: $e';
      _setState(ConnectionState.error);
      debugPrint('[Client] Discovery initialization failed: $e\n$stackTrace');
    }
  }

  void stopDiscovery() {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _discoveryTimeoutTimer?.cancel();
    _discoveryTimeoutTimer = null;
    _clientUdpSocket?.close();
    _clientUdpSocket = null;
    if (_state == ConnectionState.discovering && _discoveredDevices.isEmpty) {
      _errorMessage = 'কোনো ডিভাইস পাওয়া যায়নি। "Manual Connect" বাটন দিয়ে PC-এর IP দিয়ে কানেক্ট করুন।';
      _setState(ConnectionState.disconnected);
    } else if (_state == ConnectionState.discovering) {
      _setState(ConnectionState.disconnected);
    }
  }

  /// Fast Subnet TCP scanner (Scans local subnet for port 9090 in parallel)
  Future<void> _scanSubnetTcp(String localIp) async {
    if (localIp.isEmpty || localIp == '127.0.0.1') return;
    final parts = localIp.split('.');
    if (parts.length != 4) return;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}.';

    final hostIndices = List.generate(254, (i) => i + 1);
    const batchSize = 32;

    for (int b = 0; b < hostIndices.length; b += batchSize) {
      if (_state != ConnectionState.discovering) break;
      final batch = hostIndices.sublist(b, (b + batchSize > hostIndices.length) ? hostIndices.length : b + batchSize);

      await Future.wait(batch.map((host) async {
        final targetIp = '$prefix$host';
        try {
          final socket = await Socket.connect(
            targetIp,
            defaultServerPort,
            timeout: const Duration(milliseconds: 350),
          );
          socket.destroy();

          String deviceName = 'AirCanvas PC ($targetIp)';
          try {
            final client = HttpClient();
            client.connectionTimeout = const Duration(milliseconds: 350);
            final req = await client.getUrl(Uri.parse('http://$targetIp:$defaultServerPort/api/info'));
            final resp = await req.close().timeout(const Duration(milliseconds: 350));
            if (resp.statusCode == 200) {
              final body = await resp.transform(utf8.decoder).join();
              final json = jsonDecode(body) as Map<String, dynamic>;
              if (json['name'] != null) {
                deviceName = json['name'] as String;
              }
            }
          } catch (_) {}

          final device = DiscoveredDevice(
            ip: targetIp,
            name: deviceName,
            port: defaultServerPort,
          );

          if (!_discoveredDevices.any((d) => d.ip == device.ip && d.port == device.port)) {
            _discoveredDevices.add(device);
            onDeviceDiscovered?.call(device);
            notifyListeners();
            debugPrint('[SubnetScan] PC পাওয়া গেছে: $targetIp:9090 ($deviceName)');
          }
        } catch (_) {}
      }));
    }
  }

  String? _lastSuccessfulPin;

  /// সার্ভারের সাথে কানেক্ট করা (client side)
  Future<bool> connectToServer(
    String ip, {
    int port = defaultServerPort,
    required Future<String?> Function() onPinRequired,
    String? pin,
    double? screenWidth,
    double? screenHeight,
    bool isReconnecting = false,
  }) async {
    try {
      _serverIp = ip;
      _serverPort = port;

      if (isReconnecting) {
        _setState(ConnectionState.reconnecting);
      } else {
        _setState(ConnectionState.connecting);
      }

      _errorMessage = '';
      _clientPinCallback = onPinRequired;
      _authCompleter = Completer<bool>();
      _isAuthenticated = false;
      _channel = null; // প্রতিটি নতুন কানেকশনে পুরনো চ্যানেল রিসেট
      _unsealedDropCount = 0;
      
      // Auto-set last successful PIN if provided or default to '1234' for zero-friction connection
      final trimmedPin = (pin != null && pin.trim().isNotEmpty) ? pin.trim() : '1234';
      _lastSuccessfulPin = trimmedPin;

      if (screenWidth != null) _clientScreenWidth = screenWidth;
      if (screenHeight != null) _clientScreenHeight = screenHeight;

      // WebSocket connection with 10s timeout
      final uri = 'ws://$ip:$port';
      debugPrint('[Client] Connecting to server: $uri...');
      _socket = await WebSocket.connect(uri).timeout(const Duration(seconds: 10));
      debugPrint('[Client] সার্ভারে সকেট কানেক্টেড: $uri');

      // Incoming data listen
      await _socketSubscription?.cancel();
      _socketSubscription = _socket!.listen(
        (data) => _handleClientReceive(data),
        onDone: () {
          debugPrint('[Client] কানেকশন বন্ধ হয়েছে');
          _handleDisconnection();
        },
        onError: (error) {
          debugPrint('[Client] কানেকশন ত্রুটি: $error');
          _handleDisconnection();
        },
      );

      // হ্যান্ডশেক শেষ হওয়ার অপেক্ষা।
      //
      // আগে এখানে কোনো টাইমআউট ছিল না। সার্ভার TCP কানেকশন নিলেও যদি
      // auth_challenge না পাঠায় (ভুল পোর্টে অন্য কোনো সার্ভিস, অথবা সার্ভার
      // হ্যান্ডশেকের মাঝপথে আটকে যাওয়া), তাহলে অ্যাপ চিরকাল "connecting"
      // স্পিনারে বসে থাকত — কোনো এরর মেসেজ ছাড়াই। PBKDF2 ফোনে কয়েক সেকেন্ড
      // নিতে পারে, তাই সীমাটা উদার রাখা হলো।
      final success = await _authCompleter!.future
          .timeout(const Duration(seconds: 25), onTimeout: () {
        _errorMessage = 'সার্ভার হ্যান্ডশেকের উত্তর দিচ্ছে না। '
            'পিসিতে AirCanvas সার্ভার চালু আছে কি, আর পোর্ট $port ঠিক আছে কি?';
        debugPrint('[Client] Handshake timed out after 25s');
        return false;
      });
      if (success) {
        _startLatencyMeasurement();
        _setState(ConnectionState.connected);
        return true;
      } else {
        if (_errorMessage.isEmpty) {
          _errorMessage = 'অথেন্টিকেশন ফেইল করেছে। সঠিক PIN দিন।';
        }
        // সকেট লিক প্রতিরোধ করতে সকেট ও সাবস্ক্রিপশন বন্ধ করুন
        await _socketSubscription?.cancel();
        _socketSubscription = null;
        await _socket?.close();
        _socket = null;
        _isAuthenticated = false;

        if (!isReconnecting) {
          _setState(ConnectionState.error);
          await disconnect();
        }
        return false;
      }
    } catch (e, stackTrace) {
      debugPrint('Error in connectToServer: $e\n$stackTrace');
      // সকেট লিক প্রতিরোধ করতে সকেট ও সাবস্ক্রিপশন বন্ধ করুন
      await _socketSubscription?.cancel();
      _socketSubscription = null;
      await _socket?.close();
      _socket = null;
      _isAuthenticated = false;

      if (!isReconnecting) {
        if (e is TimeoutException) {
          _errorMessage = 'কানেকশন টাইমআউট। একই WiFi এবং Firewall নিশ্চিত করুন।';
        } else if (e.toString().contains('refused')) {
          _errorMessage = 'সার্ভারে কানেক্ট করা যায়নি (Connection Refused)। পিসিতে সার্ভার চালু আছে তো?';
        } else {
          _errorMessage = 'কানেক্ট করতে সমস্যা: $e';
        }
        _setState(ConnectionState.error);
      }
      if (_authCompleter != null && !_authCompleter!.isCompleted) {
        _completeAuth(false);
      }
      return false;
    }
  }

  void _handleClientReceive(dynamic data) {
    _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
    try {
      if (data is List<int>) {
        // handshake শেষ হওয়ার আগে বাইনারি ফ্রেম আসার কথা নয়
        if (_channel == null) {
          debugPrint('[Client] Dropped binary frame received before key exchange');
          return;
        }
        final payload = _channel!.open(data);
        if (payload == null) {
          debugPrint('[Client] Dropped frame that failed MAC/replay check');
          return;
        }
        try {
          _handleClientReceiveJson(
              jsonDecode(utf8.decode(payload)) as Map<String, dynamic>);
        } catch (e) {
          debugPrint('[Client] Failed to decode sealed payload: $e');
        }
        return;
      }

      if (data is String) {
        final json = jsonDecode(data) as Map<String, dynamic>;
        // auth শেষ হওয়ার পর প্লেইনটেক্সট আর গ্রহণযোগ্য নয় — নাহলে আক্রমণকারী
        // অথেন্টিকেশনের পরেও sealed চ্যানেল বাইপাস করে মেসেজ ঢোকাতে পারত।
        if (_channel != null) {
          debugPrint('[Client] Dropped unsealed frame after key exchange');
          return;
        }
        _handleClientReceiveJson(json);
      }
    } catch (e, stackTrace) {
      debugPrint('[Client] ডেটা পার্স ত্রুটি: $e\n$stackTrace');
    }
  }

  void _handleClientReceiveJson(Map<String, dynamic> json) {
    if (json.containsKey('type') && json['type'] is String) {
      final msgType = json['type'] as String;
      switch (msgType) {
        case 'auth_challenge':
          if (_lastSuccessfulPin != null) {
            debugPrint('[Client] Auto-authenticating with cached PIN');
            _sendToServer({
              'type': 'auth_response',
              'pin': _lastSuccessfulPin,
            });
          } else if (_clientPinCallback != null) {
            _clientPinCallback!().then((pin) {
              if (pin != null) {
                // provisionally রাখা হচ্ছে — auth_fail এলে মুছে ফেলা হয়।
                // auth_success এর wrapped key খুলতে এই PIN দরকার।
                _lastSuccessfulPin = pin;
                _sendToServer({
                  'type': 'auth_response',
                  'pin': pin,
                });
              } else {
                _errorMessage = 'অথেন্টিকেশন বাতিল করা হয়েছে।';
                _completeAuth(false);
              }
            });
          } else {
            _completeAuth(false);
          }
          break;
        case 'auth_success':
          // PBKDF2 আলাদা isolate-এ চলে, তাই এটা async। এখানে await করার কিছু
          // নেই — ফলাফল _authCompleter দিয়ে connectToServer এ পৌঁছে যায়।
          unawaited(_handleAuthSuccess(json));
          break;
        case 'auth_fail':
          _channel = null;
          _errorMessage = json['reason'] as String? ?? 'Authentication failed';
          _lastSuccessfulPin = null; // Clear cached PIN on failure
          _completeAuth(false);
          break;
        case 'server_config':
          if (json['data'] is Map<String, dynamic>) {
            _serverConfig = ServerConfig.fromJson(json['data'] as Map<String, dynamic>);
            debugPrint('[Client] সার্ভার কনফিগ পাওয়া: port=${_serverConfig.port}');
            notifyListeners();
          }
          break;
        case 'ping':
          // সার্ভারের লেটেন্সি মাপার ping-এর উত্তরে pong পাঠান
          _sendToServer({'type': 'pong', 'ts': json['ts']});
          break;
        case 'pong':
          if (json['ts'] is int) {
            _handlePong(json['ts'] as int);
          }
          break;
      }
    }
  }

  /// সার্ভারের auth_success এসেছে — এতে session key সরাসরি নেই, বরং PIN থেকে
  /// PBKDF2 করে পাওয়া key এর নিচে sealed অবস্থায় আছে। MAC মিললেই বোঝা যায়
  /// অন্য পাশে সত্যিই একই PIN জানা সার্ভার বসে আছে (mutual proof)।
  ///
  /// PBKDF2 ১ লাখ ইটারেশন — pairing-এর সময় একবারই চলে, প্রতি প্যাকেটে নয়।
  /// pointycastle native নয়, তাই কাজটা [unwrapSessionKeyAsync] দিয়ে আলাদা
  /// isolate-এ পাঠানো হয়; নাহলে ফোনে কয়েক সেকেন্ড UI জমে থাকত এবং সেটাকেই
  /// "কানেক্ট হচ্ছে না" মনে হতো।
  Future<void> _handleAuthSuccess(Map<String, dynamic> json) async {
    final pin = _lastSuccessfulPin;
    final saltB64 = json['salt'] as String?;
    final wrappedB64 = json['wrapped_key'] as String?;

    if (pin == null || saltB64 == null || wrappedB64 == null) {
      // পুরনো (v1) সার্ভার এখানে 'session_key' প্লেইনটেক্সটে পাঠাত। ওটা আর
      // মানা হয় না — নাহলে আক্রমণকারী v1 হ্যান্ডশেক জোর করে downgrade করাতে পারত।
      _errorMessage = 'সার্ভারটি পুরনো ভার্সনের (v1 handshake)। '
          'পিসির AirCanvas সার্ভার আপডেট করুন।';
      debugPrint('[Client] Rejected auth_success without v2 key exchange');
      _completeAuth(false);
      return;
    }

    List<int>? sessionKey;
    try {
      sessionKey = await unwrapSessionKeyAsync(
        base64Decode(wrappedB64),
        pin,
        base64Decode(saltB64),
        iterations: (json['iterations'] as num?)?.toInt() ?? SecureChannel.pbkdf2Iterations,
      );
    } catch (e) {
      debugPrint('[Client] Key unwrap threw: $e');
      sessionKey = null;
    }

    // isolate-এ কাজ চলার সময় সকেট বন্ধ হয়ে যেতে পারে — তখন এই ফলাফল বাসি।
    if (_socket == null || (_authCompleter?.isCompleted ?? true)) {
      debugPrint('[Client] Discarded stale key unwrap result');
      return;
    }

    if (sessionKey == null) {
      _errorMessage = 'সার্ভারের পাঠানো কী যাচাই করা যায়নি। PIN ঠিক আছে কি?';
      _lastSuccessfulPin = null;
      debugPrint('[Client] Session key unwrap failed (bad PIN or tampered frame)');
      _completeAuth(false);
      return;
    }

    _isAuthenticated = true;
    _channel = SecureChannel(sessionKey, isServer: false);
    debugPrint('[Client] Authenticated; secure channel established');

    final deviceInfo = DeviceInfo(
      deviceName: kIsWeb ? 'Web Browser' : Platform.localHostname,
      deviceModel: kIsWeb ? 'Web' : Platform.operatingSystem,
      platform: kIsWeb ? 'web' : (Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'windows')),
      screenWidth: _clientScreenWidth,
      screenHeight: _clientScreenHeight,
      hasStylusSupport: _hasStylusSupportSetting,
      maxPressure: _maxPressureSetting,
    );
    _sendToServer({
      'type': 'device_info',
      'data': deviceInfo.toJson(),
    });
    _completeAuth(true);
  }

  /// auth completer একবারই complete হতে পারে। আগে সব জায়গায়
  /// `_authCompleter?.complete(...)` লেখা ছিল — একের বেশি পথ একসাথে চললে
  /// (যেমন isolate থেকে ফেরার আগেই সকেট বন্ধ) "Future already completed"
  /// এক্সসেপশন উঠত এবং সেটা onError-এ গিয়ে কানেকশন ভেঙে দিত।
  void _completeAuth(bool success) {
    final completer = _authCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(success);
    }
  }

  void _handleDisconnection() {
    _completeAuth(false);
    // Only auto-reconnect if we were successfully connected and the connection dropped.
    // Do NOT reconnect on initial handshake failure or incorrect PIN.
    if (_state == ConnectionState.connected) {
      _setState(ConnectionState.reconnecting);

      // আগের reconnect timer থাকলে বন্ধ করুন (prevent stacking)
      _reconnectTimer?.cancel();
      _reconnectTimer = null;

      // Auto reconnect (3 attempts, 2 second intervals)
      int attempts = 0;
      _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        // যদি ইউজার আগেই disconnect করে ফেলে বা state পরিবর্তন হয়ে থাকে
        if (_state != ConnectionState.reconnecting) {
          timer.cancel();
          return;
        }
        // আগের রিকানেক্ট চেষ্টা এখনো চলমান থাকলে এই টিক স্কিপ করুন (overlap প্রতিরোধ)
        if (_reconnectInProgress) return;
        attempts++;
        if (attempts > 3) {
          timer.cancel();
          _reconnectTimer = null;
          _errorMessage = 'রিকানেক্ট করতে ব্যর্থ হয়েছে।';
          _setState(ConnectionState.error);
          return;
        }
        debugPrint('[Client] রিকানেক্ট চেষ্টা $attempts/3...');
        _reconnectInProgress = true;
        await _socketSubscription?.cancel();
        _socketSubscription = null;
        await _socket?.close();
        _socket = null;
        
        try {
          await connectToServer(
            _serverIp,
            port: _serverPort,
            onPinRequired: _clientPinCallback ?? () async => null,
            isReconnecting: true,
          );
          // Failure handling is done via states in connectToServer and this timer
        } finally {
          _reconnectInProgress = false;
        }
      });
    }
  }

  // ==================== INPUT SENDING ====================

  /// ইনপুট ইভেন্ট সার্ভারে পাঠানো (client side)
  void sendInputEvent(InputEvent event) {
    if (_socket == null || !isConnected) return;

    // চ্যানেল ছাড়া পাঠানোর কোনো অর্থ নেই: সার্ভার ৪৮ বাইটের চেয়ে ছোট বা
    // MAC-হীন ফ্রেম নিঃশব্দে ফেলে দেয়। আগে এখানে `_socket!.add(rawBytes)`
    // fallback ছিল — প্যাকেটগুলো তখন কালো গর্তে চলে যেত, ইউজার শুধু দেখত
    // "কানেক্টেড কিন্তু আঁকা হচ্ছে না"। এখন গোনা হয় ও লগ করা হয়।
    final channel = _channel;
    if (channel == null) {
      _unsealedDropCount++;
      if (_unsealedDropCount == 1 || _unsealedDropCount % 120 == 0) {
        debugPrint('[Client] Secure channel নেই, $_unsealedDropCount টি ইনপুট '
            'প্যাকেট পাঠানো হয়নি — আবার পেয়ার করুন।');
      }
      return;
    }

    final List<int> rawBytes;
    if (_serverConfig.useBinaryProtocol) {
      rawBytes = event.toBinary();
    } else {
      rawBytes = utf8.encode(jsonEncode({
        'type': 'input',
        'data': event.toJson(),
      }));
    }

    try {
      _socket!.add(channel.seal(rawBytes));
      _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
    } catch (e, stackTrace) {
      debugPrint('[Client] Input send exception: $e\n$stackTrace');
      _handleDisconnection();
    }
  }

  void _sendToServer(dynamic data) {
    if (_socket != null) {
      final encoded = data is String ? data : jsonEncode(data);
      try {
        if (_channel != null) {
          _socket!.add(_channel!.seal(utf8.encode(encoded)));
        } else {
          // কেবল handshake মেসেজ (auth_response) — তখনও চ্যানেল তৈরি হয়নি
          _socket!.add(encoded);
        }
        _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
      } catch (e, stackTrace) {
        debugPrint('[Client] Socket write exception: $e\n$stackTrace');
      }
    }
  }

  // ==================== DISCOVERY BROADCAST (SERVER) ====================

  Future<void> _startDiscoveryBroadcast(int serverPort) async {
    try {
      _serverUdpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        defaultDiscoveryPort,
        reuseAddress: true,
        reusePort: !kIsWeb && !Platform.isWindows,
      );
      _serverUdpSocket!.broadcastEnabled = true;
      _serverUdpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _serverUdpSocket!.receive();
          if (datagram != null) {
            try {
              final message = utf8.decode(datagram.data);
              final json = jsonDecode(message) as Map<String, dynamic>;
              if (json['type'] == 'aircanvas_discovery') {
                // Client কে respond করা
                final response = jsonEncode({
                  'type': 'aircanvas_response',
                  'name': kIsWeb ? 'Web Device' : Platform.localHostname,
                  'port': serverPort,
                  'ip': _localIp,
                });
                final encoded = utf8.encode(response);
                _serverUdpSocket!.send(encoded, datagram.address, datagram.port);
                try {
                  _serverUdpSocket!.send(encoded, InternetAddress('255.255.255.255'), defaultDiscoveryPort);
                } catch (_) {}
              }
            } catch (e, stackTrace) {
              debugPrint('[Server] Discovery request parse error: $e\n$stackTrace');
            }
          }
        }
      });

      debugPrint('[Server] Discovery broadcast শুরু হয়েছে (port $defaultDiscoveryPort)');
    } catch (e, stackTrace) {
      debugPrint('[Server] Discovery broadcast ত্রুটি: $e\n$stackTrace');
    }
  }

  // ==================== LATENCY MEASUREMENT ====================

  void _startLatencyMeasurement() {
    _pingTimer?.cancel();
    _lastReportedRejects = 0;
    // Ping adaptive (5 seconds interval when idle)
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // ফ্রেম ড্রপ হচ্ছে কিনা সেটা লগে তোলা — smoothness ডিবাগ করার সময়
      // এটাই বলে দেয় সমস্যা ক্রিপ্টোতে নাকি নেটওয়ার্কে/রেন্ডারিংয়ে।
      final rejects = rejectedFrames;
      if (rejects > _lastReportedRejects) {
        debugPrint('[SecureChannel] Rejected frames: $rejects '
            '(+${rejects - _lastReportedRejects} in last 5s)');
        _lastReportedRejects = rejects;
      }

      if (_socket != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        // Skip ping if we recently communicated to save network traffic
        if (now - _lastDataSentOrReceivedTime < 5000) {
          return;
        }

        final msg = {'type': 'ping', 'ts': now};
        if (_mode == ConnectionMode.client) {
          _sendToServer(msg);
        } else {
          _sendToClient(msg);
        }
      }
    });
  }

  /// pong response পেলে লেটেন্সি ক্যালকুলেট করুন
  void _handlePong(int pingTs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (pingTs > 0 && now >= pingTs) {
      _latencyMs = (now - pingTs) ~/ 2; // RTT / 2 = one-way latency
      notifyListeners();
    }
  }

  void _stopLatencyMeasurement() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _latencyMs = 0;
  }

  // ==================== UTILITY ====================

  String _getSubnetBroadcast(String ip) {
    if (ip.isEmpty || ip == '0.0.0.0' || ip.startsWith('127.')) return '255.255.255.255';
    final parts = ip.split('.');
    if (parts.length == 4) {
      return '${parts[0]}.${parts[1]}.${parts[2]}.255';
    }
    return '255.255.255.255';
  }

  Future<String> _getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      // Prioritize physical/real interfaces by filtering out virtual ones
      final realInterfaces = interfaces.where((interface) {
        final name = interface.name.toLowerCase();
        return !name.contains('vbox') &&
               !name.contains('virtual') &&
               !name.contains('vmware') &&
               !name.contains('wsl') &&
               !name.contains('docker') &&
               !name.contains('loopback');
      }).toList();

      // Search real interfaces first
      for (var interface in realInterfaces) {
        for (var addr in interface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
            return ip;
          }
        }
      }

      // Fallback to any non-loopback private IP
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
            return ip;
          }
        }
      }

      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
    } catch (e, stackTrace) {
      debugPrint('Error getting local IP: $e\n$stackTrace');
    }

    try {
      final info = NetworkInfo();
      final ip = await info.getWifiIP();
      return ip ?? '';
    } catch (_) {
      return '';
    }
  }

  void _setState(ConnectionState newState) {
    if (_state != newState) {
      _state = newState;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _completeAuth(false);
    _lastSuccessfulPin = null;
    _channel = null;
    _sessionKey = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectInProgress = false;
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _discoveryTimeoutTimer?.cancel();
    _discoveryTimeoutTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    
    await _socket?.close();
    _socket = null;
    
    await _httpServer?.close();
    _httpServer = null;
    
    _serverUdpSocket?.close();
    _serverUdpSocket = null;
    
    _clientUdpSocket?.close();
    _clientUdpSocket = null;
    
    _connectedDeviceName = '';
    _remoteDeviceInfo = null;
    _discoveredDevices.clear();
    _stopLatencyMeasurement();
    _setState(ConnectionState.disconnected);
    debugPrint('[Connection] ডিসকানেক্টেড');
  }

  void clearError() {
    _errorMessage = '';
    _setState(ConnectionState.disconnected);
  }

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    disconnect();
    super.dispose();
  }
}