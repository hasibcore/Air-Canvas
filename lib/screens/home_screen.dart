// হোম স্ক্রিন - সার্ভার/ক্লায়েন্ট মোড সিলেক্ট ও কানেকশন ম্যানেজমেন্ট
//
// এই স্ক্রিন থেকে ইউজার:
// 1. পিসিতে সার্ভার শুরু করতে পারে
// 2. মোবাইল থেকে সার্ভার খুঁজে কানেক্ট করতে পারে
// 3. ম্যানুয়ালি IP দিয়ে কানেক্ট করতে পারে

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/connection_provider.dart';
import '../services/drawing_provider.dart';
import 'drawing_screen.dart';
import '../widgets/connection_status_bar.dart';
import '../widgets/device_list_tile.dart';
import '../widgets/manual_connect_dialog.dart';

// Bug 140: Localization-ready app constants
const String kAppName = 'Air Canvas';
const String kAppTagline = 'Wireless Graphics Tablet';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _ipController = TextEditingController();
  // Bug 138: Use constant instead of hardcoded port
  final TextEditingController _portController = TextEditingController(
    text: ConnectionProvider.defaultServerPort.toString(),
  );

  @override
  void initState() {
    super.initState();
    final isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;

    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: isDesktop ? 0 : 1,
    );

    if (!isDesktop) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _ipController.dispose();
    _portController.dispose();
    // Bug 136: Restore orientation to default on dispose
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  // Bug 137: Granular rebuild with Selector instead of context.watch
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      body: SafeArea(
        child: Selector<ConnectionProvider, ({ConnectionState state, bool isConnected})>(
          selector: (_, cp) => (state: cp.state, isConnected: cp.isConnected),
          builder: (context, sel, _) {
            final connection = context.read<ConnectionProvider>();
            return Column(
              children: [
                // Header — only rebuilds on localIp/pairingPin changes
                Selector<ConnectionProvider, ({String localIp, String? pairingPin})>(
                  selector: (_, cp) => (localIp: cp.localIp, pairingPin: cp.pairingPin),
                  builder: (context, _, __) => _buildHeader(connection),
                ),

                // Connection Status Bar
                const ConnectionStatusBar(),

                // Content
                Expanded(
                  child: sel.isConnected
                      ? _buildConnectedView(connection)
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            _buildServerTab(connection),
                            _buildClientTab(connection),
                          ],
                        ),
                ),

                // Tab Bar
                if (!sel.isConnected)
                  Container(
                    decoration: const BoxDecoration(
                      color: Color(0xFF1A1A2E),
                      border: Border(
                        top: BorderSide(color: Color(0xFF2A2A4A)),
                      ),
                    ),
                    child: TabBar(
                      controller: _tabController,
                      indicatorColor: const Color(0xFF6C63FF),
                      indicatorWeight: 3,
                      labelColor: const Color(0xFF6C63FF),
                      unselectedLabelColor: Colors.grey,
                      tabs: const [
                        Tab(text: 'SERVER (PC)', icon: Icon(Icons.computer)),
                        Tab(text: 'CLIENT (Mobile)', icon: Icon(Icons.phone_android)),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(ConnectionProvider connection) {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF6C63FF).withValues(alpha: 0.3),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    'assets/logo.png',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C63FF).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.draw,
                        color: Color(0xFF6C63FF),
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Bug 140: Use app constants
                    const Text(
                      kAppName,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                    Text(
                      kAppTagline,
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              // Settings button
              IconButton(
                onPressed: () => _showSettings(context),
                icon: const Icon(Icons.settings, color: Colors.grey),
              ),
            ],
          ),
          if (connection.localIp.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2A2A4A)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi, color: Colors.green.shade400, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'Local IP: ${connection.localIp}',
                    style: TextStyle(color: Colors.grey.shade300, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ==================== SERVER TAB ====================
  Widget _buildServerTab(ConnectionProvider connection) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Server status card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF1A1A2E),
                  Color(0xFF16213E),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2A2A4A)),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.computer,
                  size: 48,
                  color: connection.state == ConnectionState.discovering
                      ? Colors.green.shade400
                      : Colors.grey.shade600,
                ),
                const SizedBox(height: 16),
                Text(
                  connection.state == ConnectionState.discovering
                      ? 'Server Running'
                      : connection.state == ConnectionState.connected
                          ? 'Client Connected'
                          : 'Server Offline',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (connection.state == ConnectionState.discovering) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Waiting for device...\n${connection.localIp}:${connection.serverPort}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                  ),
                  if (connection.pairingPin != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C63FF).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF6C63FF).withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'PAIRING PIN',
                            style: TextStyle(
                              color: Colors.grey.shade400,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            connection.pairingPin!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
                if (connection.state == ConnectionState.connected) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade400.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade400.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.phone_android, color: Colors.green.shade400, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                connection.connectedDeviceName,
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                              ),
                              if (connection.remoteDeviceInfo != null)
                                Text(
                                  '${connection.remoteDeviceInfo!.platform.toUpperCase()} - ${connection.remoteDeviceInfo!.screenWidth.toInt()}x${connection.remoteDeviceInfo!.screenHeight.toInt()}',
                                  style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          '${connection.latencyMs}ms',
                          style: TextStyle(color: Colors.green.shade400, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Start/Stop server button
          ElevatedButton(
            onPressed: connection.state == ConnectionState.discovering
                ? () => connection.disconnect()
                : () => connection.startServer(),
            style: ElevatedButton.styleFrom(
              backgroundColor: connection.state == ConnectionState.discovering
                  ? Colors.red.shade400
                  : const Color(0xFF6C63FF),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              connection.state == ConnectionState.discovering
                  ? 'Stop Server'
                  : 'Start Server',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),

          const SizedBox(height: 20),

          // Instructions
          _buildInstructionCard(
            icon: Icons.wifi,
            title: 'Step 1: Same WiFi',
            description: 'PC and mobile must be on the same WiFi network.',
          ),
          const SizedBox(height: 12),
          _buildInstructionCard(
            icon: Icons.play_arrow,
            title: 'Step 2: Start Server',
            description: 'Click "Start Server" on this PC.',
          ),
          const SizedBox(height: 12),
          _buildInstructionCard(
            icon: Icons.phone_android,
            title: 'Step 3: Connect Mobile',
            description: 'On your phone, go to Client tab and connect.',
          ),
          const SizedBox(height: 12),
          _buildInstructionCard(
            icon: Icons.security,
            title: 'Firewall Notice',
            description: 'Allow AirCanvas through Windows Firewall on private networks if prompted.',
          ),
        ],
      ),
    );
  }

  // ==================== CLIENT TAB ====================
  Widget _buildClientTab(ConnectionProvider connection) {
    return Column(
      children: [
        Expanded(
          child: connection.state == ConnectionState.discovering &&
                  connection.mode == ConnectionMode.client
              ? _buildDiscoveryView(connection)
              : connection.discoveredDevices.isNotEmpty
                  ? _buildDeviceListView(connection)
                  : _buildClientIdleView(connection),
        ),

        // Bottom actions
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A2E),
            border: Border(top: BorderSide(color: Color(0xFF2A2A4A))),
          ),
          child: SafeArea(
            child: Row(
              children: [
                // Manual connect
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _showManualConnectDialog(context, connection),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF6C63FF)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Manual Connect',
                      style: TextStyle(color: Color(0xFF6C63FF), fontSize: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Scan button
                Expanded(
                  child: ElevatedButton(
                    onPressed: connection.state == ConnectionState.discovering
                        ? () => connection.stopDiscovery()
                        : () => connection.startDiscovery(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6C63FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          connection.state == ConnectionState.discovering
                              ? Icons.stop
                              : Icons.search,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          connection.state == ConnectionState.discovering
                              ? 'Stop Scan'
                              : 'Scan Devices',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildClientIdleView(ConnectionProvider connection) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: Colors.grey.shade700),
            const SizedBox(height: 16),
            Text(
              'Scan for Devices',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Make sure your PC and phone are\non the same WiFi network',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => connection.startDiscovery(),
              icon: const Icon(Icons.search),
              label: const Text('Start Scanning'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveryView(ConnectionProvider connection) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              color: Color(0xFF6C63FF),
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Scanning network...',
            style: TextStyle(color: Colors.grey.shade300, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'Looking for Air Canvas servers',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceListView(ConnectionProvider connection) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: connection.discoveredDevices.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              'Found ${connection.discoveredDevices.length} device(s)',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
            ),
          );
        }
        final device = connection.discoveredDevices[index - 1];
        final size = MediaQuery.of(context).size;
        return DeviceListTile(
          device: device,
          onTap: () async {
            final success = await connection.connectToServer(
              device.ip,
              port: device.port,
              onPinRequired: () => _promptForPin(context),
              screenWidth: size.width,
              screenHeight: size.height,
            );
            if (success && context.mounted) {
              await Navigator.of(context).pushNamed('/drawing');
            }
          },
        );
      },
    );
  }

  // ==================== CONNECTED VIEW ====================
  Widget _buildConnectedView(ConnectionProvider connection) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 28),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  connection.mode == ConnectionMode.server
                      ? 'Connected: ${connection.connectedDeviceName}'
                      : 'Connected to ${connection.serverIp}',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Live drawing preview canvas for real-time stroke display
          Consumer<DrawingProvider>(
            builder: (context, drawing, _) {
              return Container(
                height: 300,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0A12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF2A2A4A)),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      drawing.updateCanvasSize(constraints.maxWidth, constraints.maxHeight);
                      return Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: DrawingPainter(drawingProvider: drawing),
                              size: Size.infinite,
                            ),
                          ),
                          if (drawing.strokes.isEmpty && drawing.currentStroke == null)
                            Center(
                              child: Text(
                                connection.mode == ConnectionMode.server
                                    ? 'Draw on your tablet/phone to see it live here!'
                                    : 'Touch or stylus drawing mirror',
                                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                              ),
                            ),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.white70, size: 20),
                              tooltip: 'Clear Canvas',
                              onPressed: () => drawing.clearCanvas(),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.of(context).pushNamed('/drawing'),
                  icon: const Icon(Icons.fullscreen),
                  label: const Text('Full Screen Drawing Pad'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => connection.disconnect(),
                icon: const Icon(Icons.link_off, color: Colors.redAccent),
                label: const Text('Disconnect', style: TextStyle(color: Colors.redAccent)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.redAccent),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==================== HELPERS ====================
  Widget _buildInstructionCard({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF6C63FF).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: const Color(0xFF6C63FF), size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 4),
              Text(description, style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }

  Future<String?> _promptForPin(BuildContext context) async {
    final TextEditingController pinController = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Enter Pairing PIN',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Enter the 4-digit pairing PIN displayed on the PC server screen.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pinController,
                keyboardType: TextInputType.number,
                maxLength: 4,
                obscureText: true,
                style: const TextStyle(color: Colors.white, fontSize: 20, letterSpacing: 8),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '••••',
                  hintStyle: TextStyle(color: Colors.grey.shade600, letterSpacing: 8),
                  enabledBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xFF2A2A4A)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xFF6C63FF)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, pinController.text),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Connect'),
            ),
          ],
        );
      },
    );
  }

  void _showManualConnectDialog(BuildContext context, ConnectionProvider connection) {
    showDialog(
      context: context,
      builder: (context) => ManualConnectDialog(
        ipController: _ipController,
        portController: _portController,
        onConnect: (ip, port) async {
          // context pop করার আগেই size নিন (pop করার পর context defunct হয়ে যায়)
          final size = MediaQuery.of(context).size;
          Navigator.pop(context);
          final success = await connection.connectToServer(
            ip,
            port: port,
            onPinRequired: () => _promptForPin(context),
            screenWidth: size.width,
            screenHeight: size.height,
          );
          if (success && context.mounted) {
            await Navigator.of(context).pushNamed('/drawing');
          }
        },
      ),
    );
  }

  void _showSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Consumer<ConnectionProvider>(
            builder: (context, connection, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade600,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('Settings', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    activeThumbColor: const Color(0xFF6C63FF),
                    title: const Text('Stylus Support', style: TextStyle(color: Colors.white)),
                    subtitle: const Text('Enable pressure sensitivity and pen inputs', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    value: connection.hasStylusSupportSetting,
                    onChanged: (val) {
                      connection.setStylusSupport(val);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.compress, color: Color(0xFF6C63FF)),
                    title: const Text('Max Pressure Level', style: TextStyle(color: Colors.white)),
                    subtitle: Text('Current: ${connection.maxPressureSetting}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    trailing: DropdownButton<double>(
                      dropdownColor: const Color(0xFF1A1A2E),
                      value: connection.maxPressureSetting,
                      style: const TextStyle(color: Colors.white),
                      underline: Container(),
                      items: const [
                        DropdownMenuItem(value: 1.0, child: Text('1.0 (Default)')),
                        DropdownMenuItem(value: 1024.0, child: Text('1024 (Basic)')),
                        DropdownMenuItem(value: 2048.0, child: Text('2048 (Medium)')),
                        DropdownMenuItem(value: 4096.0, child: Text('4096 (High)')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          connection.setMaxPressure(val);
                        }
                      },
                    ),
                  ),
                  const Divider(color: Colors.white12),
                  ListTile(
                    leading: const Icon(Icons.language, color: Color(0xFF6C63FF)),
                    title: const Text('Website', style: TextStyle(color: Colors.white)),
                    subtitle: const Text('Visit our local website', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    onTap: () async {
                      final Uri url = Uri.parse('http://localhost:3000'); // Change this URL to your actual local website URL
                      if (!await launchUrl(url)) {
                        debugPrint('Could not launch $url');
                      }
                    },
                  ),
                  const Divider(color: Colors.white12),
                  const ListTile(
                    leading: Icon(Icons.info_outline, color: Color(0xFF6C63FF)),
                    title: Text('About', style: TextStyle(color: Colors.white)),
                    subtitle: Text('$kAppName v1.0', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
