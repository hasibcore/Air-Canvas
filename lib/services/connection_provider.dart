/// কানেকশন স্টেট ম্যানেজার
///
/// এই প্রোভাইডার সমগ্র কানেকশন লাইফসাইকেল ম্যানেজ করে:
/// 1. WiFi Discovery - UDP Broadcast দিয়ে সার্ভার খোঁজা
/// 2. WebSocket Connection - সার্ভারে কানেক্ট করা
/// 3. Handshake - ডিভাইস ইনফো ও কনফিগ এক্সচেঞ্জ
/// 4. Reconnection - স্বয়ংক্রিয় রিকানেক্ট

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';
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
  // --- State ---
  ConnectionState _state = ConnectionState.disconnected;
  ConnectionMode _mode = ConnectionMode.client;
  String _localIp = '';
  String _serverIp = '';
  int _serverPort = 9090;
  String _errorMessage = '';
  String _connectedDeviceName = '';
  DeviceInfo? _remoteDeviceInfo;
  ServerConfig _serverConfig = const ServerConfig();
  final List<DiscoveredDevice> _discoveredDevices = [];
  int _latencyMs = 0;
  String? _pairingPin;
  bool _isAuthenticated = false;

  // --- Network ---
  WebSocket? _socket;
  HttpServer? _httpServer;
  StreamSubscription? _socketSubscription;
  RawDatagramSocket? _udpSocket;
  Timer? _discoveryTimer;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  int _lastPingTimestamp = 0;
  Completer<bool>? _authCompleter;
  Future<String?> Function()? _clientPinCallback;
  List<int>? _encryptionKey;

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

  // ==================== SERVER MODE ====================

  /// পিসিতে সার্ভার শুরু করে - মোবাইল কানেক্ট করবে
  Future<bool> startServer({int port = 9090}) async {
    try {
      _mode = ConnectionMode.server;
      _serverPort = port;
      _setState(ConnectionState.discovering);
      _errorMessage = '';
      _isAuthenticated = false;

      // pairing pin জেনারেট করা
      final rand = Random();
      _pairingPin = (1000 + rand.nextInt(9000)).toString();
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

      _setState(ConnectionState.discovering);
      notifyListeners();
      debugPrint('[Server] সার্ভার শুরু হয়েছে: $_localIp:$port');
      return true;
    } catch (e) {
      _errorMessage = 'সার্ভার শুরু করতে সমস্যা: $e';
      _setState(ConnectionState.error);
      notifyListeners();
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
            notifyListeners();
          },
          onError: (error) {
            debugPrint('[Server] কানেকশন ত্রুটি: $error');
            _setState(ConnectionState.discovering);
            notifyListeners();
          },
        );

        onClientConnected?.call();
      });
    }
  }

  void _handleServerReceive(dynamic data) {
    try {
      if (!_isAuthenticated) {
        if (data is String) {
          final json = jsonDecode(data) as Map<String, dynamic>;
          if (json['type'] == 'auth_response') {
            final pin = json['pin'] as String?;
            if (pin == _pairingPin) {
              _isAuthenticated = true;
              _sendToClient({'type': 'auth_success'});
              _encryptionKey = utf8.encode(_pairingPin!); // Set encryption key
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
        // Binary mode (11 bytes event packet)
        if (decryptedData.length == 11) {
          final event = InputEvent.fromBinary(decryptedData);
          onInputEventReceived?.call(event);
        } else {
          try {
            final str = utf8.decode(decryptedData);
            _handleServerReceiveJson(jsonDecode(str) as Map<String, dynamic>);
          } catch (e) {
            debugPrint('[Server] Failed to decode decrypted packet: $e');
          }
        }
      } else if (decryptedData is String) {
        _handleServerReceiveJson(jsonDecode(decryptedData) as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('[Server] ডেটা পার্স ত্রুটি: $e');
    }
  }

  void _handleServerReceiveJson(Map<String, dynamic> json) {
    if (json.containsKey('type')) {
      final msgType = json['type'] as String;

      switch (msgType) {
        case 'device_info':
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
          notifyListeners();
          break;

        case 'input':
          final event = InputEvent.fromJson(json['data']);
          onInputEventReceived?.call(event);
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
      if (_encryptionKey != null) {
        final rawBytes = utf8.encode(encoded);
        _socket!.add(_crypt(rawBytes, _encryptionKey!));
      } else {
        _socket!.add(encoded);
      }
    }
  }

  // ==================== CLIENT MODE ====================

  /// সার্ভার খুঁজে বের করা (UDP Discovery)
  Future<void> startDiscovery({int durationSeconds = 5}) async {
    _mode = ConnectionMode.client;
    _discoveredDevices.clear();
    _setState(ConnectionState.discovering);
    notifyListeners();

    try {
      _localIp = await _getLocalIpAddress();
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

      // Discovery request পাঠানো
      final discoveryMessage = jsonEncode({
        'type': 'superdisplay_discovery',
        'version': '1.0',
      });

      _discoveryTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) {
          if (_udpSocket != null) {
            _udpSocket!.send(
              utf8.encode(discoveryMessage),
              InternetAddress('255.255.255.255'),
              9091, // Discovery port
            );
          }
        },
      );

      // Responses শোনা
      _udpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket!.receive();
          if (datagram != null) {
            final message = utf8.decode(datagram.data);
            try {
              final json = jsonDecode(message) as Map<String, dynamic>;
              if (json['type'] == 'superdisplay_response') {
                final device = DiscoveredDevice(
                  ip: datagram.address.address,
                  name: json['name'] as String? ?? 'Unknown',
                  port: json['port'] as int? ?? 9090,
                );
                // Duplicate check
                if (!_discoveredDevices.any((d) => d.ip == device.ip)) {
                  _discoveredDevices.add(device);
                  onDeviceDiscovered?.call(device);
                  notifyListeners();
                  debugPrint('[Discovery] ডিভাইস পাওয়া গেছে: ${device.ip} (${device.name})');
                }
              }
            } catch (_) {}
          }
        }
      });

      // Duration শেষে discovery বন্ধ
      Timer(Duration(seconds: durationSeconds), () {
        stopDiscovery();
      });
    } catch (e) {
      _errorMessage = 'Discovery শুরু করতে সমস্যা: $e';
      _setState(ConnectionState.error);
      notifyListeners();
    }
  }

  void stopDiscovery() {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _udpSocket?.close();
    _udpSocket = null;
    if (_state == ConnectionState.discovering && _discoveredDevices.isEmpty) {
      _errorMessage = 'কোনো ডিভাইস পাওয়া যায়নি। একই WiFi-তে আছেন তো?';
      _setState(ConnectionState.error);
      notifyListeners();
    }
  }

  String? _lastSuccessfulPin;

  /// ম্যানুয়ালি IP দিয়ে কানেক্ট করা
  Future<bool> connectToServer(
    String ip, {
    int port = 9090,
    required Future<String?> Function() onPinRequired,
  }) async {
    try {
      _serverIp = ip;
      _serverPort = port;
      _setState(ConnectionState.connecting);
      _errorMessage = '';
      _clientPinCallback = onPinRequired;
      _authCompleter = Completer<bool>();
      _isAuthenticated = false;
      notifyListeners();

      // WebSocket connection
      final uri = 'ws://$ip:$port';
      _socket = await WebSocket.connect(uri).timeout(const Duration(seconds: 5));
      debugPrint('[Client] সার্ভারে কানেক্টেড: $uri');

      // Incoming data listen
      _socketSubscription?.cancel();
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
        notifyListeners();
        return true;
      } else {
        if (_errorMessage.isEmpty) {
          _errorMessage = 'অথেন্টিকেশন ফেইল করেছে। সঠিক PIN দিন।';
        }
        _setState(ConnectionState.error);
        notifyListeners();
        disconnect();
        return false;
      }
    } catch (e) {
      _errorMessage = 'কানেক্ট করতে সমস্যা: $e';
      _setState(ConnectionState.error);
      notifyListeners();
      if (_authCompleter != null && !_authCompleter!.isCompleted) {
        _authCompleter!.complete(false);
      }
      return false;
    }
  }

  void _handleClientReceive(dynamic data) {
    try {
      dynamic decryptedData = data;
      if (_encryptionKey != null && data is List<int>) {
        decryptedData = _crypt(data, _encryptionKey!);
      }

      if (decryptedData is List<int>) {
        try {
          final str = utf8.decode(decryptedData);
          _handleClientReceiveJson(jsonDecode(str) as Map<String, dynamic>);
        } catch (e) {
          debugPrint('[Client] Failed to decode decrypted packet: $e');
        }
      } else if (decryptedData is String) {
        _handleClientReceiveJson(jsonDecode(decryptedData) as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('[Client] ডেটা পার্স ত্রুটি: $e');
    }
  }

  void _handleClientReceiveJson(Map<String, dynamic> json) {
    final msgType = json['type'] as String;
    switch (msgType) {
      case 'auth_challenge':
        if (_lastSuccessfulPin != null) {
          debugPrint('[Client] Auto-authenticating with cached PIN');
          _sendToClient({
            'type': 'auth_response',
            'pin': _lastSuccessfulPin,
          });
        } else if (_clientPinCallback != null) {
          _clientPinCallback!().then((pin) {
            if (pin != null) {
              _lastSuccessfulPin = pin; // Store provisionally, clear if auth_fail
              _sendToClient({
                'type': 'auth_response',
                'pin': pin,
              });
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
        _encryptionKey = utf8.encode(_lastSuccessfulPin!); // Set encryption key
        debugPrint('[Client] Authenticated successfully');
        // Device info পাঠানো
        final deviceInfo = DeviceInfo(
          deviceName: 'Mobile Tablet',
          deviceModel: 'Flutter Device',
          platform: Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'windows'),
          screenWidth: 1080,
          screenHeight: 1920,
          hasStylusSupport: true,
          maxPressure: 1.0,
        );
        _sendToClient({
          'type': 'device_info',
          'data': deviceInfo.toJson(),
        });
        _authCompleter?.complete(true);
        break;
      case 'auth_fail':
        _errorMessage = json['reason'] as String? ?? 'Authentication failed';
        _lastSuccessfulPin = null; // Clear cached PIN on failure
        _authCompleter?.complete(false);
        break;
      case 'server_config':
        _serverConfig = ServerConfig.fromJson(json['data']);
        debugPrint('[Client] সার্ভার কনফিগ পাওয়া: port=${_serverConfig.port}');
        notifyListeners();
        break;
      case 'pong':
        _handlePong(json['ts'] as int);
        break;
    }
  }

  void _handleDisconnection() {
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(false);
    }
    if (_state == ConnectionState.connected || _state == ConnectionState.connecting) {
      _setState(ConnectionState.reconnecting);
      notifyListeners();

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
          notifyListeners();
          return;
        }
        debugPrint('[Client] রিকানেক্ট চেষ্টা $attempts/3...');
        _socketSubscription?.cancel();
        _socket = null;
        _setState(ConnectionState.connecting);
        connectToServer(
          _serverIp,
          port: _serverPort,
          onPinRequired: _clientPinCallback ?? () async => null,
        ).then((success) {
          if (!success && _state == ConnectionState.reconnecting) {
            // Already set error state
          }
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

    if (_encryptionKey != null) {
      _socket!.add(_crypt(rawBytes, _encryptionKey!));
    } else {
      _socket!.add(rawBytes);
    }
  }

  // ==================== DISCOVERY BROADCAST (SERVER) ====================

  Future<void> _startDiscoveryBroadcast(int serverPort) async {
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 9091);

      // Broadcast responses listen
      _udpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket!.receive();
          if (datagram != null) {
            try {
              final message = utf8.decode(datagram.data);
              final json = jsonDecode(message) as Map<String, dynamic>;
              if (json['type'] == 'superdisplay_discovery') {
                // Client কে respond করা
                final response = jsonEncode({
                  'type': 'superdisplay_response',
                  'name': 'My PC',
                  'port': serverPort,
                  'ip': _localIp,
                });
                _udpSocket!.send(
                  utf8.encode(response),
                  datagram.address,
                  datagram.port,
                );
              }
            } catch (_) {}
          }
        }
      });

      debugPrint('[Server] Discovery broadcast শুরু হয়েছে (port 9091)');
    } catch (e) {
      debugPrint('[Server] Discovery broadcast ত্রুটি: $e');
    }
  }

  // ==================== LATENCY MEASUREMENT ====================

  void _startLatencyMeasurement() {
    _pingTimer?.cancel();
    _lastPingTimestamp = 0;
    _pingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_socket != null) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        _lastPingTimestamp = ts;
        final msg = jsonEncode({'type': 'ping', 'ts': ts});
        if (_mode == ConnectionMode.client) {
          _socket!.add(msg);
        } else {
          _sendToClient(msg);
        }
      }
    });
  }

  /// pong response পেলে লেটেন্সি ক্যালকুলেট করুন
  void _handlePong(int pingTs) {
    if (_lastPingTimestamp > 0) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _latencyMs = (now - pingTs) ~/ 2; // RTT / 2 = one-way latency
      notifyListeners();
    }
  }

  void _stopLatencyMeasurement() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _lastPingTimestamp = 0;
    _latencyMs = 0;
  }

  // ==================== UTILITY ====================

  Future<String> _getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      
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
    } catch (e) {
      debugPrint('Error getting local IP: $e');
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
    _state = newState;
  }

  void disconnect() {
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(false);
    }
    _lastSuccessfulPin = null;
    _encryptionKey = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _socketSubscription?.cancel();
    _socket?.close();
    _httpServer?.close();
    _udpSocket?.close();
    _socket = null;
    _httpServer = null;
    _udpSocket = null;
    _connectedDeviceName = '';
    _remoteDeviceInfo = null;
    _discoveredDevices.clear();
    _stopLatencyMeasurement();
    _setState(ConnectionState.disconnected);
    notifyListeners();
    debugPrint('[Connection] ডিসকানেক্টেড');
  }

  void clearError() {
    _errorMessage = '';
    _setState(ConnectionState.disconnected);
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}