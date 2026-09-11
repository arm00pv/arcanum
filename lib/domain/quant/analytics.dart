/// Composite trend scoring for a single card's price history.
///
/// The engine is deliberately transparent: every number it reports is a closed
/// form statistic (moving averages, Wilder's RSI, OLS on log prices, Holt's
/// linear trend, a local-linear-trend Kalman filter). There is no machine
/// learning, no black box, and no look-ahead - a value reported for day `t` is
/// computed from days `<= t` only, except for the Kalman smoother, which is a
/// *retrospective* description of the window rather than a trading signal.
library;

import 'dart:math' as math;

import 'indicators.dart';
import 'kalman.dart';
import 'models.dart';

/// Weights of the eight score components. They sum to exactly 1.0.
const List<double> _weights = <double>[
  0.20, // OLS log-price trend
  0.15, // Kalman slope
  0.15, // 30-day momentum
  0.12, // MACD histogram
  0.13, // RSI(14)
  0.10, // SMA20 vs SMA50
  0.05, // Bollinger %B
  0.10, // Holt 14-day forecast vs price
];

/// Robust modified z-score above which a daily move is reported as an anomaly.
const double _anomalyThreshold = 3.5;

/// Fraction of the window that must carry prices before the score is trusted.
const double _thinDataCoverage = 0.6;

/// Number of observations below which no trend is reported at all.
const int _minimumObservationsForTrend = 3;

/// Smallest daily log-return dispersion that is treated as a real measurement.
///
/// Below it the series is deterministic to within floating point, and any
/// ratio built on that dispersion (risk-adjusted momentum, structural-break
/// detection) would be meaningless noise amplified by division by ~0.
const double _minimumDispersion = 1e-9;

