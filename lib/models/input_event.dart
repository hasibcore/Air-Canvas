/// ইনপুট ইভেন্ট মডেল - মোবাইল থেকে পিসিতে পাঠানোর জন্য

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
}

class InputEvent {
  static const int binaryPacketLength = 11;

  final InputEventType type;
  final double x;          // normalized 0.0 - 1.0
  final double y;          // normalized 0.0 - 1.0
  final double pressure;   // 0.0 - 1.0 (stylus) or 0.0/1.0 (finger)
  final PointerType pointerType;
  final int pointerId;     // multi-touch support
  final double tiltX;      // stylus tilt (degrees, -90 to 90)
  final double tiltY;      // stylus tilt (degrees, -90 to 90)
  final int buttons;       // button state bitmask (1=primary, 2=secondary, 4=middle)
  final DateTime timestamp;

  InputEvent({
    required this.type,
    required this.x,
    required this.y,
    this.pressure = 0.0,
    this.pointerType = PointerType.finger,
    this.pointerId = 0,
    this.tiltX = 0.0,
    this.tiltY = 0.0,
    this.buttons = 0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// JSON এ কনভার্ট করে WebSocket এ পাঠানোর জন্য
  Map<String, dynamic> toJson() => {
    't': type.index,
    'x': x,
    'y': y,
    'p': pressure,
    'pt': pointerType.index,
    'id': pointerId,
    'tx': tiltX,
    'ty': tiltY,
    'b': buttons,
    'ts': timestamp.millisecondsSinceEpoch,
  };

  /// JSON থেকে InputEvent তৈরি (server side receive)
  factory InputEvent.fromJson(Map<String, dynamic> json) => InputEvent(
    type: InputEventType.values[json['t'] as int],
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    pressure: (json['p'] as num?)?.toDouble() ?? 0.0,
    pointerType: PointerType.values[json['pt'] as int? ?? 0],
    pointerId: json['id'] as int? ?? 0,
    tiltX: (json['tx'] as num?)?.toDouble() ?? 0.0,
    tiltY: (json['ty'] as num?)?.toDouble() ?? 0.0,
    buttons: json['b'] as int? ?? 0,
    timestamp: json['ts'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['ts'] as int)
        : DateTime.now(),
  );

  /// Binary format for ultra-low-latency mode (12 bytes per event)
  /// Format: [type:1][x:2][y:2][pressure:1][pointerType:1][pointerId:1][tiltX:1][tiltY:1][buttons:1][reserved:1]
  List<int> toBinary() {
    return [
      type.index,
      ..._floatToUint16(x),
      ..._floatToUint16(y),
      (pressure * 255).round().clamp(0, 255),
      pointerType.index,
      pointerId.clamp(0, 255),
      ((tiltX + 90) / 180 * 255).round().clamp(0, 255),
      ((tiltY + 90) / 180 * 255).round().clamp(0, 255),
      buttons.clamp(0, 255),
      0, // reserved
    ];
  }

  static InputEvent fromBinary(List<int> data) {
    return InputEvent(
      type: InputEventType.values[data[0]],
      x: _uint16ToFloat(data[1], data[2]),
      y: _uint16ToFloat(data[3], data[4]),
      pressure: data[5] / 255.0,
      pointerType: PointerType.values[data[6]],
      pointerId: data[7],
      tiltX: (data[8] / 255.0 * 180) - 90,
      tiltY: (data[9] / 255.0 * 180) - 90,
      buttons: data[10],
    );
  }

  static List<int> _floatToUint16(double value) {
    final clamped = value.clamp(0.0, 1.0);
    final intVal = (clamped * 65535).round();
    return [intVal >> 8, intVal & 0xFF];
  }

  static double _uint16ToFloat(int high, int low) {
    return ((high << 8) | low) / 65535.0;
  }

  @override
  String toString() =>
      'InputEvent(${type.name}, x=${x.toStringAsFixed(3)}, y=${y.toStringAsFixed(3)}, '
      'pressure=${pressure.toStringAsFixed(2)}, ${pointerType.name})';
}

/// ডিভাইস ইনফো - ক্লায়েন্ট কানেক্ট করার সময় পাঠায়
class DeviceInfo {
  final String deviceName;
  final String deviceModel;
  final String platform;      // android / ios / windows
  final double screenWidth;
  final double screenHeight;
  final bool hasStylusSupport;
  final double maxPressure;

  DeviceInfo({
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
    deviceName: json['deviceName'] as String,
    deviceModel: json['deviceModel'] as String,
    platform: json['platform'] as String,
    screenWidth: (json['screenWidth'] as num).toDouble(),
    screenHeight: (json['screenHeight'] as num).toDouble(),
    hasStylusSupport: json['hasStylus'] as bool? ?? false,
    maxPressure: (json['maxPressure'] as num?)?.toDouble() ?? 1.0,
  );
}

/// সার্ভার কনফিগারেশন - কানেকশন স্থাপনের সময় এক্সচেঞ্জ হয়
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
}