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
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/input_event.dart';

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
  Timer? _pingTimer;
  int _lastDataSentOrReceivedTime = 0;
  Completer<bool>? _authCompleter;
  Future<String?> Function()? _clientPinCallback;
  List<int>? _encryptionKey;
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
        deviceName: Platform.localHostname,
        deviceModel: Platform.operatingSystem,
        platform: Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'windows'),
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

  List<int> _crypt(List<int> data, List<int> key) {
    final result = List<int>.filled(data.length, 0);
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ key[i % key.length];
    }
    return result;
  }

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

      // pairing pin জেনারেট করা
      final rand = Random.secure();
      _pairingPin = (1000 + rand.nextInt(9000)).toString();
      _sessionKey = List<int>.generate(32, (i) => rand.nextInt(256));
      debugPrint('[Server] Generated pairing PIN: $_pairingPin');

      // লোকাল IP বের করা
      _localIp = await _getLocalIpAddress();
      if (_localIp.isEmpty) {
        _localIp = '0.0.0.0';
      }

      // WebSocket Server শুরু করা
      _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _serverConfig = ServerConfig(port: port);

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
        debugPrint('[Server] ক্লায়েন্ট কানেক্টেড');

        // অথেন্টিকেশন চ্যালেঞ্জ পাঠানো
        _sendToClient({'type': 'auth_challenge'});

        // Ping-pong লেটেন্সি মাপা শুরু
        _startLatencyMeasurement();

        // ইনকামিং ডেটা পড়া
        _socketSubscription = ws.listen(
          (data) => _handleServerReceive(data),
          onDone: () {
            debugPrint('[Server] ক্লায়েন্ট ডিসকানেক্টেড');
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

  void _handleServerReceive(dynamic data) {
    _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
    try {
      if (!_isAuthenticated) {
        if (data is String) {
          final json = jsonDecode(data) as Map<String, dynamic>;
          if (json['type'] == 'auth_response') {
            final pin = json['pin'] as String?;
            if (pin == _pairingPin) {
              _isAuthenticated = true;
              // Temporarily set encryption key to PIN to securely send the new session key
              _encryptionKey = utf8.encode(_pairingPin!);
              _sendToClient({
                'type': 'auth_success',
                'session_key': base64Encode(_sessionKey!),
              });
              // Rotate to the new session key for all subsequent packets
              _encryptionKey = _sessionKey;
              debugPrint('[Server] Client authenticated successfully');
            } else {
              _sendToClient({'type': 'auth_fail', 'reason': 'Incorrect pairing PIN'});
              debugPrint('[Server] Client authentication failed (Incorrect PIN: $pin)');
              _socket?.close(WebSocketStatus.normalClosure, 'Auth failed');
            }
          }
        }
        return;
      }

      dynamic decryptedData = data;
      if (_encryptionKey != null && data is List<int>) {
        decryptedData = _crypt(data, _encryptionKey!);
      }

      if (decryptedData is List<int>) {
        // Binary mode (InputEvent.binaryPacketLength bytes event packet)
        if (decryptedData.length == InputEvent.binaryPacketLength) {
          final event = InputEvent.fromBinary(decryptedData);
          onInputEventReceived?.call(event);
        } else {
          try {
            final str = utf8.decode(decryptedData);
            _handleServerReceiveJson(jsonDecode(str) as Map<String, dynamic>);
          } catch (e, stackTrace) {
            debugPrint('[Server] Failed to decode decrypted packet: $e\n$stackTrace');
          }
        }
      } else if (decryptedData is String) {
        _handleServerReceiveJson(jsonDecode(decryptedData) as Map<String, dynamic>);
      }
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
      }
    }
  }

  void _sendToClient(dynamic data) {
    if (_socket != null) {
      final encoded = data is String ? data : jsonEncode(data);
      try {
        if (_encryptionKey != null) {
          final rawBytes = utf8.encode(encoded);
          _socket!.add(_crypt(rawBytes, _encryptionKey!));
        } else {
          _socket!.add(encoded);
        }
        _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
      } catch (e, stackTrace) {
        debugPrint('[Server] Socket write exception: $e\n$stackTrace');
      }
    }
  }

  // ==================== CLIENT MODE ====================

  /// সার্ভার খুঁজে বের করা (UDP Discovery)
  Future<void> startDiscovery({int durationSeconds = 5}) async {
    _mode = ConnectionMode.client;
    _discoveredDevices.clear();
    _setState(ConnectionState.discovering);

    try {
      _localIp = await _getLocalIpAddress();
      _clientUdpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _clientUdpSocket!.broadcastEnabled = true;

      // Discovery request পাঠানো
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
                final device = DiscoveredDevice(
                  ip: datagram.address.address,
                  name: json['name'] as String? ?? 'Unknown',
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
      _errorMessage = 'কোনো ডিভাইস পাওয়া যায়নি। একই WiFi-তে আছেন তো?';
      _setState(ConnectionState.error);
    }
  }

  String? _lastSuccessfulPin;

  /// ম্যানুয়ালি IP দিয়ে কানেক্ট করা
  Future<bool> connectToServer(
    String ip, {
    int port = defaultServerPort,
    required Future<String?> Function() onPinRequired,
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

      if (screenWidth != null) _clientScreenWidth = screenWidth;
      if (screenHeight != null) _clientScreenHeight = screenHeight;

      // WebSocket connection
      final uri = 'ws://$ip:$port';
      _socket = await WebSocket.connect(uri).timeout(const Duration(seconds: 5));
      debugPrint('[Client] সার্ভারে কানেক্টেড: $uri');

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

      // Ping-pong লেটেন্সি মাপা
      _startLatencyMeasurement();

      // Wait for authentication challenge to complete
      final success = await _authCompleter!.future;
      if (success) {
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
        _errorMessage = 'কানেক্ট করতে সমস্যা: $e';
        _setState(ConnectionState.error);
      }
      if (_authCompleter != null && !_authCompleter!.isCompleted) {
        _authCompleter!.complete(false);
      }
      return false;
    }
  }

  void _handleClientReceive(dynamic data) {
    _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
    try {
      dynamic decryptedData = data;
      if (_encryptionKey != null && data is List<int>) {
        decryptedData = _crypt(data, _encryptionKey!);
      }

      if (decryptedData is List<int>) {
        try {
          final str = utf8.decode(decryptedData);
          _handleClientReceiveJson(jsonDecode(str) as Map<String, dynamic>);
        } catch (e, stackTrace) {
          debugPrint('[Client] Failed to decode decrypted packet: $e\n$stackTrace');
        }
      } else if (decryptedData is String) {
        _handleClientReceiveJson(jsonDecode(decryptedData) as Map<String, dynamic>);
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
            _encryptionKey = utf8.encode(_lastSuccessfulPin!); // Temporarily use PIN for auth_success decryption
          } else if (_clientPinCallback != null) {
            _clientPinCallback!().then((pin) {
              if (pin != null) {
                _lastSuccessfulPin = pin; // Store provisionally, clear if auth_fail
                _sendToServer({
                  'type': 'auth_response',
                  'pin': pin,
                });
                _encryptionKey = utf8.encode(pin); // Temporarily use PIN for auth_success decryption
              } else {
                _errorMessage = 'অথেন্টিকেশন বাতিল করা হয়েছে।';
                _authCompleter?.complete(false);
              }
            });
          } else {
            _authCompleter?.complete(false);
          }
          break;
        case 'auth_success':
          _isAuthenticated = true;
          if (json.containsKey('session_key')) {
             _encryptionKey = base64Decode(json['session_key'] as String);
          } else {
             _encryptionKey = utf8.encode(_lastSuccessfulPin!); // Fallback
          }
          debugPrint('[Client] Authenticated successfully with rotated key');
          // Device info পাঠানো
          final deviceInfo = DeviceInfo(
            deviceName: Platform.localHostname,
            deviceModel: Platform.operatingSystem,
            platform: Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'windows'),
            screenWidth: _clientScreenWidth,
            screenHeight: _clientScreenHeight,
            hasStylusSupport: _hasStylusSupportSetting,
            maxPressure: _maxPressureSetting,
          );
          _sendToServer({
            'type': 'device_info',
            'data': deviceInfo.toJson(),
          });
          _authCompleter?.complete(true);
          break;
        case 'auth_fail':
          _encryptionKey = null; // Clear the temporary wrong PIN key
          _errorMessage = json['reason'] as String? ?? 'Authentication failed';
          _lastSuccessfulPin = null; // Clear cached PIN on failure
          _authCompleter?.complete(false);
          break;
        case 'server_config':
          if (json['data'] is Map<String, dynamic>) {
            _serverConfig = ServerConfig.fromJson(json['data'] as Map<String, dynamic>);
            debugPrint('[Client] সার্ভার কনফিগ পাওয়া: port=${_serverConfig.port}');
            notifyListeners();
          }
          break;
        case 'pong':
          if (json['ts'] is int) {
            _handlePong(json['ts'] as int);
          }
          break;
      }
    }
  }

  void _handleDisconnection() {
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(false);
    }
    if (_state == ConnectionState.connected || _state == ConnectionState.connecting) {
      _setState(ConnectionState.reconnecting);

      // আগের reconnect timer থাকলে বন্ধ করুন (prevent stacking)
      _reconnectTimer?.cancel();
      _reconnectTimer = null;

      // Auto reconnect (3 attempts, 2 second intervals)
      int attempts = 0;
      _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
        // যদি ইউজার আগেই disconnect করে ফেলে বা state পরিবর্তন হয়ে থাকে
        if (_state != ConnectionState.reconnecting) {
          timer.cancel();
          return;
        }
        attempts++;
        if (attempts > 3) {
          timer.cancel();
          _reconnectTimer = null;
          _errorMessage = 'রিকানেক্ট করতে ব্যর্থ হয়েছে।';
          _setState(ConnectionState.error);
          return;
        }
        debugPrint('[Client] রিকানেক্ট চেষ্টা $attempts/3...');
        _socketSubscription?.cancel();
        _socketSubscription = null;
        _socket?.close();
        _socket = null;
        
        connectToServer(
          _serverIp,
          port: _serverPort,
          onPinRequired: _clientPinCallback ?? () async => null,
          isReconnecting: true,
        ).then((success) {
          // Failure handling is done via states in connectToServer and this timer
        });
      });
    }
  }

  // ==================== INPUT SENDING ====================

  /// ইনপুট ইভেন্ট সার্ভারে পাঠানো (client side)
  void sendInputEvent(InputEvent event) {
    if (_socket == null || !isConnected) return;

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
      if (_encryptionKey != null) {
        _socket!.add(_crypt(rawBytes, _encryptionKey!));
      } else {
        _socket!.add(rawBytes);
      }
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
        if (_encryptionKey != null) {
          final rawBytes = utf8.encode(encoded);
          _socket!.add(_crypt(rawBytes, _encryptionKey!));
        } else {
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
      _serverUdpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, defaultDiscoveryPort);
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
                  'name': Platform.localHostname,
                  'port': serverPort,
                  'ip': _localIp,
                });
                _serverUdpSocket!.send(
                  utf8.encode(response),
                  datagram.address,
                  datagram.port,
                );
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
    // Ping adaptive (5 seconds interval when idle)
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
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
    if (ip.isEmpty) return '255.255.255.255';
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
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(false);
    }
    _lastSuccessfulPin = null;
    _encryptionKey = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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