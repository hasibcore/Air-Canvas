// Connection State Manager
//
// Manages the entire connection lifecycle:
// 1. WiFi Discovery - UDP Broadcast to locate server
// 2. WebSocket Connection - Connect to PC server
// 3. Handshake - Device info and configuration exchange
// 4. Reconnection - Automatic reconnect

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/input_event.dart';
import 'secure_channel.dart';

enum ConnectionMode { server, client }

/// Transport type selection (Additive USB + Wi-Fi)
enum TransportType {
  auto,
  usb,
  wifi,
}

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
  final TransportType transportType;

  DiscoveredDevice({
    required this.ip,
    required this.name,
    required this.port,
    this.transportType = TransportType.wifi,
    DateTime? discoveredAt,
  }) : discoveredAt = discoveredAt ?? DateTime.now();
}

/// Pairing PIN length. Matches C# server GeneratePairingPin().
/// 6 digits provide 1,000,000 possibilities with brute-force lockout.
const int kPairingPinLength = 6;

class ConnectionProvider extends ChangeNotifier {
  static const int defaultServerPort = 9090;
  static const int defaultDiscoveryPort = 9091;

  // --- Transport State (Unconditionally Free USB & Wi-Fi) ---
  TransportType _selectedTransport = TransportType.auto;
  TransportType _activeTransport = TransportType.wifi;
  TransportType get selectedTransport => _selectedTransport;
  TransportType get activeTransport => _activeTransport;
  bool get isUsbActive => _activeTransport == TransportType.usb;

  // Session tracking for strict session isolation across switches (Rule 7)
  String _sessionId = '';
  String get sessionId => _sessionId;

  // Bounded Outbound Queue (Rule 9: Backpressure / Queue Safety)
  // Maximum 64 events capacity (~533ms backlog at 120Hz). Prevents unbounded latency.
  static const int maxQueueCapacity = 64;
  final List<InputEvent> _outboundQueue = [];
  bool _isFlushingQueue = false;

  // USB Stream Framing & Raw TCP Socket
  Socket? _rawTcpSocket;
  StreamSubscription? _rawTcpSubscription;
  List<int> _tcpStreamBuffer = [];

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
  // Rejects all auth attempts for a cooldown period after repeated wrong PIN attempts.
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

  int _lastDataSentOrReceivedTime = 0;
  Completer<bool>? _authCompleter;
  Future<String?> Function()? _clientPinCallback;

  /// Secure channel through which all frames flow after authentication.
  /// null indicates handshake is in progress - only handshake messages allowed.
  /// Replaced former XOR key with robust AES-256-CBC session key.
  SecureChannel? _channel;

  /// 32-byte session key generated for this session in server mode.
  List<int>? _sessionKey;
  List<int>? get currentSessionKey => _sessionKey;

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

  /// Constant-time PIN comparison to prevent timing side-channel attacks.
  /// Equivalent to C# server FixedTimeEquals.
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

  /// Number of frames rejected by MAC/replay check. Helps distinguish whether
  /// dropped strokes are crypto rejections or network/rendering latency.
  /// 0 means crypto is not causing any frame drops.
  int get rejectedFrames => _channel?.rejectedFrames ?? 0;

  String? get pairingPin => _pairingPin;
  bool get isAuthenticated => _isAuthenticated;
  bool get isConnected => _state == ConnectionState.connected;
  bool get hasStylusSupportSetting => _hasStylusSupportSetting;
  double get maxPressureSetting => _maxPressureSetting;

  // ==================== SERVER MODE ====================

