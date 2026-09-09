import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:air_canvas/models/input_event.dart';
import 'package:air_canvas/services/drawing_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AIRCanvas Fullscreen, Border & Center Alignment Tests', () {
    late DrawingProvider provider;

    setUp(() {
      provider = DrawingProvider();
    });

    tearDown(() {
      provider.dispose();
    });

    test('1. Mobile defaults to Full Screen Tablet Mode (Zero letterbox border)', () {
      expect(provider.fullScreenTabletMode, isTrue,
          reason: 'Mobile must default to full screen graphics tablet mode so whole display is active');
    });

    test('2. Exact Center Normalization Invariant: Mobile (0.5, 0.5) across phone viewports', () {
      // Test mobile screen resolutions and aspect ratios:
      // 16:9 (1920x1080), 18:9 (2160x1080), 19.5:9 (2340x1080), 20:9 (2400x1080)
      final mobileViewports = [
        const Size(1920, 1080), // 16:9
        const Size(2160, 1080), // 18:9
        const Size(2340, 1080), // 19.5:9
        const Size(2400, 1080), // 20:9
      ];

      for (final vp in mobileViewports) {
        provider.updateCanvasSize(vp.width, vp.height);

        InputEvent? capturedEvent;
        provider.onInputGenerated = (event) {
          capturedEvent = event;
        };

        // Touch exact geometric center of phone screen
        final centerPoint = Offset(vp.width * 0.5, vp.height * 0.5);
        provider.onPointerDown(centerPoint, pressure: 0.5);

        expect(capturedEvent, isNotNull);
        expect(capturedEvent!.x, closeTo(0.5, 1e-6),
            reason: 'Normalized X must be exactly 0.5 for viewport ${vp.width}x${vp.height}');
        expect(capturedEvent!.y, closeTo(0.5, 1e-6),
            reason: 'Normalized Y must be exactly 0.5 for viewport ${vp.width}x${vp.height}');

        provider.onPointerUp();
      }
    });

    test('3. Corner Normalization Invariant: (0,0), (1,0), (0,1), (1,1)', () {
      const vp = Size(2400, 1080); // 20:9 phone
      provider.updateCanvasSize(vp.width, vp.height);

      final corners = [
        {'pt': const Offset(0, 0), 'expectedX': 0.0, 'expectedY': 0.0},
        {'pt': Offset(vp.width, 0), 'expectedX': 1.0, 'expectedY': 0.0},
        {'pt': Offset(0, vp.height), 'expectedX': 0.0, 'expectedY': 1.0},
        {'pt': Offset(vp.width, vp.height), 'expectedX': 1.0, 'expectedY': 1.0},
      ];

      for (final c in corners) {
        InputEvent? captured;
        provider.onInputGenerated = (e) => captured = e;

        provider.onPointerDown(c['pt'] as Offset, pressure: 0.5);
        expect(captured, isNotNull);
        expect(captured!.x, closeTo(c['expectedX'] as double, 1e-6));
        expect(captured!.y, closeTo(c['expectedY'] as double, 1e-6));
        provider.onPointerUp();
      }
    });

    test('4. Center alignment remains 0.5 under Writing Scale and Center Anchor', () {
      provider.updateCanvasSize(2400, 1080);
      provider.writingAnchor = WritingAnchor.center;

      for (final scale in [1.0, 0.75, 0.50, 0.25]) {
        provider.writingScale = scale;

        InputEvent? captured;
        provider.onInputGenerated = (e) => captured = e;

        // Center touch
        provider.onPointerDown(const Offset(1200, 540), pressure: 0.5);
        expect(captured, isNotNull);
        expect(captured!.x, closeTo(0.5, 1e-6),
            reason: 'Center touch must remain 0.5 at writing scale $scale');
        expect(captured!.y, closeTo(0.5, 1e-6),
            reason: 'Center touch must remain 0.5 at writing scale $scale');
        provider.onPointerUp();
      }
    });

    test('5. Center Guide Diagnostic toggle works properly', () {
      expect(provider.showCenterGuide, isFalse);
      provider.showCenterGuide = true;
      expect(provider.showCenterGuide, isTrue);
      provider.showCenterGuide = false;
      expect(provider.showCenterGuide, isFalse);
    });

    test('6. Clamping and Safety: Out-of-bounds touches safely clamped to [0.0, 1.0]', () {
      provider.updateCanvasSize(1920, 1080);

      InputEvent? captured;
      provider.onInputGenerated = (e) => captured = e;

      // Negative coordinates (outside canvas)
      provider.onPointerDown(const Offset(-100, -50), pressure: 0.5);
      expect(captured, isNotNull);
      expect(captured!.x, equals(0.0));
      expect(captured!.y, equals(0.0));
      provider.onPointerUp();

      // Over-boundary coordinates
      provider.onPointerDown(const Offset(2500, 1500), pressure: 0.5);
      expect(captured, isNotNull);
      expect(captured!.x, equals(1.0));
      expect(captured!.y, equals(1.0));
      provider.onPointerUp();
    });
  });

  group('PC Target Geometry Simulation Tests', () {
    test('PC Target Center calculation: targetCenterX = targetLeft + targetWidth / 2', () {
      final testCases = [
        // Resolution, Left, Top, ExpectedCenterX, ExpectedCenterY
        {'name': '1080p Fullscreen', 'l': 0, 't': 0, 'w': 1920, 'h': 1080, 'cx': 960, 'cy': 540},
        {'name': '1440p Fullscreen', 'l': 0, 't': 0, 'w': 2560, 'h': 1440, 'cx': 1280, 'cy': 720},
        {'name': '4K Fullscreen', 'l': 0, 't': 0, 'w': 3840, 'h': 2160, 'cx': 1920, 'cy': 1080},
        {'name': '1366x768 Laptop', 'l': 0, 't': 0, 'w': 1366, 'h': 768, 'cx': 683, 'cy': 384},
        {'name': '720p HD', 'l': 0, 't': 0, 'w': 1280, 'h': 720, 'cx': 640, 'cy': 360},
        // Multi-monitor with negative origin
        {'name': 'Monitor 2 Left of Mon 1', 'l': -1920, 't': 0, 'w': 1920, 'h': 1080, 'cx': -960, 'cy': 540},
        {'name': 'Monitor 2 Above Mon 1', 'l': 0, 't': -1080, 'w': 1920, 'h': 1080, 'cx': 960, 'cy': -540},
        // Portrait monitor
        {'name': 'Portrait Monitor', 'l': 1920, 't': 0, 'w': 1080, 'h': 1920, 'cx': 2460, 'cy': 960},
        // Windowed / Maximized Client Area (e.g. Chrome with tabs/address bar)
        {'name': 'Maximized Chrome Client', 'l': 0, 't': 72, 'w': 1920, 'h': 968, 'cx': 960, 'cy': 556},
        {'name': 'Windowed Client Rect', 'l': 200, 't': 150, 'w': 1200, 'h': 800, 'cx': 800, 'cy': 550},
      ];

      for (final tc in testCases) {
        final l = tc['l'] as int;
        final t = tc['t'] as int;
        final w = tc['w'] as int;
        final h = tc['h'] as int;
        final expectedCx = tc['cx'] as int;
        final expectedCy = tc['cy'] as int;

        final actualCx = l + (w ~/ 2);
        final actualCy = t + (h ~/ 2);

        expect(actualCx, equals(expectedCx),
            reason: '${tc['name']}: CenterX must match exactly');
        expect(actualCy, equals(expectedCy),
            reason: '${tc['name']}: CenterY must match exactly');

        // Test normalized mapping at 0.5, 0.5
        const normX = 0.5;
        const normY = 0.5;
        final mappedX = (normX - 0.5).abs() < 1e-5 ? (l + (w ~/ 2)) : (l + (normX * (w - 1)).round());
        final mappedY = (normY - 0.5).abs() < 1e-5 ? (t + (h ~/ 2)) : (t + (normY * (h - 1)).round());

        expect(mappedX, equals(expectedCx));
        expect(mappedY, equals(expectedCy));
      }
    });

    test('Corners map to exact physical target bounds without clipping or offset', () {
      const l = 100;
      const t = 50;
      const w = 1600;
      const h = 900;

      // Normalized corners
      final corners = [
        {'x': 0.0, 'y': 0.0, 'expectedX': l, 'expectedY': t},
        {'x': 1.0, 'y': 0.0, 'expectedX': l + w - 1, 'expectedY': t},
        {'x': 0.0, 'y': 1.0, 'expectedX': l, 'expectedY': t + h - 1},
        {'x': 1.0, 'y': 1.0, 'expectedX': l + w - 1, 'expectedY': t + h - 1},
      ];

      for (final c in corners) {
        final nx = c['x'] as double;
        final ny = c['y'] as double;
        final mx = (nx - 0.5).abs() < 1e-5 ? (l + (w ~/ 2)) : (l + (nx * (w - 1)).round());
        final my = (ny - 0.5).abs() < 1e-5 ? (t + (h ~/ 2)) : (t + (ny * (h - 1)).round());

        expect(mx, equals(c['expectedX'] as int));
        expect(my, equals(c['expectedY'] as int));
      }
    });
  });
}
