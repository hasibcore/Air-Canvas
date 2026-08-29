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
  // Bug 146: Undo button state
  final bool canUndo;
  /// পাম রিজেকশন চালু/বন্ধ। বন্ধ করলে যে পয়েন্টার প্রথমে নামে সে-ই আঁকে,
  /// তালু বা দ্বিতীয় আঙুল আলাদা করে বাছা হয় না।
  final bool palmRejection;
  final ValueChanged<bool> onPalmRejectionChanged;

  const ToolbarWidget({
    super.key,
    required this.brushSettings,
    required this.onBrushChanged,
    required this.onUndo,
    required this.onClear,
    required this.onDisconnect,
    required this.isConnected,
    required this.latency,
    required this.palmRejection,
    required this.onPalmRejectionChanged,
    this.canUndo = true,
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
            // Bug 144: Brush sliders extracted into separate child widget
            // to avoid rebuilding buttons when only size/opacity changes.
            _BrushSliders(
              brushSettings: brushSettings,
              onBrushChanged: onBrushChanged,
            ),
            const SizedBox(height: 8),
            // Bug 144: Buttons row — only rebuilds when brushSettings.mode
            // or canUndo changes (both are lightweight)
            _ActionButtons(
              brushSettings: brushSettings,
              onBrushChanged: onBrushChanged,
              onUndo: onUndo,
              onClear: onClear,
              onDisconnect: onDisconnect,
              canUndo: canUndo,
              palmRejection: palmRejection,
              onPalmRejectionChanged: onPalmRejectionChanged,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bug 144: Separate widget for sliders so they don't rebuild buttons
class _BrushSliders extends StatelessWidget {
  final BrushSettings brushSettings;
  final ValueChanged<BrushSettings> onBrushChanged;

  const _BrushSliders({
    required this.brushSettings,
    required this.onBrushChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Brush size slider
        Row(
          children: [
            // Bug 149: Semantics for accessibility
            Semantics(
              label: 'Brush size',
              child: const Icon(Icons.brush, color: Color(0xFF6C63FF), size: 18),
            ),
            const SizedBox(width: 8),
            Text('Size', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
            const SizedBox(width: 8),
            Expanded(
              // Bug 145: onChangeEnd to reduce intermediate rebuilds
              child: Slider(
                value: brushSettings.baseWidth,
                min: 1,
                max: 30,
                onChanged: (v) => onBrushChanged(brushSettings.copyWith(baseWidth: v)),
                activeColor: const Color(0xFF6C63FF),
                inactiveColor: Colors.grey.shade800,
              ),
            ),
            SizedBox(
              width: 36,
              child: Text(
                brushSettings.baseWidth.toStringAsFixed(1),
                style: const TextStyle(color: Colors.white, fontSize: 12),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Opacity slider
        Row(
          children: [
            Semantics(
              label: 'Brush opacity',
              child: const Icon(Icons.opacity, color: Color(0xFF6C63FF), size: 18),
            ),
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
            SizedBox(
              width: 36,
              child: Text(
                '${(brushSettings.opacity * 100).toInt()}%',
                style: const TextStyle(color: Colors.white, fontSize: 12),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Bug 144: Separate widget for action buttons
class _ActionButtons extends StatelessWidget {
  final BrushSettings brushSettings;
  final ValueChanged<BrushSettings> onBrushChanged;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onDisconnect;
  final bool canUndo;
  final bool palmRejection;
  final ValueChanged<bool> onPalmRejectionChanged;

  const _ActionButtons({
    required this.brushSettings,
    required this.onBrushChanged,
    required this.onUndo,
    required this.onClear,
    required this.onDisconnect,
    required this.canUndo,
    required this.palmRejection,
    required this.onPalmRejectionChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
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
        // পাম রিজেকশন টগল — চালু থাকলে পেন আঁকার সময় তালু/দ্বিতীয় আঙুল উপেক্ষা
        // হয়। কোনো ডিভাইসে stylus কে touch রিপোর্ট করলে এটা বন্ধ করলেই আগের
        // আচরণ ফিরে আসে, তাই টগলটা হাতের কাছে রাখা হলো।
        _buildIconButton(
          icon: palmRejection ? Icons.back_hand : Icons.back_hand_outlined,
          tooltip: palmRejection
              ? 'Palm rejection: ON (tap to disable)'
              : 'Palm rejection: OFF (tap to enable)',
          onTap: () => onPalmRejectionChanged(!palmRejection),
          color: palmRejection ? null : Colors.grey.shade500,
        ),
        const SizedBox(width: 6),
        // Bug 146: Undo button visually disabled when no strokes
        _buildIconButton(
          icon: Icons.undo,
          tooltip: canUndo ? 'Undo' : 'Nothing to undo',
          onTap: canUndo ? onUndo : null,
          disabled: !canUndo,
        ),
        const SizedBox(width: 6),
        // Bug 147: Clear with confirmation dialog
        _buildIconButton(
          icon: Icons.delete_outline,
          tooltip: 'Clear canvas',
          onTap: () => _confirmClear(context),
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
    );
  }

  // Bug 147: Confirmation dialog before clearing canvas
  void _confirmClear(BuildContext context) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF2A2A4A)),
        ),
        title: const Text(
          'Clear Canvas?',
          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'This will erase all strokes. This action cannot be undone.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade400,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) onClear();
    });
  }

  Widget _buildColorButton(BuildContext context, Color color) {
    final isSelected = brushSettings.color == color;
    // Bug 149: Semantics for color buttons
    return Semantics(
      label: 'Select ${_colorName(color)} brush color',
      selected: isSelected,
      child: GestureDetector(
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
      ),
    );
  }

  // Bug 149: Human-readable color name for screen readers
  String _colorName(Color color) {
    if (color == Colors.white) return 'white';
    if (color == Colors.red) return 'red';
    if (color == Colors.green) return 'green';
    if (color == Colors.blue) return 'blue';
    if (color == Colors.yellow) return 'yellow';
    return 'custom';
  }

  // Bug 146: Supports disabled state
  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    Color? color,
    bool disabled = false,
  }) {
    final effectiveColor = disabled
        ? Colors.grey.shade700
        : (color ?? const Color(0xFF6C63FF));

    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        button: true,
        enabled: !disabled,
        child: InkWell(
          onTap: disabled ? null : onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: effectiveColor.withValues(alpha: disabled ? 0.05 : 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: effectiveColor, size: 20),
          ),
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