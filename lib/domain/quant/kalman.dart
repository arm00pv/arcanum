/// Local-linear-trend Kalman filter with a Rauch-Tung-Striebel smoother.
///
/// The model tracks the log price as `y_t = level_t + noise`, with the level
/// following a random walk whose drift (slope) itself follows a random walk:
///
/// ```
/// x_t = [level, slope]'
/// F   = [[1, 1], [0, 1]]
/// H   = [1, 0]
/// Q   = [[2.5333e-5, 5e-7], [5e-7, 1e-6]]
/// R   = 1e-4
/// ```
///
/// Missing days are handled by running the prediction step alone, so the state
/// uncertainty grows through the gap instead of being hidden by a forward fill.
/// The smoother then uses the whole window - including observations *after* a
/// gap - to estimate the level on every day of the grid.
library;

/// Noise settings for [runLocalLinearTrend].
class KalmanSettings {
  /// Process variance of the level.
  final double levelVariance;

  /// Process covariance between level and slope.
  final double levelSlopeCovariance;

  /// Process variance of the slope.
  final double slopeVariance;

  /// Observation variance.
  final double observationVariance;

  /// Prior variance of the level at `t = 0`.
  final double initialLevelVariance;

  /// Prior variance of the slope at `t = 0`.
  final double initialSlopeVariance;

  /// Variance substituted for the level prior after a structural break.
  final double diffuseLevelVariance;

  /// Creates noise settings; the defaults are the values used by the engine.
  const KalmanSettings({
    this.levelVariance = 2.5333e-5,
    this.levelSlopeCovariance = 5e-7,
    this.slopeVariance = 1e-6,
    this.observationVariance = 1e-4,
    this.initialLevelVariance = 1e-2,
    this.initialSlopeVariance = 1e-6,
    this.diffuseLevelVariance = 1e6,
  });
}

/// Output of [runLocalLinearTrend].
class KalmanRun {
  /// Filtered state `[level, slope]` for every day of the grid.
  final List<List<double>> filtered;

  /// RTS-smoothed state `[level, slope]` for every day of the grid.
  final List<List<double>> smoothed;

  /// Filtered covariance of every day, packed as `[p00, p01, p11]`.
  final List<List<double>> filteredCovariance;

  /// Smoothed covariance of every day, packed as `[p00, p01, p11]`.
  final List<List<double>> smoothedCovariance;

  /// Grid days at which a structural break reset the state to a diffuse prior.
  final List<int> breakIndices;

  /// Creates a Kalman run.
  const KalmanRun({
    required this.filtered,
    required this.smoothed,
    required this.filteredCovariance,
    required this.smoothedCovariance,
    required this.breakIndices,
  });

  /// Smoothed state on the final grid day, or `[0, 0]` for an empty run.
  List<double> get lastSmoothed =>
      smoothed.isEmpty ? const <double>[0, 0] : smoothed.last;

  /// Smoothed covariance on the final grid day, or `[0, 0, 0]` when empty.
  List<double> get lastSmoothedCovariance => smoothedCovariance.isEmpty
      ? const <double>[0, 0, 0]
      : smoothedCovariance.last;
}

