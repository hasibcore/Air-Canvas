// 1-Euro Filter - Adaptive Noise & Jitter Filter for Drawing & Stylus Input
//
// Reference: Casiez, G., Roussel, N. and Vogel, D. (2012)
// "1 € Filter: A Simple Speed-based Low-pass Filter for Noisy Input in HCI"
// Proceedings of the SIGCHI Conference on Human Factors in Computing Systems.
//
// Algorithm characteristics:
// - At low speed: cutoff frequency drops -> high filtering -> eliminates sensor jitter & hand tremble
// - At high speed: cutoff frequency increases -> low filtering -> 0 lag & razor-sharp corner preservation

import 'dart:math' as math;
import 'dart:ui';

/// 1D Low-pass filter with exponential smoothing
class _LowPassFilter {
  double? _s;

  double filter(double value, double alpha) {
    if (_s == null) {
      _s = value;
    } else {
      _s = alpha * value + (1.0 - alpha) * _s!;
    }
    return _s!;
  }

  double? get lastValue => _s;

  void reset() {
    _s = null;
  }
}

/// 1D 1-Euro Filter
class OneEuroFilter {
  /// Minimum cutoff frequency in Hz.
  /// Lower values reduce more jitter during slow movements (default 1.2 Hz).
  final double minCutoff;

  /// Speed coefficient beta.
  /// Higher values reduce lag during fast movements (default 0.008).
  final double beta;

  /// Derivative cutoff frequency in Hz (default 1.0 Hz).
  final double dCutoff;

  final _LowPassFilter _xFilter = _LowPassFilter();
  final _LowPassFilter _dxFilter = _LowPassFilter();
  DateTime? _lastTime;

  OneEuroFilter({
    this.minCutoff = 1.2,
    this.beta = 0.008,
    this.dCutoff = 1.0,
  });

  static double _computeAlpha(double rate, double cutoff) {
    if (rate <= 0.0 || cutoff <= 0.0) return 1.0;
    final tau = 1.0 / (2.0 * math.pi * cutoff);
    final te = 1.0 / rate;
    return 1.0 / (1.0 + tau / te);
  }

  /// Filter a new sample [value] measured at [timestamp].
  double filter(double value, DateTime timestamp) {
    if (_lastTime == null) {
      _lastTime = timestamp;
      return _xFilter.filter(value, 1.0);
    }

    final dtMicro = timestamp.difference(_lastTime!).inMicroseconds;
    _lastTime = timestamp;

    // Guard against identical timestamps or reverse clocks
    final dt = dtMicro > 0 ? dtMicro / 1000000.0 : 1.0 / 120.0;
    final rate = 1.0 / dt;

    final prevX = _xFilter.lastValue ?? value;
    final rawDx = (value - prevX) * rate;

    // Filter the derivative (velocity)
    final dAlpha = _computeAlpha(rate, dCutoff);
    final filteredDx = _dxFilter.filter(rawDx, dAlpha);

    // Adaptive cutoff based on velocity: f_c = minCutoff + beta * |dx|
    final cutoff = minCutoff + beta * filteredDx.abs();
    final xAlpha = _computeAlpha(rate, cutoff);

    return _xFilter.filter(value, xAlpha);
  }

  void reset() {
    _xFilter.reset();
    _dxFilter.reset();
    _lastTime = null;
  }
}

/// 2D 1-Euro Filter for (X, Y) Coordinates
class OneEuroFilter2D {
  final OneEuroFilter _filterX;
  final OneEuroFilter _filterY;

  OneEuroFilter2D({
    double minCutoff = 1.2,
    double beta = 0.008,
    double dCutoff = 1.0,
  })  : _filterX = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff),
        _filterY = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff);

  /// Filter a 2D position [point] at [timestamp].
  Offset filter(Offset point, DateTime timestamp) {
    final fx = _filterX.filter(point.dx, timestamp);
    final fy = _filterY.filter(point.dy, timestamp);
    return Offset(fx, fy);
  }

  void reset() {
    _filterX.reset();
    _filterY.reset();
  }
}
