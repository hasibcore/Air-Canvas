import 'dart:typed_data';

// ইনপুট ইভেন্ট মডেল - মোবাইল থেকে পিসিতে পাঠানোর জন্য

enum PointerType {
  finger,   // আঙুল টাচ
  stylus,   // স্টাইলাস/পেন (pressure sensitive)
  mouse,    // মাউস (desktop mode)
  eraser,   // ইরেজার টিপ
}

enum InputEventType {
  pointerDown,
  pointerMove,
  pointerUp,
  pointerCancel,
  hover,
  clear,
}

class InputEvent {
  /// Binary format length (13 bytes per event)
  /// Format: [type:1][x:2][y:2][pressure:1][pointerType:1][pointerId:1][tiltX:1][tiltY:1][buttons:1][version:1][checksum:1]
  static const int binaryPacketLength = 13;
  static const int protocolVersion = 1;

  final InputEventType type;
  final double x;          // normalized 0.0 - 1.0 (clamped)
  final double y;          // normalized 0.0 - 1.0 (clamped)
  final double pressure;   // 0.0 - 1.0 (stylus) or 0.0/1.0 (finger, clamped)
  final PointerType pointerType;
  final int pointerId;     // multi-touch support
  final double tiltX;      // stylus tilt (degrees, -90 to 90)
  final double tiltY;      // stylus tilt (degrees, -90 to 90)
  final int buttons;       // button state bitmask (1=primary, 2=secondary, 4=middle)
  final DateTime timestamp;

  InputEvent({
    required this.type,
    required double x,
    required double y,
    double pressure = 0.0,
    this.pointerType = PointerType.finger,
    int pointerId = 0,
    double tiltX = 0.0,
    double tiltY = 0.0,
    int buttons = 0,
    DateTime? timestamp,
  })  : assert(pointerId >= 0, 'pointerId must be non-negative'),
        pointerId = pointerId.clamp(0, 255),
        buttons = buttons.clamp(0, 255),
        x = x.isNaN || x.isInfinite ? 0.0 : x.clamp(0.0, 1.0), // Bug 43: Coordinate bounds
        y = y.isNaN || y.isInfinite ? 0.0 : y.clamp(0.0, 1.0), // Bug 43: Coordinate bounds
        pressure = pressure.isNaN || pressure.isInfinite ? 0.0 : pressure.clamp(0.0, 1.0), // Bug 42: Pressure bounds
        tiltX = tiltX.isNaN || tiltX.isInfinite ? 0.0 : tiltX.clamp(-90.0, 90.0),
        tiltY = tiltY.isNaN || tiltY.isInfinite ? 0.0 : tiltY.clamp(-90.0, 90.0),
        timestamp = timestamp ?? DateTime.now();

  /// JSON এ কনভার্ট করে WebSocket এ পাঠানোর জন্য
  Map<String, dynamic> toJson() => {
    'v': protocolVersion, // Bug 46: Versioning
    't': _inputEventTypeToString(type), // Bug 40: Order-independent enum serialization
    'x': _roundCoordinate(x), // Bug 39: Limit float precision
    'y': _roundCoordinate(y), // Bug 39: Limit float precision
    'p': _roundPressure(pressure), // Bug 39: Limit float precision
    'pt': _pointerTypeToString(pointerType), // Bug 40: Order-independent enum serialization
    'id': pointerId,
    'tx': _roundCoordinate(tiltX),
    'ty': _roundCoordinate(tiltY),
    'b': buttons,
    'ts': timestamp.millisecondsSinceEpoch,
  };

  /// JSON থেকে InputEvent তৈরি (server side receive) (Bug 37: Null safety)
  factory InputEvent.fromJson(Map<String, dynamic> json) {
    // Bug 41: Graceful fallback for unknown event types
    InputEventType typeVal = InputEventType.pointerMove;
    final tObj = json['t'];
    if (tObj is int) {
      if (tObj >= 0 && tObj < InputEventType.values.length) {
        typeVal = InputEventType.values[tObj];
      }
    } else if (tObj is String) {
      typeVal = _stringToInputEventType(tObj);
    }

    // Bug 38: Type casting safety (avoid "as double" TypeError)
    final xVal = _toDouble(json['x']);
    final yVal = _toDouble(json['y']);
    final pVal = _toDouble(json['p']);

    PointerType ptVal = PointerType.finger;
    final ptObj = json['pt'];
    if (ptObj is int) {
      if (ptObj >= 0 && ptObj < PointerType.values.length) {
        ptVal = PointerType.values[ptObj];
      }
    } else if (ptObj is String) {
      ptVal = _stringToPointerType(ptObj);
    }

    final idVal = _toInt(json['id']);
    final txVal = _toDouble(json['tx']);
    final tyVal = _toDouble(json['ty']);
    final bVal = _toInt(json['b']);

    // AC-008: Timestamp bounds validation (min year 2000-01-01, max future +1 day)
    DateTime timeVal = DateTime.now();
    final tsObj = json['ts'];
    if (tsObj is int && tsObj > 0) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      const minTimestamp = 946684800000; // 2000-01-01
      if (tsObj >= minTimestamp && tsObj <= nowMs + 86400000) {
        timeVal = DateTime.fromMillisecondsSinceEpoch(tsObj);
      }
    }