/// Runs the filter and smoother over a daily grid.
///
/// [gridLength] is the number of calendar days from the first to the last
/// observation, inclusive. [observations] maps a grid index to a log price;
/// indices that are absent are treated as missing days and only the prediction
/// step is run for them.
///
/// When [breakThreshold] is non-null and the absolute change in log price since
/// the previous observation exceeds it, the state is re-based on the new
/// observation with a diffuse level prior `diag(1e6, 1e-6)` and the grid index
/// is recorded in [KalmanRun.breakIndices]. That keeps a regime change from
/// being smeared across the smoother as if it were noise.
///
/// Never throws: an empty grid returns an empty run.
KalmanRun runLocalLinearTrend({
  required int gridLength,
  required Map<int, double> observations,
  double? breakThreshold,
  KalmanSettings settings = const KalmanSettings(),
}) {
  final filtered = <List<double>>[];
  final smoothed = <List<double>>[];
  final filteredCovariance = <List<double>>[];
  final smoothedCovariance = <List<double>>[];
  final breaks = <int>[];
  if (gridLength <= 0) {
    return KalmanRun(
      filtered: filtered,
      smoothed: smoothed,
      filteredCovariance: filteredCovariance,
      smoothedCovariance: smoothedCovariance,
      breakIndices: breaks,
    );
  }

  final predicted = <List<double>>[];
  final predictedCovariance = <List<double>>[];

  final firstObservation =
      observations[0] ??
      (observations.isEmpty ? 0.0 : observations[observations.keys.first]!);

  var level = firstObservation;
  var slope = 0.0;
  var p00 = settings.initialLevelVariance;
  var p01 = 0.0;
  var p11 = settings.initialSlopeVariance;
  double? previousObservation;

  for (var t = 0; t < gridLength; t++) {
    final z = observations[t];
    if (z != null &&
        previousObservation != null &&
        breakThreshold != null &&
        (z - previousObservation).abs() > breakThreshold) {
      breaks.add(t);
      level = z;
      p00 = settings.diffuseLevelVariance;
      p01 = 0.0;
      p11 = settings.initialSlopeVariance;
    }

    // Predict.
    final levelMinus = level + slope;
    final slopeMinus = slope;
    // P- = F P F' + Q with F = [[1, 1], [0, 1]], so
    // P-00 = p00 + 2*p01 + p11, P-01 = p01 + p11, P-11 = p11.
    final m00 = p00 + 2 * p01 + p11 + settings.levelVariance;
    final m01 = p01 + p11 + settings.levelSlopeCovariance;
    final m11 = p11 + settings.slopeVariance;
    predicted.add(<double>[levelMinus, slopeMinus]);
    predictedCovariance.add(<double>[m00, m01, m11]);

    // Update, when there is something to update with.
    var f00 = m00;
    var f01 = m01;
    var f11 = m11;
    var filteredLevel = levelMinus;
    var filteredSlope = slopeMinus;
    final s = m00 + settings.observationVariance;
    if (z != null && s.isFinite && s > 0) {
      final k0 = m00 / s;
      final k1 = m01 / s;
      final innovation = z - levelMinus;
      filteredLevel = levelMinus + k0 * innovation;
      filteredSlope = slopeMinus + k1 * innovation;
      final c00 = (1 - k0) * m00;
      final c01 = 0.5 * (((1 - k0) * m01) + (m01 - k1 * m00));
      final c11 = m11 - k1 * m01;
      if (c00.isFinite && c01.isFinite && c11.isFinite) {
        f00 = c00;
        f01 = c01;
        f11 = c11;
        previousObservation = z;
      }
    }

    level = filteredLevel;
    slope = filteredSlope;
    p00 = f00;
    p01 = f01;
    p11 = f11;
    filtered.add(<double>[filteredLevel, filteredSlope]);
    filteredCovariance.add(<double>[f00, f01, f11]);
  }

  // Rauch-Tung-Striebel backward pass.
  for (var t = 0; t < gridLength; t++) {
    smoothed.add(<double>[filtered[t][0], filtered[t][1]]);
    smoothedCovariance.add(<double>[
      filteredCovariance[t][0],
      filteredCovariance[t][1],
      filteredCovariance[t][2],
    ]);
  }
  for (var t = gridLength - 2; t >= 0; t--) {
    final a00 = filteredCovariance[t][0];
    final a01 = filteredCovariance[t][1];
    final a11 = filteredCovariance[t][2];
    // Pf * F' with F' = [[1, 0], [1, 1]].
    final b00 = a00 + a01;
    final b01 = a01;
    final b10 = a01 + a11;
    final b11 = a11;
    final q00 = predictedCovariance[t + 1][0];
    final q01 = predictedCovariance[t + 1][1];
    final q11 = predictedCovariance[t + 1][2];
    final det = q00 * q11 - q01 * q01;
    if (!det.isFinite || det.abs() < 1e-300) continue;
    final i00 = q11 / det;
    final i01 = -q01 / det;
    final i11 = q00 / det;
    final j00 = b00 * i00 + b01 * i01;
    final j01 = b00 * i01 + b01 * i11;
    final j10 = b10 * i00 + b11 * i01;
    final j11 = b10 * i01 + b11 * i11;
    final dx0 = smoothed[t + 1][0] - predicted[t + 1][0];
    final dx1 = smoothed[t + 1][1] - predicted[t + 1][1];
    smoothed[t][0] = filtered[t][0] + j00 * dx0 + j01 * dx1;
    smoothed[t][1] = filtered[t][1] + j10 * dx0 + j11 * dx1;

    final d00 = smoothedCovariance[t + 1][0] - q00;
    final d01 = smoothedCovariance[t + 1][1] - q01;
    final d11 = smoothedCovariance[t + 1][2] - q11;
    final m00 = j00 * d00 + j01 * d01;
    final m01 = j00 * d01 + j01 * d11;
    final m10 = j10 * d00 + j11 * d01;
    final m11 = j10 * d01 + j11 * d11;
    final n00 = a00 + m00 * j00 + m01 * j01;
    final n01 = a01 + m00 * j10 + m01 * j11;
    final n11 = a11 + m10 * j10 + m11 * j11;
    if (n00.isFinite && n01.isFinite && n11.isFinite) {
      smoothedCovariance[t][0] = n00;
      smoothedCovariance[t][1] = n01;
      smoothedCovariance[t][2] = n11;
    }
  }

  return KalmanRun(
    filtered: filtered,
    smoothed: smoothed,
    filteredCovariance: filteredCovariance,
    smoothedCovariance: smoothedCovariance,
    breakIndices: breaks,
  );
}
