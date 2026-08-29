// কানেকশন ফ্লোটিং বাটন - ড্রয়িং স্ক্রিনে কানেকশন স্ট্যাটাস দেখায়
import 'package:flutter/material.dart';

class ConnectionFloatingButton extends StatelessWidget {
  final bool isConnected;
  final int latency;
  final String deviceName;
  final VoidCallback onTap;

  const ConnectionFloatingButton({
    super.key,
    required this.isConnected,
    required this.latency,
    required this.deviceName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isConnected ? Colors.green.shade400 : Colors.red.shade400;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Pulsing dot
            AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              isConnected
                  ? (latency > 0 ? '$latency ms' : 'Live')
                  : 'Offline',
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}