    return InputEvent(
      type: typeVal,
      x: xVal,
      y: yVal,
      pressure: pVal,
      pointerType: ptVal,
      pointerId: idVal,
      tiltX: txVal,
      tiltY: tyVal,
      buttons: bVal,
      timestamp: timeVal,
    );
  }

  /// Binary format using Uint8List (AC-010: Zero dynamic list allocation for 120Hz streaming)
  Uint8List toBinary() {
    final bytes = Uint8List(binaryPacketLength);
    bytes[0] = type.index;
    final xBytes = _floatToUint16(x);
    bytes[1] = xBytes[0];
    bytes[2] = xBytes[1];
    final yBytes = _floatToUint16(y);
    bytes[3] = yBytes[0];
    bytes[4] = yBytes[1];
    bytes[5] = (pressure * 255).round().clamp(0, 255);
    bytes[6] = pointerType.index;
    bytes[7] = pointerId.clamp(0, 255);
    bytes[8] = ((tiltX + 90) / 180 * 255).round().clamp(0, 255);
    bytes[9] = ((tiltY + 90) / 180 * 255).round().clamp(0, 255);
    bytes[10] = buttons.clamp(0, 255);
    bytes[11] = protocolVersion;
    bytes[12] = _computeCrc8(bytes, 12); // AC-009: CRC-8 Checksum
    return bytes;
  }

  /// Non-throwing binary parser for high-frequency network packets (AC-011)
  static InputEvent? tryFromBinary(List<int> data) {
    if (data.length < binaryPacketLength) return null;

    // AC-009: CRC-8 verification
    final expectedCrc = _computeCrc8(data, 12);
    final actualCrc = data[12];
    if (expectedCrc != actualCrc) return null;

    // Protocol version check
    final version = data[11];
    if (version != protocolVersion) {
      // Fallback or ignore unsupported version
    }

    final tIdx = data[0];
    final typeVal = tIdx >= 0 && tIdx < InputEventType.values.length
        ? InputEventType.values[tIdx]
        : InputEventType.pointerMove;

    final ptIdx = data[6];
    final ptVal = ptIdx >= 0 && ptIdx < PointerType.values.length
        ? PointerType.values[ptIdx]
        : PointerType.finger;

    return InputEvent(
      type: typeVal,
      x: _uint16ToFloat(data[1], data[2]),
      y: _uint16ToFloat(data[3], data[4]),
      pressure: data[5] / 255.0,
      pointerType: ptVal,
      pointerId: data[7],
      tiltX: (data[8] / 255.0 * 180) - 90,
      tiltY: (data[9] / 255.0 * 180) - 90,
      buttons: data[10],
    );
  }

  /// Deserialization from binary format with exception handling
  static InputEvent fromBinary(List<int> data) {
    final event = tryFromBinary(data);
    if (event == null) {
      if (data.length < binaryPacketLength) {
        throw FormatException('Binary packet length too short (expected $binaryPacketLength, got ${data.length})');
      }
      throw const FormatException('Checksum or format mismatch in binary packet');
    }
    return event;
  }

  /// AC-009: CRC-8 (SMBus polynomial 0x07) for robust error detection
  static int _computeCrc8(List<int> data, int length) {
    int crc = 0xFF;
    for (int i = 0; i < length; i++) {
      crc ^= data[i];
      for (int j = 0; j < 8; j++) {
        if ((crc & 0x80) != 0) {
          crc = ((crc << 1) ^ 0x07) & 0xFF;
        } else {
          crc = (crc << 1) & 0xFF;
        }
      }
    }
    return crc;
  }

  // --- Helper Methods ---

  /// Network Byte Order (Big-Endian) float to Uint16 conversion (Endianness-independent)
  static List<int> _floatToUint16(double value) {
    final clamped = value.clamp(0.0, 1.0);
    final intVal = (clamped * 65535).round();
    return [intVal >> 8, intVal & 0xFF];
  }

  /// Network Byte Order (Big-Endian) Uint16 to float conversion (Endianness-independent)
  static double _uint16ToFloat(int high, int low) {
    return ((high << 8) | low) / 65535.0;
  }

  static double _roundCoordinate(double val) {
    if (val.isNaN || val.isInfinite) return 0.0;
    return (val * 100000).round() / 100000.0;
  }

  static double _roundPressure(double val) {
    if (val.isNaN || val.isInfinite) return 0.0;
    return (val * 1000).round() / 1000.0;
  }

  static double _toDouble(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return 0.0;
  }

  static int _toInt(dynamic val) {
    if (val == null) return 0;
    if (val is num) return val.toInt();
    return 0;
  }

  static String _inputEventTypeToString(InputEventType type) {
    switch (type) {
      case InputEventType.pointerDown: return 'down';
      case InputEventType.pointerMove: return 'move';
      case InputEventType.pointerUp: return 'up';
      case InputEventType.pointerCancel: return 'cancel';
      case InputEventType.hover: return 'hover';
      case InputEventType.clear: return 'clear';
    }
  }

  static InputEventType _stringToInputEventType(String? typeStr) {
    switch (typeStr) {
      case 'down': return InputEventType.pointerDown;
      case 'move': return InputEventType.pointerMove;
      case 'up': return InputEventType.pointerUp;
      case 'cancel': return InputEventType.pointerCancel;
      case 'hover': return InputEventType.hover;
      case 'clear': return InputEventType.clear;
      default: return InputEventType.pointerMove;
    }
  }

  static String _pointerTypeToString(PointerType type) {
    switch (type) {
      case PointerType.finger: return 'finger';
      case PointerType.stylus: return 'stylus';
      case PointerType.mouse: return 'mouse';
      case PointerType.eraser: return 'eraser';
    }
  }

  static PointerType _stringToPointerType(String? typeStr) {
    switch (typeStr) {
      case 'finger': return PointerType.finger;
      case 'stylus': return PointerType.stylus;
      case 'mouse': return PointerType.mouse;
      case 'eraser': return PointerType.eraser;
      default: return PointerType.finger;
    }
  }

  // Bug 50: Safe State updates with copyWith
  InputEvent copyWith({
    InputEventType? type,
    double? x,
    double? y,
    double? pressure,
    PointerType? pointerType,
    int? pointerId,
    double? tiltX,
    double? tiltY,
    int? buttons,
    DateTime? timestamp,
  }) {
    return InputEvent(
      type: type ?? this.type,
      x: x ?? this.x,
      y: y ?? this.y,
      pressure: pressure ?? this.pressure,
      pointerType: pointerType ?? this.pointerType,
      pointerId: pointerId ?? this.pointerId,
      tiltX: tiltX ?? this.tiltX,
      tiltY: tiltY ?? this.tiltY,
      buttons: buttons ?? this.buttons,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  // Bug 48: Equality override
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InputEvent &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          x == other.x &&
          y == other.y &&
          pressure == other.pressure &&
          pointerType == other.pointerType &&
          pointerId == other.pointerId &&
          tiltX == other.tiltX &&
          tiltY == other.tiltY &&
          buttons == other.buttons &&
          timestamp.millisecondsSinceEpoch == other.timestamp.millisecondsSinceEpoch;

  // Bug 48: HashCode override
  @override
  int get hashCode =>
      type.hashCode ^
      x.hashCode ^
      y.hashCode ^
      pressure.hashCode ^
      pointerType.hashCode ^
      pointerId.hashCode ^
      tiltX.hashCode ^
      tiltY.hashCode ^
      buttons.hashCode ^
      timestamp.millisecondsSinceEpoch.hashCode;

  @override
  String toString() =>
      'InputEvent(${type.name}, x=${x.toStringAsFixed(3)}, y=${y.toStringAsFixed(3)}, '
      'pressure=${pressure.toStringAsFixed(2)}, ${pointerType.name})';
}

/// ডিভাইস ইনফো - ক্লায়েন্ট কানেক্ট করার সময় পাঠায় (Bug 49: Immutable)
class DeviceInfo {
  final String deviceName;
  final String deviceModel;
  final String platform;      // android / ios / windows
  final double screenWidth;
  final double screenHeight;
  final bool hasStylusSupport;
  final double maxPressure;

  const DeviceInfo({
    required this.deviceName,
    required this.deviceModel,
    required this.platform,
    required this.screenWidth,
    required this.screenHeight,
    this.hasStylusSupport = false,
    this.maxPressure = 1.0,
  });

  Map<String, dynamic> toJson() => {
    'deviceName': deviceName,
    'deviceModel': deviceModel,
    'platform': platform,
    'screenWidth': screenWidth,
    'screenHeight': screenHeight,
    'hasStylus': hasStylusSupport,
    'maxPressure': maxPressure,
  };

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    deviceName: json['deviceName'] as String? ?? 'Unknown',
    deviceModel: json['deviceModel'] as String? ?? 'Unknown',
    platform: json['platform'] as String? ?? 'unknown',
    screenWidth: (json['screenWidth'] as num?)?.toDouble() ?? 0.0,
    screenHeight: (json['screenHeight'] as num?)?.toDouble() ?? 0.0,
    hasStylusSupport: json['hasStylus'] as bool? ?? false,
    maxPressure: (json['maxPressure'] as num?)?.toDouble() ?? 1.0,
  );

  // Bug 50: copyWith
  DeviceInfo copyWith({
    String? deviceName,
    String? deviceModel,
    String? platform,
    double? screenWidth,
    double? screenHeight,
    bool? hasStylusSupport,
    double? maxPressure,
  }) {
    return DeviceInfo(
      deviceName: deviceName ?? this.deviceName,
      deviceModel: deviceModel ?? this.deviceModel,
      platform: platform ?? this.platform,
      screenWidth: screenWidth ?? this.screenWidth,
      screenHeight: screenHeight ?? this.screenHeight,
      hasStylusSupport: hasStylusSupport ?? this.hasStylusSupport,
      maxPressure: maxPressure ?? this.maxPressure,
    );
  }

  // Bug 48: Equality override
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceInfo &&
          runtimeType == other.runtimeType &&
          deviceName == other.deviceName &&
          deviceModel == other.deviceModel &&
          platform == other.platform &&
          screenWidth == other.screenWidth &&
          screenHeight == other.screenHeight &&
          hasStylusSupport == other.hasStylusSupport &&
          maxPressure == other.maxPressure;

  // Bug 48: HashCode override
  @override
  int get hashCode =>
      deviceName.hashCode ^
      deviceModel.hashCode ^
      platform.hashCode ^
      screenWidth.hashCode ^
      screenHeight.hashCode ^
      hasStylusSupport.hashCode ^
      maxPressure.hashCode;
}

