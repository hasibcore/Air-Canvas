/// কানেকশন স্ট্যাটাস বার - হোম স্ক্রিনে কানেকশন অবস্থা দেখায়
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:provider/provider.dart';
import '../services/connection_provider.dart';

class ConnectionStatusBar extends StatelessWidget {
  const ConnectionStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final connection = context.watch<ConnectionProvider>();

    if (connection.state == ConnectionState.disconnected) {
      return const SizedBox.shrink();
    }

    final (color, icon, label) = switch (connection.state) {
      ConnectionState.discovering => (
          Colors.amber.shade400,
          Icons.radar,
          'Discovering...'
        ),
      ConnectionState.connecting => (
          Colors.blue.shade400,
          Icons.sync,
          'Connecting...'
        ),
      ConnectionState.connected => (
          Colors.green.shade400,
          Icons.wifi,
          'Connected${connection.latencyMs > 0 ? ' (${connection.latencyMs}ms)' : ''}'
        ),
      ConnectionState.reconnecting => (
          Colors.orange.shade400,
          Icons.sync_problem,
          'Reconnecting...'
        ),
      ConnectionState.error => (
          Colors.red.shade400,
          Icons.error_outline,
          connection.errorMessage.isNotEmpty ? connection.errorMessage : 'Error'
        ),
      ConnectionState.disconnected => (Colors.grey, Icons.wifi_off, 'Disconnected'),
    };

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: color, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (connection.state == ConnectionState.error)
            GestureDetector(
              onTap: () => connection.clearError(),
              child: Icon(Icons.close, color: color, size: 16),
            ),
        ],
      ),
    );
  }
}