/// Hyperbolic tangent, which `dart:math` does not provide.
///
/// Saturates at +/-1 outside +/-20 so that a pathological input cannot make
/// `exp` overflow.
double _tanh(double x) {
  if (x.isNaN) return 0;
  if (x >= 20) return 1;
  if (x <= -20) return -1;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

/// Squashes [x] into `-1..1`, treating [scale] as one unit of "signal".
double _squash(double x, double scale) => scale > 0 ? _tanh(x / scale) : 0;

/// `(exp(365 * slope) - 1) * 100`, guarding the overflow of `exp`.
double _annualizedPct(double slope) {
  if (!slope.isFinite) return 0;
  final exponent = (365 * slope).clamp(-700.0, 700.0);
  final growth = math.exp(exponent);
  if (!growth.isFinite) return 0;
  return (growth - 1) * 100;
}

/// Sorts, de-duplicates and normalises raw input into usable observations.
///
/// Non-finite and non-positive prices are dropped (they cannot be logged),
/// dates are truncated to UTC midnight, the result is sorted by date, and when
/// two points land on the same day the later one wins.
List<PricePoint> _sanitize(List<PricePoint> input) {
  final indexed = <_IndexedPoint>[];
  for (var i = 0; i < input.length; i++) {
    final point = input[i];
    final price = point.price;
    if (!price.isFinite || price <= 0) continue;
    indexed.add(_IndexedPoint(
      i,
      PricePoint(
        DateTime.utc(point.date.year, point.date.month, point.date.day),
        price,
      ),
    ));
  }
  indexed.sort((a, b) {
    final byDate = a.point.date.compareTo(b.point.date);
    return byDate != 0 ? byDate : a.index.compareTo(b.index);
  });
  final out = <PricePoint>[];
  for (final entry in indexed) {
    if (out.isNotEmpty && out.last.date == entry.point.date) {
      out[out.length - 1] = entry.point;
    } else {
      out.add(entry.point);
    }
  }
  return out;
}

/// Helper carrying the original position of a point, so that sorting is stable.
class _IndexedPoint {
  /// Position of the point in the caller's list.
  final int index;

  /// The normalised point.
  final PricePoint point;

  /// Creates an indexed point.
  const _IndexedPoint(this.index, this.point);
}

/// The result returned when there is nothing to analyse.
CardAnalytics _emptyResult(int window) => CardAnalytics(
      currentPrice: null,
      trendScore: 50,
      direction: TrendDirection.flat,
      confidence: 0,
      headline: 'No data',
      summary: 'No usable price history was supplied, so no trend can be '
          'estimated. Prices must be finite and greater than zero.',
      anomalies: const <AnomalyFlag>[],
      readings: const <IndicatorReading>[],
      effectiveSamples: 0,
      windowDays: window,
      thinData: true,
      series: const <PricePoint>[],
    );

/// Maps a composite score onto its direction bucket.
TrendDirection _directionFor(double score) {
  if (score >= 65) return TrendDirection.rising;
  if (score >= 55) return TrendDirection.slightlyRising;
  if (score >= 45) return TrendDirection.flat;
  if (score >= 35) return TrendDirection.slightlyFalling;
  return TrendDirection.falling;
}

/// Short label for a direction bucket.
String _directionLabel(TrendDirection direction) {
  switch (direction) {
    case TrendDirection.rising:
      return 'Rising';
    case TrendDirection.slightlyRising:
      return 'Slightly rising';
    case TrendDirection.flat:
      return 'Flat';
    case TrendDirection.slightlyFalling:
      return 'Slightly falling';
    case TrendDirection.falling:
      return 'Falling';
  }
}

/// Plain-English confidence band for a `0..1` confidence value.
String _confidenceWord(double confidence) {
  if (confidence < 0.10) return 'very low';
  if (confidence < 0.25) return 'low';
  if (confidence < 0.45) return 'moderate';
  if (confidence < 0.70) return 'high';
  return 'very high';
}

/// Signed percentage, clamped so that a runaway value cannot produce a
/// kilobyte-long string.
String _signedPct(double value, {int decimals = 1}) {
  if (!value.isFinite) return 'n/a';
  final clamped = value.clamp(-99999.0, 99999.0);
  final sign = clamped >= 0 ? '+' : '-';
  return '$sign${clamped.abs().toStringAsFixed(decimals)}%';
}

/// Unsigned percentage, clamped like [_signedPct].
String _plainPct(double value, {int decimals = 1}) {
  if (!value.isFinite) return 'n/a';
  return '${value.clamp(0.0, 99999.0).toStringAsFixed(decimals)}%';
}

/// Builds the indicator rows shown in the UI panel.
List<IndicatorReading> _buildReadings({
  required double score,
  required TrendDirection direction,
  required double? rsi,
  required MacdResult? macdResult,
  required BollingerBands? bands,
  required double? sma20,
  required double? sma50,
  required double? mom30,
  required double? mom90,
  required double? volatility,
  required double? drawdown,
  required KalmanTrend? kalman,
  required List<AnomalyFlag> anomalies,
  required double price,
}) {
  final readings = <IndicatorReading>[
    IndicatorReading(
      label: 'Trend score',
      value: '${score.round()} / 100',
      interpretation: _directionLabel(direction),
      signal: ((score - 50) / 50).clamp(-1.0, 1.0),
    ),
  ];

  if (rsi != null) {
    final String interpretation;
    if (rsi >= 70) {
      interpretation = 'Overbought';
    } else if (rsi <= 30) {
      interpretation = 'Oversold';
    } else if (rsi >= 55) {
      interpretation = 'Bullish bias';
    } else if (rsi <= 45) {
      interpretation = 'Bearish bias';
    } else {
      interpretation = 'Neutral';
    }
    readings.add(IndicatorReading(
      label: 'RSI (14)',
      value: rsi.toStringAsFixed(1),
      interpretation: interpretation,
      signal: interpretation == 'Neutral'
          ? null
          : ((rsi - 50) / 50).clamp(-1.0, 1.0),
    ));
  }

  if (macdResult != null && price > 0) {
    final relative = macdResult.histogram / price;
    final percent = relative * 100;
    final String interpretation;
    if (percent.abs() < 0.05) {
      interpretation = 'Flat';
    } else if (percent > 0) {
      interpretation = 'Bullish momentum';
    } else {
      interpretation = 'Bearish momentum';
    }
    readings.add(IndicatorReading(
      label: 'MACD (12,26,9)',
      value: '${_signedPct(percent, decimals: 2)} of price',
      interpretation: interpretation,
      signal: interpretation == 'Flat' ? null : _squash(relative, 0.02),
    ));
  }

  if (bands != null) {
    final String interpretation;
    if (bands.upper - bands.lower < 1e-12) {
      interpretation = 'Band has no width';
    } else if (bands.percentB > 1) {
      interpretation = 'Above the upper band';
    } else if (bands.percentB < 0) {
      interpretation = 'Below the lower band';
    } else if (bands.percentB >= 0.5) {
      interpretation = 'Upper half of the band';
    } else {
      interpretation = 'Lower half of the band';
    }
    readings.add(IndicatorReading(
      label: 'Bollinger %B (20,2)',
      value: bands.percentB.toStringAsFixed(2),
      interpretation: interpretation,
      signal: ((bands.percentB - 0.5) * 2).clamp(-1.0, 1.0),
    ));
    readings.add(IndicatorReading(
      label: 'Bollinger bandwidth (20,2)',
      value: _plainPct(bands.bandwidth * 100),
      interpretation: bands.bandwidth < 0.08
          ? 'Compressed range'
          : (bands.bandwidth > 0.35 ? 'Very wide range' : 'Normal range'),
    ));
  }

  if (sma20 != null && sma50 != null && sma50 > 0) {
    final spread = (sma20 / sma50 - 1) * 100;
    final String interpretation;
    if (spread.abs() < 0.25) {
      interpretation = 'Averages are level';
    } else if (spread > 0) {
      interpretation = 'Short average above the long average';
    } else {
      interpretation = 'Short average below the long average';
    }
    readings.add(IndicatorReading(
      label: 'SMA 20 vs SMA 50',
      value: _signedPct(spread, decimals: 2),
      interpretation: interpretation,
      signal: spread.abs() < 0.25 ? null : _squash(spread / 100, 0.05),
    ));
  }

  if (mom30 != null) {
    readings.add(IndicatorReading(
      label: 'Momentum (30d)',
      value: _signedPct(mom30),
      interpretation: mom30.abs() < 1
          ? 'Little change'
          : (mom30 > 0 ? 'Price higher than 30 days ago' : 'Price lower than 30 days ago'),
      signal: _squash(mom30 / 100, 0.15),
    ));
  }

  if (mom90 != null) {
    readings.add(IndicatorReading(
      label: 'Momentum (90d)',
      value: _signedPct(mom90),
      interpretation: mom90.abs() < 1
          ? 'Little change'
          : (mom90 > 0 ? 'Price higher than 90 days ago' : 'Price lower than 90 days ago'),
      signal: _squash(mom90 / 100, 0.15),
    ));
  }

  if (volatility != null) {
    readings.add(IndicatorReading(
      label: 'Volatility (annualised)',
      value: _plainPct(volatility),
      interpretation: volatility < 20
          ? 'Low'
          : (volatility < 45 ? 'Moderate' : 'High'),
    ));
  }

  if (drawdown != null) {
    readings.add(IndicatorReading(
      label: 'Max drawdown',
      value: _plainPct(drawdown),
      interpretation: drawdown < 10
          ? 'Shallow'
          : (drawdown < 30 ? 'Moderate' : 'Deep'),
    ));
  }

  if (kalman != null) {
    readings.add(IndicatorReading(
      label: 'Trend (Kalman, annualised)',
      value: _signedPct(kalman.trendAnnualPct),
      interpretation: kalman.trendAnnualPct.abs() < 5
          ? 'No clear drift'
          : (kalman.trendAnnualPct > 0 ? 'Upward drift' : 'Downward drift'),
      signal: _squash(kalman.slope * 365, 0.30),
    ));
  }

  if (anomalies.isNotEmpty) {
    final kinds = <String>{for (final a in anomalies) a.kind}.toList()..sort();
    readings.add(IndicatorReading(
      label: 'Unusual moves',
      value: '${anomalies.length} flagged',
      interpretation: kinds.join(', '),
    ));
  }

  return readings;
}

/// Analyses a card's price history and returns a fully populated
/// [CardAnalytics].
///
/// [points] may be unsorted, may contain duplicate days, and may contain
/// non-finite or non-positive prices; all of that is cleaned up first. Only the
/// last [windowDays] calendar days are analysed.
///
/// The analysis series is the raw observed prices when every day in the window
/// carries a price, and the Kalman-smoothed path evaluated at the observation
/// timestamps when days are missing. Realised statistics - momentum,
/// volatility, drawdown and anomalies - always come from the raw observations,
/// because smoothing would understate risk and erase the very spikes the
/// anomaly detector exists to find.
///
/// This function never throws: an empty, single-point, flat or corrupt input
/// yields a result whose fields are null or neutral rather than an exception.
CardAnalytics analyzeSeries(
  List<PricePoint> points, {
  int windowDays = 365,
  int forecastHorizon = 30,
}) {
  final window = windowDays > 0 ? windowDays : 365;
  final horizon = forecastHorizon > 0 ? forecastHorizon : 0;

  final clean = _sanitize(points);
  if (clean.isEmpty) return _emptyResult(window);

  final lastDate = clean.last.date;
  final cutoff = lastDate.subtract(Duration(days: window));
  var observations = <PricePoint>[
    for (final point in clean)
      if (!point.date.isBefore(cutoff)) point,
  ];
  if (observations.isEmpty) observations = <PricePoint>[clean.last];

  final nEff = observations.length;
  final coverage = (nEff / window).clamp(0.0, 1.0);
  final thinData = coverage < _thinDataCoverage;

  final firstDate = observations.first.date;
  var gridLength = lastDate.difference(firstDate).inDays + 1;
  if (gridLength < 1) gridLength = 1;

  final gridObservations = <int, double>{};
  for (final point in observations) {
    gridObservations[point.date.difference(firstDate).inDays] =
        math.log(point.price);
  }
  final rawPrices = <double>[for (final point in observations) point.price];
  final hasMissingDays = nEff < gridLength;

  final returns = logReturns(rawPrices);
  final sigmaDaily = sampleStdDev(returns);
  // A structural break is only meaningful when the series has a measurable
  // daily dispersion to be extreme relative to. On a perfectly deterministic
  // ramp sigma is ~1e-16 and every single day would "exceed 5 sigma".
  final hasUsableDispersion = sigmaDaily != null && sigmaDaily > _minimumDispersion;
  final breakThreshold = hasUsableDispersion ? 5 * sigmaDaily : null;

  final run = runLocalLinearTrend(
    gridLength: gridLength,
    observations: gridObservations,
    breakThreshold: breakThreshold,
  );

  final analysisPrices = <double>[];
  for (final point in observations) {
    final gridIndex = point.date.difference(firstDate).inDays;
    if (!hasMissingDays) {
      analysisPrices.add(point.price);
      continue;
    }
    final state = run.smoothed[gridIndex];
    final smoothed = safeExp(state[0]);
    analysisPrices.add(smoothed.isFinite && smoothed > 0 ? smoothed : point.price);
  }

  final series = <PricePoint>[
    for (var i = 0; i < nEff; i++)
      PricePoint(observations[i].date, analysisPrices[i]),
  ];
  final price = rawPrices.last;

  // --- Indicators on the analysis series -----------------------------------
  final sma20 = sma(analysisPrices, 20);
  final sma50 = sma(analysisPrices, 50);
  final rsi14 = rsiWilder(analysisPrices, 14);
  final macdResult = macd(analysisPrices);
  final bands = bollingerBands(analysisPrices);
  final regression = olsLogTrend(analysisPrices, window: 90);
  final forecast =
      horizon > 0 ? holtLinearForecast(analysisPrices, horizon: horizon) : null;

  // --- Realised statistics on the raw observations -------------------------
  final volatility = annualizedVolatility(rawPrices);
  final drawdown = nEff >= 2 ? maxDrawdownPct(rawPrices) : null;
  final mom7 = momentumPct(observations, 7);
  final mom30 = momentumPct(observations, 30);
  final mom90 = momentumPct(observations, 90);
  final meanReturn = mean(returns);
  final riskAdjusted = (hasUsableDispersion && meanReturn != null)
      ? (kDaysPerYear * meanReturn - 0.04) / (sigmaDaily * math.sqrt(kDaysPerYear))
      : null;

  // --- Kalman reading ------------------------------------------------------
  final lastState = run.lastSmoothed;
  final lastCovariance = run.lastSmoothedCovariance;
  final kalmanSlope = lastState[1];
  final slopeVariance = lastCovariance[2] < 0 ? 0.0 : lastCovariance[2];
  final kalman = KalmanTrend(
    lastState[0],
    kalmanSlope,
    slopeVariance,
    <double>[for (final state in run.smoothed) state[0]],
    _annualizedPct(kalmanSlope),
    1.96 * math.sqrt(slopeVariance) * kDaysPerYear,
  );

  // --- Anomalies -----------------------------------------------------------
  final anomalies = detectAnomalies(observations, threshold: _anomalyThreshold);
  final observationByGridIndex = <int, int>{
    for (var i = 0; i < nEff; i++)
      observations[i].date.difference(firstDate).inDays: i,
  };
  final seen = <String>{
    for (final anomaly in anomalies) '${anomaly.kind}|${anomaly.date}',
  };
  for (final gridIndex in run.breakIndices) {
    final index = observationByGridIndex[gridIndex];
    if (index == null) continue;
    final point = observations[index];
    final key = 'gap|${point.date}';
    if (seen.contains(key)) continue;
    seen.add(key);
    final change = index > 0 && observations[index - 1].price > 0
        ? (point.price / observations[index - 1].price - 1) * 100
        : 0.0;
    anomalies.add(AnomalyFlag(
      date: point.date,
      price: point.price,
      zScore: 0,
      kind: 'gap',
      description: 'Structural break: price moved '
          '${_signedPct(change)} in a single day, far outside the recent '
          'range, so the trend model was re-based.',
    ));
  }
  anomalies.sort((a, b) => a.date.compareTo(b.date));

  // --- Composite score -----------------------------------------------------
  final holtAt14 = forecast == null || forecast.point.isEmpty
      ? null
      : (forecast.point.length >= 14
          ? forecast.point[13]
          : forecast.point.last);
  final rSquared = regression?.rSquared ?? 0.0;
  final components = <double>[
    regression == null
        ? 0.0
        : _squash(regression.slope * kDaysPerYear, 0.30) *
            rSquared.clamp(0.0, 1.0) *
            (regression.tStat.abs() < 2 ? 0.3 : 1.0),
    _squash(kalman.slope * kDaysPerYear, 0.30),
    mom30 == null ? 0.0 : _squash(mom30 / 100.0, 0.15),
    (macdResult == null || !(price > 0))
        ? 0.0
        : _squash(macdResult.histogram / price, 0.02),
    rsi14 == null ? 0.0 : _squash(rsi14 - 50, 20),
    (sma20 == null || sma50 == null || !(sma50 > 0))
        ? 0.0
        : _squash(sma20 / sma50 - 1, 0.05),
    bands == null ? 0.0 : _squash(bands.percentB - 0.5, 0.35),
    (holtAt14 == null || !(price > 0))
        ? 0.0
        : _squash(holtAt14 / price - 1, 0.10),
  ];
  var rawSignal = 0.0;
  for (var i = 0; i < _weights.length; i++) {
    rawSignal += _weights[i] * components[i];
  }
  final finiteVolatility =
      volatility != null && volatility.isFinite ? volatility : 0.0;
  final sigmaAnnual = finiteVolatility / 100.0;
  final confidence =
      rSquared * coverage * (1 / (1 + sigmaAnnual / 0.60));
  final score = (50 + 50 * confidence * rawSignal).clamp(0.0, 100.0);
  final direction = _directionFor(score);

  // --- Narrative -----------------------------------------------------------
  final String headline;
  final String summary;
  if (nEff < _minimumObservationsForTrend) {
    headline = 'Insufficient data';
    summary = 'Only $nEff price observation${nEff == 1 ? '' : 's'} '
        '${nEff == 1 ? 'is' : 'are'} available in the last $window days, '
        'which is not enough to estimate a trend. The price shown is the '
        'latest observation.';
  } else {
    headline = _directionLabel(direction);
    final sentences = <String>[
      '$headline, ${_confidenceWord(confidence)} confidence '
          '(trend score ${score.round()}/100).',
    ];
    final momentum = mom90 ?? mom30 ?? mom7;
    final momentumDays = mom90 != null ? 90 : (mom30 != null ? 30 : 7);
    if (momentum != null) {
      final strength = regression == null
          ? null
          : (regression.rSquared >= 0.5
              ? 'statistically strong'
              : (regression.rSquared >= 0.2
                  ? 'statistically weak'
                  : 'statistically very weak'));
      final move = momentum.abs() < 0.05
          ? 'The price is unchanged over $momentumDays days'
          : '${momentum >= 0 ? 'Up' : 'Down'} '
              '${momentum.abs().toStringAsFixed(1)}% over $momentumDays days';
      sentences.add(
        '$move${strength == null ? '.' : '; the trend is $strength '
            '(R-squared ${rSquared.toStringAsFixed(2)}).'}',
      );
    }
    final caveats = <String>[];
    if (thinData) {
      caveats.add('Only $nEff of the last $window days carry prices, so this '
          'reading is low trust.');
    }
    if (anomalies.isNotEmpty) {
      caveats.add('${anomalies.length} unusual '
          'move${anomalies.length == 1 ? '' : 's'} '
          '${anomalies.length == 1 ? 'was' : 'were'} flagged in the window.');
    }
    if (forecast != null) {
      caveats.add('The forecast is a statistical range, not a prediction.');
    }
    if (caveats.isNotEmpty) sentences.add(caveats.join(' '));
    summary = sentences.join(' ');
  }

  final readings = _buildReadings(
    score: score,
    direction: direction,
    rsi: rsi14,
    macdResult: macdResult,
    bands: bands,
    sma20: sma20,
    sma50: sma50,
    mom30: mom30,
    mom90: mom90,
    volatility: volatility,
    drawdown: drawdown,
    // The smoothed slope of a one- or two-point series is arithmetic, not
    // evidence, so it is kept out of the panel.
    kalman: nEff >= _minimumObservationsForTrend ? kalman : null,
    anomalies: anomalies,
    price: price,
  );

  return CardAnalytics(
    currentPrice: price,
    trendScore: score,
    direction: direction,
    confidence: confidence.isFinite ? confidence.clamp(0.0, 1.0) : 0.0,
    headline: headline,
    summary: summary,
    trendAnnualPct: kalman.trendAnnualPct,
    rsi14: rsi14,
    macd: macdResult,
    bollinger: bands,
    regression90: regression,
    momentum7: mom7,
    momentum30: mom30,
    momentum90: mom90,
    volatilityAnnualized: volatility,
    maxDrawdown: drawdown,
    riskAdjustedMomentum:
        riskAdjusted != null && riskAdjusted.isFinite ? riskAdjusted : null,
    forecast: forecast,
    kalman: kalman,
    anomalies: List<AnomalyFlag>.unmodifiable(anomalies),
    readings: List<IndicatorReading>.unmodifiable(readings),
    effectiveSamples: nEff,
    windowDays: window,
    thinData: thinData,
    series: List<PricePoint>.unmodifiable(series),
  );
}