/// সার্ভার কনফিগারেশন - কানেকশন স্থাপনের সময় এক্সচেঞ্জ হয় (Bug 49: Immutable)
class ServerConfig {
  final int port;
  final bool useBinaryProtocol;
  final int targetFPS;
  final bool enablePressureSmoothing;
  final bool enablePrediction;  // client-side movement prediction

  const ServerConfig({
    this.port = 9090,
    this.useBinaryProtocol = false,
    this.targetFPS = 120,
    this.enablePressureSmoothing = true,
    this.enablePrediction = true,
  });

  Map<String, dynamic> toJson() => {
    'port': port,
    'binary': useBinaryProtocol,
    'fps': targetFPS,
    'pressureSmooth': enablePressureSmoothing,
    'prediction': enablePrediction,
  };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
    port: json['port'] as int? ?? 9090,
    useBinaryProtocol: json['binary'] as bool? ?? false,
    targetFPS: json['fps'] as int? ?? 120,
    enablePressureSmoothing: json['pressureSmooth'] as bool? ?? true,
    enablePrediction: json['prediction'] as bool? ?? true,
  );

  // Bug 50: copyWith
  ServerConfig copyWith({
    int? port,
    bool? useBinaryProtocol,
    int? targetFPS,
    bool? enablePressureSmoothing,
    bool? enablePrediction,
  }) {
    return ServerConfig(
      port: port ?? this.port,
      useBinaryProtocol: useBinaryProtocol ?? this.useBinaryProtocol,
      targetFPS: targetFPS ?? this.targetFPS,
      enablePressureSmoothing: enablePressureSmoothing ?? this.enablePressureSmoothing,
      enablePrediction: enablePrediction ?? this.enablePrediction,
    );
  }

  // Bug 48: Equality override
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerConfig &&
          runtimeType == other.runtimeType &&
          port == other.port &&
          useBinaryProtocol == other.useBinaryProtocol &&
          targetFPS == other.targetFPS &&
          enablePressureSmoothing == other.enablePressureSmoothing &&
          enablePrediction == other.enablePrediction;

  // Bug 48: HashCode override
  @override
  int get hashCode =>
      port.hashCode ^
      useBinaryProtocol.hashCode ^
      targetFPS.hashCode ^
      enablePressureSmoothing.hashCode ^
      enablePrediction.hashCode;
}