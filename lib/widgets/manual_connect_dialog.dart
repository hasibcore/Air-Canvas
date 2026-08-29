// ম্যানুয়াল কানেক্ট ডায়ালগ - IP ও Port দিয়ে কানেক্ট করা
//
// Bug 143: TextEditingControllers owned by parent (HomeScreen).
// Parent is responsible for disposing them.
import 'package:flutter/material.dart';
import '../services/connection_provider.dart';

class ManualConnectDialog extends StatefulWidget {
  /// Controllers owned by parent — this widget does NOT dispose them (Bug 143)
  final TextEditingController ipController;
  final TextEditingController portController;
  final TextEditingController? pinController;
  final Future<void> Function(String ip, int port, String? pin) onConnect;

  const ManualConnectDialog({
    super.key,
    required this.ipController,
    required this.portController,
    this.pinController,
    required this.onConnect,
  });

  @override
  State<ManualConnectDialog> createState() => _ManualConnectDialogState();
}

class _ManualConnectDialogState extends State<ManualConnectDialog> {
  // Bug 142: Prevents double-tap connect
  bool _isConnecting = false;

  late final TextEditingController _localPinController;
  TextEditingController get _effectivePinController =>
      widget.pinController ?? _localPinController;

  @override
  void initState() {
    super.initState();
    _localPinController = TextEditingController(text: '1234');
  }

  @override
  void dispose() {
    _localPinController.dispose();
    super.dispose();
  }

  // Bug 141: Form key for validation
  final _formKey = GlobalKey<FormState>();

  // Bug 141: IPv4 validation regex
  static final _ipv4Regex = RegExp(
    r'^((25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(25[0-5]|2[0-4]\d|[01]?\d\d?)$',
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFF2A2A4A)),
      ),
      title: const Text(
        'Manual Connect',
        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
      ),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter PC IP, Port, and Pairing PIN shown on the PC screen',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 20),
              // Bug 141: IP field with proper validation
              TextFormField(
                controller: widget.ipController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                enabled: !_isConnecting,
                validator: _validateIp,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: _inputDecoration(
                  label: 'Server IP',
                  hint: '192.168.1.10',
                ),
              ),
              const SizedBox(height: 12),
              // Bug 141: Port field with range validation
              TextFormField(
                controller: widget.portController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                enabled: !_isConnecting,
                validator: _validatePort,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: _inputDecoration(
                  label: 'Port',
                  hint: ConnectionProvider.defaultServerPort.toString(),
                ),
              ),
              const SizedBox(height: 12),
              // PIN field directly in dialog
              TextFormField(
                controller: _effectivePinController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white, letterSpacing: 4, fontWeight: FontWeight.bold),
                enabled: !_isConnecting,
                maxLength: 6,
                decoration: _inputDecoration(
                  label: 'Pairing PIN (6 Digits)',
                  hint: '123456',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        // Bug 149: Semantic labels for accessibility
        Semantics(
          label: 'Cancel connection',
          child: TextButton(
            onPressed: _isConnecting ? null : () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
        ),
        // Bug 142: Button fully disabled while connecting
        Semantics(
          label: 'Connect to server',
          child: ElevatedButton(
            onPressed: _isConnecting ? null : _connect,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6C63FF),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _isConnecting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Text('Connect'),
          ),
        ),
      ],
    );
  }

  // Bug 141: IPv4 format validation
  String? _validateIp(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'IP address required';
    }
    if (!_ipv4Regex.hasMatch(value.trim())) {
      return 'Invalid IPv4 format (e.g. 192.168.1.100)';
    }
    return null;
  }

  // Bug 141: Port range validation (1–65535)
  String? _validatePort(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Port required';
    }
    final port = int.tryParse(value.trim());
    if (port == null || port < 1 || port > 65535) {
      return 'Port must be 1–65535';
    }
    return null;
  }

  // Bug 142: Guarded connect with form validation
  Future<void> _connect() async {
    // Bug 142: Early exit if already connecting
    if (_isConnecting) return;

    // Bug 141: Validate form before proceeding
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final ip = widget.ipController.text.trim();
    final port = int.tryParse(widget.portController.text.trim())
        ?? ConnectionProvider.defaultServerPort;
    final pin = _effectivePinController.text.trim();

    setState(() => _isConnecting = true);
    try {
      await widget.onConnect(ip, port, pin.isEmpty ? null : pin);
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  // Shared InputDecoration builder
  InputDecoration _inputDecoration({
    required String label,
    String? hint,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: Colors.grey.shade400),
      hintText: hint,
      hintStyle: TextStyle(color: Colors.grey.shade600),
      filled: true,
      fillColor: const Color(0xFF0F0F1A),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF2A2A4A)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF2A2A4A)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF6C63FF)),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.red.shade400),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.red.shade400),
      ),
      errorStyle: TextStyle(color: Colors.red.shade300, fontSize: 11),
    );
  }
}