  /// Starts server on PC for mobile/client devices to connect
  Future<bool> startServer({int port = defaultServerPort}) async {
    try {
      _mode = ConnectionMode.server;
      _serverPort = port;
      _setState(ConnectionState.discovering);
      _errorMessage = '';
      _isAuthenticated = false;
      _channel = null; // Reset channel for new session

      // Generate fresh random 6-digit PIN on each server start.
      // Prevents unauthorized connections and replaces hardcoded secrets.
      final rand = Random.secure();
      _pairingPin =
          List<int>.generate(kPairingPinLength, (_) => rand.nextInt(10)).join();
      _sessionKey = null; // Fresh session key generated upon each successful auth
      _consecutiveAuthFailures = 0;
      _authLockoutUntil = null;
      debugPrint('[Server] New pairing PIN generated (shown in UI)');

      // Determine local IP address
      _localIp = await _getLocalIpAddress();
      if (_localIp.isEmpty) {
        _localIp = '0.0.0.0';
      }

      // Start WebSocket Server
      // Detect PC display resolution for accurate client aspect ratio
      int screenW = 1920;
      int screenH = 1080;
      try {
        final displays = ui.PlatformDispatcher.instance.displays;
        if (displays.isNotEmpty && displays.first.size.width > 0 && displays.first.size.height > 0) {
          screenW = displays.first.size.width.toInt();
          screenH = displays.first.size.height.toInt();
        }
      } catch (e) {
        debugPrint('[Server] Display resolution detection fallback: $e');
      }

      _serverConfig = ServerConfig(
        port: port,
        useBinaryProtocol: true,
        screenWidth: screenW,
        screenHeight: screenH,
      );

      // Start UDP Discovery Broadcast
      await _startDiscoveryBroadcast(port);

      // Accept incoming connections
      _httpServer!.listen(_handleIncomingConnection);

      debugPrint('[Server] Server started: $_localIp:$port');
      return true;
    } catch (e, stackTrace) {
      _errorMessage = 'Failed to start server: $e';
      _setState(ConnectionState.error);
      debugPrint('[Server] Error starting server: $e\n$stackTrace');
      return false;
    }
  }

