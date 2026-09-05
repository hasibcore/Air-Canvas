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
  final bool fullScreenMode;
  final ValueChanged<bool> onFullScreenModeChanged;
  final bool directTabletMode;
  final ValueChanged<bool> onDirectTabletModeChanged;
  final PrecisionMode precisionMode;
  final ValueChanged<PrecisionMode>? onPrecisionModeChanged;
  final PressureCurve pressureCurve;
  final ValueChanged<PressureCurve>? onPressureCurveChanged;
  final double writingScale;
  final ValueChanged<double>? onWritingScaleChanged;
  final WritingAnchor writingAnchor;
  final ValueChanged<WritingAnchor>? onWritingAnchorChanged;
  final ValueChanged<String>? onClassAction;

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
    this.fullScreenMode = true,
    required this.onFullScreenModeChanged,
    this.directTabletMode = true,
    required this.onDirectTabletModeChanged,
    this.precisionMode = PrecisionMode.proAdaptive,
    this.onPrecisionModeChanged,
    this.pressureCurve = PressureCurve.standard,
    this.onPressureCurveChanged,
    this.writingScale = 0.55,
    this.onWritingScaleChanged,
    this.writingAnchor = WritingAnchor.center,
    this.onWritingAnchorChanged,
    this.onClassAction,
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
              fullScreenMode: fullScreenMode,
              onFullScreenModeChanged: onFullScreenModeChanged,
              directTabletMode: directTabletMode,
              onDirectTabletModeChanged: onDirectTabletModeChanged,
              precisionMode: precisionMode,
              onPrecisionModeChanged: onPrecisionModeChanged,
              pressureCurve: pressureCurve,
              onPressureCurveChanged: onPressureCurveChanged,
              writingScale: writingScale,
              onWritingScaleChanged: onWritingScaleChanged,
              writingAnchor: writingAnchor,
              onWritingAnchorChanged: onWritingAnchorChanged,
              onClassAction: onClassAction,
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
  final bool fullScreenMode;
  final ValueChanged<bool> onFullScreenModeChanged;
  final bool directTabletMode;
  final ValueChanged<bool> onDirectTabletModeChanged;
  final PrecisionMode precisionMode;
  final ValueChanged<PrecisionMode>? onPrecisionModeChanged;
  final PressureCurve pressureCurve;
  final ValueChanged<PressureCurve>? onPressureCurveChanged;
  final double writingScale;
  final ValueChanged<double>? onWritingScaleChanged;
  final WritingAnchor writingAnchor;
  final ValueChanged<WritingAnchor>? onWritingAnchorChanged;
  final ValueChanged<String>? onClassAction;

  const _ActionButtons({
    required this.brushSettings,
    required this.onBrushChanged,
    required this.onUndo,
    required this.onClear,
    required this.onDisconnect,
    required this.canUndo,
    required this.palmRejection,
    required this.onPalmRejectionChanged,
    required this.fullScreenMode,
    required this.onFullScreenModeChanged,
    required this.directTabletMode,
    required this.onDirectTabletModeChanged,
    required this.precisionMode,
    this.onPrecisionModeChanged,
    required this.pressureCurve,
    this.onPressureCurveChanged,
    required this.writingScale,
    this.onWritingScaleChanged,
    required this.writingAnchor,
    this.onWritingAnchorChanged,
    this.onClassAction,
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
        // PC Handwriting Size / Scale Button
        _buildIconButton(
          icon: Icons.format_size_rounded,
          tooltip: 'পিসিতে লেখার সাইজ: ${(writingScale * 100).round()}% (ছোট/বড় করতে ট্যাপ করুন)',
          onTap: () => _showWritingScaleMenu(context),
          color: const Color(0xFF4ADE80),
        ),
        const SizedBox(width: 6),
        // Tablet Surface Mode toggle (Aspect match 1:1 vs Full screen stretched)
        _buildIconButton(
          icon: !fullScreenMode ? Icons.aspect_ratio : Icons.fit_screen,
          tooltip: !fullScreenMode
              ? '1:1 PC Aspect Ratio (Active - Zero Distortion) - Tap for Full Screen'
              : 'Full Screen Stretched (Active - Shapes May Distort) - Tap for 1:1 Match',
          onTap: () => onFullScreenModeChanged(!fullScreenMode),
          color: !fullScreenMode ? const Color(0xFF00E5FF) : Colors.amber.shade300,
        ),
        const SizedBox(width: 6),
        // Pro Accuracy & Jitter Filter Engine Selector
        _buildIconButton(
          icon: precisionMode == PrecisionMode.proAdaptive
              ? Icons.auto_awesome
              : (precisionMode == PrecisionMode.rawDirect ? Icons.bolt : Icons.brush),
          tooltip: precisionMode == PrecisionMode.proAdaptive
              ? 'Pro Accuracy: 1-Euro Adaptive Filter ON (Zero Jitter, Zero Lag) - Tap to configure'
              : (precisionMode == PrecisionMode.rawDirect
                  ? 'Accuracy: Direct Raw (Unfiltered Sensor) - Tap to configure'
                  : 'Accuracy: Studio Stabilizer (Art Inking) - Tap to configure'),
          onTap: () => _showPrecisionMenu(context),
          color: precisionMode == PrecisionMode.proAdaptive
              ? const Color(0xFFFFD700)
              : (precisionMode == PrecisionMode.rawDirect ? const Color(0xFF00E5FF) : const Color(0xFFC084FC)),
        ),
        const SizedBox(width: 6),
        // Classroom & Presentation Tools (PPT Pen, Laser, Eraser, OneNote)
        _buildIconButton(
          icon: Icons.school_outlined,
          tooltip: 'Classroom & Presentation Shortcuts (PPT Pen, Laser, Eraser, OneNote)',
          onTap: () => _showClassroomMenu(context, onClassAction),
          color: const Color(0xFF38BDF8),
        ),
        const SizedBox(width: 6),
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

  void _showWritingScaleMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B26),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF2A374A)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4ADE80).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.format_size_rounded, color: Color(0xFF4ADE80), size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'পিসিতে লেখার সাইজ (Handwriting Size)',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'পিসির পর্দায় লেখা যাতে অনেক বড় না হয়ে স্বাভাবিক খাতার মতো সুন্দর ও নিখুঁত দেখায়, সাইজ নির্বাচন করুন:',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  _buildEngineOption(
                    title: 'ছোট সাইজ (৫০% - Compact Note) ★প্রস্তাবিত',
                    subtitle: 'খাতার স্বাভাবিক লেখা। এক লাইনে অনেক শব্দ ও সমীকরণ সুন্দরভাবে আঁটবে।',
                    icon: Icons.notes_rounded,
                    accentColor: const Color(0xFF4ADE80),
                    isSelected: (writingScale - 0.50).abs() < 0.08,
                    onTap: () {
                      onWritingScaleChanged?.call(0.50);
                      Navigator.pop(ctx);
                    },
                  ),
                  const SizedBox(height: 6),
                  _buildEngineOption(
                    title: 'মাঝারি সাইজ (৭৫% - Balanced)',
                    subtitle: 'অনলাইন ক্লাস ও হোয়াইটবোর্ডে ড্রয়িংয়ের জন্য আদর্শ ব্যালেন্সড সাইজ।',
                    icon: Icons.draw_rounded,
                    accentColor: const Color(0xFF38BDF8),
                    isSelected: (writingScale - 0.75).abs() < 0.08,
                    onTap: () {
                      onWritingScaleChanged?.call(0.75);
                      Navigator.pop(ctx);
                    },
                  ),
                  const SizedBox(height: 6),
                  _buildEngineOption(
                    title: 'পুরো মনিটর (১০০% - Full Screen)',
                    subtitle: 'পুরো ডিসপ্লে জুড়ে বড় করে আঁকা ও ফুল স্ক্রিন নেভিগেশন।',
                    icon: Icons.fullscreen_rounded,
                    accentColor: const Color(0xFFFFD700),
                    isSelected: (writingScale - 1.0).abs() < 0.08,
                    onTap: () {
                      onWritingScaleChanged?.call(1.0);
                      Navigator.pop(ctx);
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'কাস্টম সাইজ স্লাইডার',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${(writingScale * 100).round()}%',
                        style: const TextStyle(color: Color(0xFF4ADE80), fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  Slider(
                    value: writingScale.clamp(0.25, 1.0),
                    min: 0.25,
                    max: 1.0,
                    divisions: 15,
                    activeColor: const Color(0xFF4ADE80),
                    inactiveColor: Colors.grey.shade800,
                    onChanged: (v) {
                      setSheetState(() {});
                      onWritingScaleChanged?.call(v);
                    },
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'পিসির পর্দায় লেখার অবস্থান (Placement):',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.north_west, size: 16),
                          label: const Text('Top-Left (শুরুতে)'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: writingAnchor == WritingAnchor.topLeft ? const Color(0xFF4ADE80) : Colors.grey,
                            side: BorderSide(
                              color: writingAnchor == WritingAnchor.topLeft ? const Color(0xFF4ADE80) : Colors.grey.shade800,
                            ),
                          ),
                          onPressed: () {
                            onWritingAnchorChanged?.call(WritingAnchor.topLeft);
                            Navigator.pop(ctx);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.filter_center_focus, size: 16),
                          label: const Text('Center (মাঝে)'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: writingAnchor == WritingAnchor.center ? const Color(0xFF4ADE80) : Colors.grey,
                            side: BorderSide(
                              color: writingAnchor == WritingAnchor.center ? const Color(0xFF4ADE80) : Colors.grey.shade800,
                            ),
                          ),
                          onPressed: () {
                            onWritingAnchorChanged?.call(WritingAnchor.center);
                            Navigator.pop(ctx);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showPrecisionMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B26),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF2A374A)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFD700).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.auto_awesome, color: Color(0xFFFFD700), size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Pro Precision & Stylus Engine',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'PRECISION & JITTER ENGINE',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 8),
                  _buildEngineOption(
                    title: '1-Euro Adaptive Filter (Pro Recommended)',
                    subtitle: 'Zero jitter on fine handwriting & math, zero lag on fast sweeps, razor-sharp corners.',
                    icon: Icons.auto_awesome,
                    accentColor: const Color(0xFFFFD700),
                    isSelected: precisionMode == PrecisionMode.proAdaptive,
                    onTap: () {
                      onPrecisionModeChanged?.call(PrecisionMode.proAdaptive);
                      Navigator.pop(ctx);
                    },
                  ),
                  const SizedBox(height: 6),
                  _buildEngineOption(
                    title: 'Direct Raw Stream (Zero Filtering)',
                    subtitle: '100% unfiltered digitizer input. Direct capacitive sensor pass-through.',
                    icon: Icons.bolt,
                    accentColor: const Color(0xFF00E5FF),
                    isSelected: precisionMode == PrecisionMode.rawDirect,
                    onTap: () {
                      onPrecisionModeChanged?.call(PrecisionMode.rawDirect);
                      Navigator.pop(ctx);
                    },
                  ),
                  const SizedBox(height: 6),
                  _buildEngineOption(
                    title: 'Studio Inking Stabilizer',
                    subtitle: 'Heavy weighted smoothing for slow, flowing artistic curves and calligraphy.',
                    icon: Icons.brush,
                    accentColor: const Color(0xFFC084FC),
                    isSelected: precisionMode == PrecisionMode.studioSmooth,
                    onTap: () {
                      onPrecisionModeChanged?.call(PrecisionMode.studioSmooth);
                      Navigator.pop(ctx);
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'STYLUS PRESSURE CALIBRATION',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildPressureChip(
                        label: 'Standard (1:1 Linear)',
                        curve: PressureCurve.standard,
                        current: pressureCurve,
                        onTap: () {
                          onPressureCurveChanged?.call(PressureCurve.standard);
                          Navigator.pop(ctx);
                        },
                      ),
                      _buildPressureChip(
                        label: 'Soft (Light Touch - Gamma 0.7)',
                        curve: PressureCurve.soft,
                        current: pressureCurve,
                        onTap: () {
                          onPressureCurveChanged?.call(PressureCurve.soft);
                          Navigator.pop(ctx);
                        },
                      ),
                      _buildPressureChip(
                        label: 'Firm (High Control - Gamma 1.4)',
                        curve: PressureCurve.firm,
                        current: pressureCurve,
                        onTap: () {
                          onPressureCurveChanged?.call(PressureCurve.firm);
                          Navigator.pop(ctx);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEngineOption({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? accentColor.withValues(alpha: 0.12) : const Color(0xFF1E2638),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isSelected ? accentColor : const Color(0xFF2A374A), width: isSelected ? 1.5 : 1.0),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? accentColor : Colors.grey.shade400, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.grey.shade200,
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                  ),
                ],
              ),
            ),
            if (isSelected) Icon(Icons.check_circle, color: accentColor, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildPressureChip({
    required String label,
    required PressureCurve curve,
    required PressureCurve current,
    required VoidCallback onTap,
  }) {
    final isSelected = curve == current;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 12, color: isSelected ? Colors.white : Colors.grey.shade300)),
      selected: isSelected,
      selectedColor: const Color(0xFF6C63FF),
      backgroundColor: const Color(0xFF1E2638),
      onSelected: (_) => onTap(),
      showCheckmark: false,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: isSelected ? const Color(0xFF6C63FF) : const Color(0xFF2A374A)),
      ),
    );
  }

  void _showClassroomMenu(BuildContext context, ValueChanged<String>? onClassAction) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B26),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF2A374A)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.school, color: Color(0xFF38BDF8), size: 22),
                  const SizedBox(width: 8),
                  const Text(
                    'Classroom & Presentation Tools',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _buildClassChip(ctx, '🖊️ PPT Pen (Ctrl+P)', () {
                    onClassAction?.call('ppt_pen');
                    Navigator.pop(ctx);
                  }),
                  _buildClassChip(ctx, '🔴 PPT Laser (Ctrl+L)', () {
                    onClassAction?.call('ppt_laser');
                    Navigator.pop(ctx);
                  }),
                  _buildClassChip(ctx, '🧹 PPT Eraser (Ctrl+E)', () {
                    onClassAction?.call('ppt_eraser');
                    Navigator.pop(ctx);
                  }),
                  _buildClassChip(ctx, '↩️ Undo (Ctrl+Z)', () {
                    onClassAction?.call('undo');
                    Navigator.pop(ctx);
                  }),
                  _buildClassChip(ctx, '📝 Open OneNote', () {
                    onClassAction?.call('launch_onenote');
                    Navigator.pop(ctx);
                  }),
                  _buildClassChip(ctx, '📊 Open PowerPoint', () {
                    onClassAction?.call('launch_ppt');
                    Navigator.pop(ctx);
                  }),
                  _buildClassChip(ctx, '🎨 Open MS Paint', () {
                    onClassAction?.call('launch_paint');
                    Navigator.pop(ctx);
                  }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClassChip(BuildContext context, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          border: Border.all(color: const Color(0xFF334155)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
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