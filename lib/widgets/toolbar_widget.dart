// ড্রয়িং টুলবার - ব্রাশ সেটিংস, আন্ডো, ক্লিয়ার, ডিসকানেক্ট
import 'package:flutter/material.dart';
import '../services/drawing_provider.dart';

class ToolbarWidget extends StatelessWidget {
  final BrushSettings brushSettings;
  final ValueChanged<BrushSettings> onBrushChanged;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onDisconnect;
  final bool isConnected;
  final int latency;

  const ToolbarWidget({
    super.key,
    required this.brushSettings,
    required this.onBrushChanged,
    required this.onUndo,
    required this.onClear,
    required this.onDisconnect,
    required this.isConnected,
    required this.latency,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF12121E),
        border: Border(
          top: BorderSide(color: Color(0xFF2A2A4A)),
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Brush size slider
            Row(
              children: [
                const Icon(Icons.brush, color: Color(0xFF6C63FF), size: 18),
                const SizedBox(width: 8),
                Text('Size', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                const SizedBox(width: 8),
                Expanded(
                  child: Slider(
                    value: brushSettings.baseWidth,
                    min: 1,
                    max: 30,
                    onChanged: (v) => onBrushChanged(brushSettings.copyWith(baseWidth: v)),
                    activeColor: const Color(0xFF6C63FF),
                    inactiveColor: Colors.grey.shade800,
                  ),
                ),
                Text(
                  brushSettings.baseWidth.toStringAsFixed(1),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Opacity slider
            Row(
              children: [
                const Icon(Icons.opacity, color: Color(0xFF6C63FF), size: 18),
                const SizedBox(width: 8),
                Text('Opacity', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                const SizedBox(width: 8),
                Expanded(
                  child: Slider(
                    value: brushSettings.opacity,
                    min: 0.1,
                    max: 1.0,
                    onChanged: (v) => onBrushChanged(brushSettings.copyWith(opacity: v)),
                    activeColor: const Color(0xFF6C63FF),
                    inactiveColor: Colors.grey.shade800,
                  ),
                ),
                Text(
                  '${(brushSettings.opacity * 100).toInt()}%',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Buttons row
            Row(
              children: [
                // Color picker
                _buildColorButton(context, Colors.white),
                const SizedBox(width: 6),
                _buildColorButton(context, Colors.red),
                const SizedBox(width: 6),
                _buildColorButton(context, Colors.green),
                const SizedBox(width: 6),
                _buildColorButton(context, Colors.blue),
                const SizedBox(width: 6),
                _buildColorButton(context, Colors.yellow),
                const Spacer(),
                // Brush mode
                _buildIconButton(
                  icon: _getBrushModeIcon(),
                  tooltip: brushSettings.mode.name,
                  onTap: () {
                    const modes = BrushMode.values;
                    final nextIndex = (modes.indexOf(brushSettings.mode) + 1) % modes.length;
                    onBrushChanged(brushSettings.copyWith(mode: modes[nextIndex]));
                  },
                ),
                const SizedBox(width: 6),
                // Undo
                _buildIconButton(
                  icon: Icons.undo,
                  tooltip: 'Undo',
                  onTap: onUndo,
                ),
                const SizedBox(width: 6),
                // Clear
                _buildIconButton(
                  icon: Icons.delete_outline,
                  tooltip: 'Clear',
                  onTap: onClear,
                ),
                const SizedBox(width: 6),
                // Disconnect
                _buildIconButton(
                  icon: Icons.link_off,
                  tooltip: 'Disconnect',
                  onTap: onDisconnect,
                  color: Colors.red.shade400,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildColorButton(BuildContext context, Color color) {
    final isSelected = brushSettings.color == color;
    return GestureDetector(
      onTap: () => onBrushChanged(brushSettings.copyWith(color: color)),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? const Color(0xFF6C63FF) : Colors.grey.shade700,
            width: isSelected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (color ?? const Color(0xFF6C63FF)).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color ?? const Color(0xFF6C63FF), size: 20),
        ),
      ),
    );
  }

  IconData _getBrushModeIcon() {
    return switch (brushSettings.mode) {
      BrushMode.pen => Icons.edit,
      BrushMode.pencil => Icons.edit_road,
      BrushMode.brush => Icons.brush,
      BrushMode.eraser => Icons.auto_fix_normal,
    };
  }
}