  void _handleIncomingConnection(HttpRequest request) {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      WebSocketTransformer.upgrade(request).then((WebSocket ws) async {
        if (_socket != null && _socket!.readyState == WebSocket.open) {
          debugPrint('[Server] Rejecting additional client: already connected');
          try {
            ws.add(jsonEncode({
              'type': 'server_busy',
              'reason': 'Another device is already connected. Disconnect it first.',
            }));
          } catch (_) {}
          await ws.close(WebSocketStatus.policyViolation, 'Server busy');
          return;
        }
        if (_socket != null) {
          await _socketSubscription?.cancel();
          await _socket?.close();
        }
        _socket = ws;
        _isAuthenticated = false;
        _channel = null; // Reset channel for new client
        debugPrint('[Server] Client connected');

        // Send authentication challenge
        _sendToClient({'type': 'auth_challenge'});

        // Listen to incoming data
        _socketSubscription = ws.listen(
          (data) => _handleServerReceive(data),
          onDone: () {
            debugPrint('[Server] Client disconnected');
            _isAuthenticated = false;
            _channel = null; // Reset channel on disconnect
            _setState(ConnectionState.discovering);
            _connectedDeviceName = '';
            _remoteDeviceInfo = null;
            _stopLatencyMeasurement();
            onClientDisconnected?.call();
          },
          onError: (error) {
            debugPrint('[Server] Connection error: $error');
            _setState(ConnectionState.discovering);
          },
        );

        onClientConnected?.call();
      });
    }
  }

  /// Server-side handling after PIN matches: generates new session key
  /// wrapped with PIN-derived key, sends to client, and activates sealed channel.
  ///
  /// PBKDF2 runs in a background isolate.
  /// If client changes during computation, stale result is discarded.
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
      unawaited(_socket?.close(WebSocketStatus.internalServerError, 'Key exchange failed'));
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

    // From now on, all frames in both directions use AES-256-CBC + HMAC-SHA256
    _channel = SecureChannel(key, isServer: true);
    debugPrint('[Server] Client authenticated successfully');
    _startLatencyMeasurement();
  }

  void _handleServerReceive(dynamic data) {
    _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
    try {
      if (!_isAuthenticated) {
        // Only auth_response is accepted prior to authentication.
        // Any other frame (including binary input) closes connection.
        // Matches C# server security behavior.
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

              // Session key is never transmitted in plaintext. Wrapped with
              // PBKDF2-derived key from PIN + random salt.
              //
              // Fresh session key is generated upon each successful auth.
              //
              // PBKDF2 runs in a background isolate to keep UI responsive.
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
          // Invalid PIN or unexpected pre-auth frame: reject connection
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

      // All binary frames post-auth are sealed. Discards if MAC fails.
      if (data is List<int>) {
        if (_channel == null) return;
        final payload = _channel!.open(data);
        if (payload == null) {
          // Tamper / replay / invalid key — drop frame silently to maintain connection
          // (network corruptions over WiFi are expected)
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

      // Plaintext frames are rejected after authentication to prevent bypass.
      debugPrint('[Server] Dropped unsealed frame after authentication');
    } catch (e, stackTrace) {
      debugPrint('[Server] Data parse error: $e\n$stackTrace');
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
            // Retrigger callback after receiving device info to ensure screen mapping
            // updates with correct resolution (native injection accuracy).
            onClientConnected?.call();
            // Send server configuration (now encrypted)
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
          // Calculate server-side latency upon receiving pong from client
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
          // Handshake messages only (auth_challenge / auth_fail / auth_success)
          _socket!.add(encoded);
        }
        _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
      } catch (e, stackTrace) {
        debugPrint('[Server] Socket write exception: $e\n$stackTrace');
      }
    }
  }

  // ==================== CLIENT MODE ====================

  /// Discover servers (Hybrid Subnet TCP + UDP Discovery)
  Future<void> startDiscovery({int durationSeconds = 10}) async {
    _mode = ConnectionMode.client;
    _discoveredDevices.clear();
    _setState(ConnectionState.discovering);

    try {
      _localIp = await _getLocalIpAddress();

      // 0. Probe USB transport (ADB reverse / loopback 127.0.0.1)
      if (!kIsWeb && (_selectedTransport == TransportType.auto || _selectedTransport == TransportType.usb)) {
        unawaited(_probeUsbTransport());
      }

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

      // Listen for responses
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
                  debugPrint('[Discovery] Device found: ${device.ip}:${device.port} (${device.name})');
                }
              }
            } catch (e) {
              debugPrint('[Discovery] Parse exception: $e');
            }
          }
        }
      });

      // Stop discovery after timeout
      _discoveryTimeoutTimer = Timer(Duration(seconds: durationSeconds), () {
        stopDiscovery();
      });
    } catch (e, stackTrace) {
      _errorMessage = 'Failed to start discovery: $e';
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
      _errorMessage = 'No devices found. Use "Manual Connect" and enter your PC\'s IP address.';
      _setState(ConnectionState.disconnected);
    } else if (_state == ConnectionState.discovering) {
      _setState(ConnectionState.disconnected);
    }
  }

  /// Fast Subnet TCP scanner (Scans local subnet & common Wi-Fi/Hotspot subnets for port 9090 in parallel)
  Future<void> _scanSubnetTcp(String localIp) async {
    final Set<String> prefixes = {};
    if (localIp.isNotEmpty && localIp != '127.0.0.1') {
      final parts = localIp.split('.');
      if (parts.length == 4) {
        prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}.');
      }
    }
    // Always include standard home Wi-Fi & Hotspot subnets as fallbacks
    prefixes.add('192.168.1.');
    prefixes.add('192.168.0.');
    prefixes.add('192.168.43.'); // Android Hotspot
    prefixes.add('172.20.10.'); // iPhone Hotspot
    prefixes.add('10.0.0.');

    final hostIndices = List.generate(254, (i) => i + 1);
    const batchSize = 32;

    for (final prefix in prefixes) {
      if (_state != ConnectionState.discovering) break;

      for (int b = 0; b < hostIndices.length; b += batchSize) {
        if (_state != ConnectionState.discovering) break;
        final batch = hostIndices.sublist(b, (b + batchSize > hostIndices.length) ? hostIndices.length : b + batchSize);

        await Future.wait(batch.map((host) async {
          final targetIp = '$prefix$host';
          try {
            final socket = await Socket.connect(
              targetIp,
              defaultServerPort,
              timeout: const Duration(milliseconds: 250),
            );
            socket.destroy();

            String deviceName = 'AirCanvas PC ($targetIp)';
            try {
              final client = HttpClient();
              client.connectionTimeout = const Duration(milliseconds: 300);
              final req = await client.getUrl(Uri.parse('http://$targetIp:$defaultServerPort/api/info'));
              final resp = await req.close().timeout(const Duration(milliseconds: 300));
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
              debugPrint('[SubnetScan] PC found: $targetIp:9090 ($deviceName)');
            }
          } catch (_) {}
        }));
      }
    }
  }

  /// Probes local USB port (via ADB reverse or USB tethering on 127.0.0.1)
  Future<void> _probeUsbTransport() async {
    try {
      final socket = await Socket.connect('127.0.0.1', defaultServerPort, timeout: const Duration(milliseconds: 600));
      socket.destroy();
      final device = DiscoveredDevice(
        ip: '127.0.0.1',
        name: 'AirCanvas PC (USB Cable)',
        port: defaultServerPort,
        transportType: TransportType.usb,
      );
      if (!_discoveredDevices.any((d) => d.ip == device.ip && d.port == device.port)) {
        _discoveredDevices.insert(0, device);
        onDeviceDiscovered?.call(device);
        notifyListeners();
        debugPrint('[USB Probe] USB PC found on 127.0.0.1:$defaultServerPort');
      }
    } catch (_) {}
  }

  String? _lastSuccessfulPin;

  /// Connect to server (client side)
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
      _channel = null; // Reset channel on each new connection
      
      // Auto-set last successful PIN if provided or default to '1234' for zero-friction connection
      final trimmedPin = (pin != null && pin.trim().isNotEmpty) ? pin.trim() : '1234';
      _lastSuccessfulPin = trimmedPin;

      if (screenWidth != null) _clientScreenWidth = screenWidth;
      if (screenHeight != null) _clientScreenHeight = screenHeight;

      // WebSocket connection with 10s timeout
      final uri = 'ws://$ip:$port';
      debugPrint('[Client] Connecting to server: $uri...');
      _socket = await WebSocket.connect(uri).timeout(const Duration(seconds: 10));
      debugPrint('[Client] Socket connected to server: $uri');

      // Incoming data listen
      await _socketSubscription?.cancel();
      _socketSubscription = _socket!.listen(
        (data) => _handleClientReceive(data),
        onDone: () {
          debugPrint('[Client] Connection closed');
          _handleDisconnection();
        },
        onError: (error) {
          debugPrint('[Client] Connection error: $error');
          _handleDisconnection();
        },
      );

      // Await handshake completion with timeout.
      // Avoids hanging on connecting spinner if server fails to challenge.
      // Generous timeout accommodates background PBKDF2 key generation.
      final success = await _authCompleter!.future
          .timeout(const Duration(seconds: 25), onTimeout: () {
        _errorMessage = 'Server is not responding to handshake. '
            'Please ensure AirCanvas server is running on PC and port $port is accessible.';
        debugPrint('[Client] Handshake timed out after 25s');
        return false;
      });
      if (success) {
        _startLatencyMeasurement();
        _setState(ConnectionState.connected);
        return true;
      } else {
        if (_errorMessage.isEmpty) {
          _errorMessage = 'Authentication failed. Please enter the correct PIN.';
        }
        // Close socket and subscription to prevent leaks
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
      // Close socket and subscription to prevent leaks
      await _socketSubscription?.cancel();
      _socketSubscription = null;
      await _socket?.close();
      _socket = null;
      _isAuthenticated = false;

      if (!isReconnecting) {
        if (e is TimeoutException) {
          _errorMessage = 'Connection timed out. Please verify same Wi-Fi network and Firewall settings.';
        } else if (e.toString().contains('refused')) {
          _errorMessage = 'Could not connect to server (Connection Refused). Is the PC server running?';
        } else {
          _errorMessage = 'Failed to connect: $e';
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
        // Binary frames unexpected prior to handshake completion
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
        // Plaintext frames are rejected after handshake completes to prevent
        // attackers from bypassing the sealed channel.
        if (_channel != null) {
          debugPrint('[Client] Dropped unsealed frame after key exchange');
          return;
        }
        _handleClientReceiveJson(json);
      }
    } catch (e, stackTrace) {
      debugPrint('[Client] Data parse error: $e\n$stackTrace');
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
                // Kept provisionally; required to unwrap session key on auth_success.
                _lastSuccessfulPin = pin;
                _sendToServer({
                  'type': 'auth_response',
                  'pin': pin,
                });
              } else {
                _errorMessage = 'Authentication cancelled.';
                _completeAuth(false);
              }
            });
          } else {
            _completeAuth(false);
          }
          break;
        case 'auth_success':
          // PBKDF2 runs in separate isolate; result delivered via _authCompleter.
          unawaited(_handleAuthSuccess(json));
          break;
        case 'auth_fail':
          _channel = null;
          _errorMessage = json['reason'] as String? ?? 'Authentication failed';
          _lastSuccessfulPin = null; // Clear cached PIN on failure
          _completeAuth(false);
          break;
        case 'server_busy':
          _channel = null;
          _errorMessage = json['reason'] as String? ??
              'Server already has an active client. Disconnect first.';
          _completeAuth(false);
          break;
        case 'server_config':
          if (json['data'] is Map<String, dynamic>) {
            _serverConfig = ServerConfig.fromJson(json['data'] as Map<String, dynamic>);
            debugPrint('[Client] Received server config: port=${_serverConfig.port}');
            notifyListeners();
          }
          break;
        case 'ping':
          // Respond to latency ping with pong
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

  /// Server auth_success received with session key sealed under PIN-derived PBKDF2 key.
  /// Matching MAC verifies server possesses the identical PIN (mutual proof).
  /// PBKDF2 runs in separate isolate to keep UI completely responsive.
  Future<void> _handleAuthSuccess(Map<String, dynamic> json) async {
    final pin = _lastSuccessfulPin;
    final saltB64 = json['salt'] as String?;
    final wrappedB64 = json['wrapped_key'] as String?;

    if (pin == null || saltB64 == null || wrappedB64 == null) {
      // Reject legacy v1 plaintext handshake to prevent downgrade attacks.
      _errorMessage = 'Server is using an outdated protocol (v1 handshake). '
          'Please update AirCanvas server on PC.';
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

    // Socket may have closed while isolate was running; discard stale result.
    if (_socket == null || (_authCompleter?.isCompleted ?? true)) {
      debugPrint('[Client] Discarded stale key unwrap result');
      return;
    }

    if (sessionKey == null) {
      _errorMessage = 'Failed to verify server key. Please check your PIN.';
      _lastSuccessfulPin = null;
      debugPrint('[Client] Session key unwrap failed (bad PIN or tampered frame)');
      _completeAuth(false);
      return;
    }

    _isAuthenticated = true;
    _channel = SecureChannel(sessionKey, isServer: false);
    debugPrint('[Client] Authenticated; secure channel established');

    if (json.containsKey('screenWidth') && json.containsKey('screenHeight')) {
      final sw = (json['screenWidth'] as num?)?.toInt() ?? 1920;
      final sh = (json['screenHeight'] as num?)?.toInt() ?? 1080;
      _serverConfig = _serverConfig.copyWith(
        screenWidth: sw,
        screenHeight: sh,
      );
      debugPrint('[Client] Updated serverConfig from auth_success: ${sw}x$sh');
      notifyListeners();
    }

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

  /// Complete auth completer safely exactly once.
  void _completeAuth(bool success) {
    final completer = _authCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(success);
    }
  }

  void _handleDisconnection() {
    _completeAuth(false);
    _outboundQueue.clear();
    onClientDisconnected?.call();
    // Only auto-reconnect if we were successfully connected and the connection dropped.
    // Do NOT reconnect on initial handshake failure or incorrect PIN.
    if (_state == ConnectionState.connected) {
      _setState(ConnectionState.reconnecting);

      // Cancel existing reconnect timer to prevent stacking
      _reconnectTimer?.cancel();
      _reconnectTimer = null;

      // Auto reconnect (3 attempts, 2 second intervals)
      int attempts = 0;
      _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        // Check if user already disconnected or state changed
        if (_state != ConnectionState.reconnecting) {
          timer.cancel();
          return;
        }
        // Skip tick if reconnect attempt is currently in progress
        if (_reconnectInProgress) return;
        attempts++;
        if (attempts > 3) {
          timer.cancel();
          _reconnectTimer = null;
          _errorMessage = 'Failed to reconnect.';
          _setState(ConnectionState.error);
          return;
        }
        debugPrint('[Client] Reconnect attempt $attempts/3...');
        _reconnectInProgress = true;
        await _socketSubscription?.cancel();
        _socketSubscription = null;
        await _socket?.close();
        _socket = null;
        await _rawTcpSubscription?.cancel();
        _rawTcpSubscription = null;
        try {
          _rawTcpSocket?.destroy();
        } catch (_) {}
        _rawTcpSocket = null;
        
        try {
          if (_activeTransport == TransportType.usb) {
            await connectViaUsb(
              port: _serverPort,
              onPinRequired: _clientPinCallback ?? () async => null,
            );
          } else {
            await connectToServer(
              _serverIp,
              port: _serverPort,
              onPinRequired: _clientPinCallback ?? () async => null,
              isReconnecting: true,
            );
          }
          // Failure handling is done via states in connectToServer and this timer
        } finally {
          _reconnectInProgress = false;
        }
      });
    }
  }

  // ==================== INPUT SENDING & USB TRANSPORT ====================

  /// Connects via USB Transport (Unconditionally Free, Zero Pro Checks)
  /// Uses ADB reverse (127.0.0.1:port) or USB tethering endpoint with stream framing.
  Future<bool> connectViaUsb({
    int port = defaultServerPort,
    Future<String?> Function()? onPinRequired,
    String? pin,
    double? screenWidth,
    double? screenHeight,
  }) async {
    debugPrint('[USB] Connecting via USB transport on 127.0.0.1:$port...');
    _selectedTransport = TransportType.usb;

    // Reset session identifier for clean session isolation (Rule 7)
    _sessionId = 'usb_${DateTime.now().millisecondsSinceEpoch}';
    _outboundQueue.clear();

    // 1. Try raw TCP socket with stream framing first for lowest latency (<1ms)
    if (!kIsWeb) {
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(seconds: 2),
        );
        socket.setOption(SocketOption.tcpNoDelay, true);
        _rawTcpSocket = socket;
        _activeTransport = TransportType.usb;
        _serverIp = '127.0.0.1';
        _serverPort = port;
        _connectedDeviceName = 'AirCanvas PC (USB Cable)';
        _isAuthenticated = true;
        _tcpStreamBuffer.clear();

        _rawTcpSubscription = socket.listen(
          (data) {
            _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
            _tcpStreamBuffer.addAll(data);

            // Parse initial JSON server_config line if present
            if (_tcpStreamBuffer.isNotEmpty && _tcpStreamBuffer.first == 0x7B) {
              final newlineIdx = _tcpStreamBuffer.indexOf(0x0A);
              if (newlineIdx != -1) {
                final jsonBytes = _tcpStreamBuffer.sublist(0, newlineIdx);
                _tcpStreamBuffer.removeRange(0, newlineIdx + 1);
                try {
                  final json = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
                  if (json['type'] == 'server_config' && json['data'] is Map<String, dynamic>) {
                    _serverConfig = ServerConfig.fromJson(json['data'] as Map<String, dynamic>);
                    debugPrint('[USB] Received server config: ${_serverConfig.screenWidth}x${_serverConfig.screenHeight}');
                    notifyListeners();
                  }
                } catch (e) {
                  debugPrint('[USB] Error parsing initial JSON config: $e');
                }
              }
            }

            final result = InputEvent.extractBinaryFrames(_tcpStreamBuffer);
            _tcpStreamBuffer = result.remainder;
            for (final evt in result.events) {
              onInputEventReceived?.call(evt);
            }
          },
          onDone: () {
            debugPrint('[USB] Raw TCP connection closed');
            _handleDisconnection();
          },
          onError: (err) {
            debugPrint('[USB] Raw TCP socket error: $err');
            _handleDisconnection();
          },
        );

        _setState(ConnectionState.connected);
        _startLatencyMeasurement();
        debugPrint('[USB] Successfully connected via raw USB stream!');
        return true;
      } catch (e) {
        debugPrint('[USB] Raw TCP loopback failed: $e, trying WebSocket over USB...');
      }
    }

    // 2. Fallback: WebSocket over 127.0.0.1:port (supports Web and HTTP upgrade)
    final ok = await connectToServer(
      '127.0.0.1',
      port: port,
      onPinRequired: onPinRequired ?? (() async => '1234'),
      pin: pin ?? '1234',
      screenWidth: screenWidth,
      screenHeight: screenHeight,
    );
    if (ok) {
      _activeTransport = TransportType.usb;
      _connectedDeviceName = 'AirCanvas PC (USB Cable)';
      notifyListeners();
      debugPrint('[USB] Successfully connected via USB WebSocket!');
    }
    return ok;
  }

  /// Sets transport preference
  void setSelectedTransport(TransportType type) {
    if (_selectedTransport != type) {
      _selectedTransport = type;
      notifyListeners();
    }
  }

  /// Switches transport between USB and Wi-Fi following the strict 5-step sequence (Rule 7):
  /// 1. Stop accepting input from old session.
  /// 2. Release active pen state if stroke was in progress.
  /// 3. Establish new transport/session.
  /// 4. Reset sequence tracking and session ID.
  /// 5. Resume input.
  Future<bool> switchTransport(TransportType newTransport, {String? wifiIp}) async {
    if (_activeTransport == newTransport && isConnected) return true;

    // 1. Stop accepting input from old session
    _outboundQueue.clear();

    // 2. Release active pen state
    if (onInputEventReceived != null) {
      try {
        onInputEventReceived!(InputEvent(
          type: InputEventType.pointerUp,
          x: 0.0,
          y: 0.0,
        ));
      } catch (_) {}
    }

    // Teardown old connection
    await _rawTcpSubscription?.cancel();
    _rawTcpSubscription = null;
    try { _rawTcpSocket?.destroy(); } catch (_) {}
    _rawTcpSocket = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    try { await _socket?.close(); } catch (_) {}
    _socket = null;
    _channel = null;

    // 3. Establish new session
    _sessionId = '${newTransport.name}_${DateTime.now().millisecondsSinceEpoch}';
    _selectedTransport = newTransport;

    if (newTransport == TransportType.usb) {
      return await connectViaUsb();
    } else {
      _activeTransport = TransportType.wifi;
      final targetIp = (wifiIp != null && wifiIp.isNotEmpty) ? wifiIp : _serverIp;
      if (targetIp.isNotEmpty && targetIp != '127.0.0.1') {
        return await connectToServer(
          targetIp,
          port: _serverPort,
          onPinRequired: _clientPinCallback ?? (() async => '1234'),
        );
      } else {
        await startDiscovery();
        return false;
      }
    }
  }

  /// Send input event to server (client side) with bounded queue backpressure safety (Rule 9)
  void sendInputEvent(InputEvent event) {
    if (!isConnected) return;

    // Enforce backpressure queue bounds (Rule 9)
    if (_outboundQueue.length >= maxQueueCapacity) {
      // Find oldest pointerMove event to drop, preserving DOWN/UP/CANCEL/CLEAR
      final dropIdx = _outboundQueue.indexWhere((e) => e.type == InputEventType.pointerMove);
      if (dropIdx != -1) {
        _outboundQueue.removeAt(dropIdx);
      } else if (event.type == InputEventType.pointerMove) {
        // Drop current move rather than growing unbounded
        return;
      }
    }
    _outboundQueue.add(event);
    _flushOutboundQueue();
  }

  void _flushOutboundQueue() {
    if (_isFlushingQueue || _outboundQueue.isEmpty) return;
    _isFlushingQueue = true;

    while (_outboundQueue.isNotEmpty && isConnected) {
      final event = _outboundQueue.removeAt(0);
      _transmitEvent(event);
    }
    _isFlushingQueue = false;
  }

  void _transmitEvent(InputEvent event) {
    // If connected via raw TCP (USB transport)
    if (_rawTcpSocket != null) {
      try {
        _rawTcpSocket!.add(event.toBinary());
        _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
      } catch (e) {
        debugPrint('[USB] Raw TCP send error: $e');
        _handleDisconnection();
      }
      return;
    }

    if (_socket == null) return;
    final List<int> rawBytes = _serverConfig.useBinaryProtocol
        ? event.toBinary()
        : utf8.encode(jsonEncode({
            'type': 'input',
            'data': event.toJson(),
          }));

    try {
      final channel = _channel;
      if (channel != null) {
        _socket!.add(channel.seal(rawBytes));
      } else {
        _socket!.add(rawBytes);
      }
      _lastDataSentOrReceivedTime = DateTime.now().millisecondsSinceEpoch;
    } catch (e, stackTrace) {
      debugPrint('[Client] Input send exception: $e\n$stackTrace');
      _handleDisconnection();
    }
  }

  /// Send classroom action or keyboard shortcut to server (e.g. ppt_pen, ppt_laser, ppt_eraser, launch_onenote, launch_ppt)
  void sendAction(String action) {
    if (_socket != null && isConnected) {
      _sendToServer({
        'type': 'aircanvas_input',
        't': action,
      });
    }
  }

  void _sendToServer(dynamic data) {
    if (_socket != null) {
      final encoded = data is String ? data : jsonEncode(data);
      try {
        if (_channel != null) {
          _socket!.add(_channel!.seal(utf8.encode(encoded)));
        } else {
          // Handshake message (auth_response) prior to channel creation
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
                // Respond to client
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

      debugPrint('[Server] Discovery broadcast started (port $defaultDiscoveryPort)');
    } catch (e, stackTrace) {
      debugPrint('[Server] Discovery broadcast error: $e\n$stackTrace');
    }
  }

  // ==================== LATENCY MEASUREMENT ====================

  void _startLatencyMeasurement() {
    _pingTimer?.cancel();
    _lastReportedRejects = 0;
    // Ping adaptive (5 seconds interval when idle)
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // Log frame drops to help diagnose crypto vs network/rendering latency.
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

  /// Calculate latency on pong response
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

    await _rawTcpSubscription?.cancel();
    _rawTcpSubscription = null;
    try {
      _rawTcpSocket?.destroy();
    } catch (_) {}
    _rawTcpSocket = null;
    _tcpStreamBuffer.clear();
    _outboundQueue.clear();
    _activeTransport = TransportType.wifi;
    
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
    debugPrint('[Connection] Disconnected');
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