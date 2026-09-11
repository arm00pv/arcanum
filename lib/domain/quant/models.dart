/// Immutable value types for the Arcanum on-device price-analytics engine.
///
/// This library is pure Dart: it imports nothing but `dart:math`, holds no
/// Flutter, network or storage reference, and can therefore run inside an
/// isolate, a background task or a plain unit test.
///
/// Every field that can legitimately be undefined for a given price history is
/// nullable instead of being filled with a sentinel such as `0` or `-1`, so a
/// caller can always tell "not computable" apart from "computed as zero".
library;

/// A single observed price for one calendar day.
///
/// This is the only input type the engine accepts. Points are expected to be
/// sorted by date (they do not have to be) and are normalised internally.
class PricePoint {
  /// The calendar day this price belongs to, normalised to UTC midnight.
  ///
  /// [analyzeSeries] normalises every incoming date to UTC midnight before use,
  /// so two points that differ only by a time-of-day component collapse onto the
  /// same day. Pass UTC dates to preserve exactly the day you intended.
  final DateTime date;

  /// The observed price, in whatever currency the caller is displaying.
  ///
  /// Supply a finite, strictly positive value. Non-finite, zero and negative
  /// prices are dropped by [analyzeSeries] because log-returns are undefined
  /// for them.
  final double price;

  /// Creates a price observation.
  const PricePoint(this.date, this.price);

  @override
  bool operator ==(Object other) =>
      other is PricePoint && other.date == date && other.price == price;

  @override
  int get hashCode => Object.hash(date, price);

  @override
  String toString() => 'PricePoint(${date.toIso8601String()}, $price)';
}

/// Coarse direction bucket derived from the composite trend score.
///
/// The buckets are fixed and documented so that the UI and the summary text can
/// never disagree about what a score means.
enum TrendDirection {
  /// Score below 35: the weight of evidence points down.
  falling,

  /// Score 35-44: mildly negative.
  slightlyFalling,

  /// Score 45-54: no usable directional signal.
  flat,

  /// Score 55-64: mildly positive.
  slightlyRising,

  /// Score 65 and above: the weight of evidence points up.
  rising,
}

/// One row of the "indicators" panel, ready to render.
///
/// [value] is pre-formatted for display; [signal] is the machine-readable
/// version of the same reading, signed so that positive is bullish.
class IndicatorReading {
  /// Human-readable indicator name, e.g. `RSI (14)`.
  final String label;

  /// Pre-formatted value, e.g. `58.3` or `+2.41% of price`.
  final String value;

  /// Short plain-English reading, e.g. `Neutral` or `Overbought`.
  ///
  /// Null when the indicator carries no interpretation.
  final String? interpretation;

  /// Bullish/bearish signal in `-1..1`, or null when the reading is neutral or
  /// not applicable.
  final double? signal;

  /// Creates an indicator row.
  const IndicatorReading({
    required this.label,
    required this.value,
    this.interpretation,
    this.signal,
  });

  @override
  String toString() => 'IndicatorReading($label: $value'
      '${interpretation == null ? '' : ' ($interpretation)'})';
}

/// A single statistically unusual observation inside the analysis window.
class AnomalyFlag {
  /// The day the unusual price was observed.
  final DateTime date;

  /// The observed price on that day.
  final double price;

  /// Robust modified z-score of that day's log return
  /// (`0.6745 * (r - median) / MAD`). Zero for gap flags, where no return
  /// z-score applies.
  final double zScore;

  /// One of `spike`, `crash` or `gap`.
  final String kind;

  /// Plain-English description suitable for direct display.
  final String description;

  /// Creates an anomaly flag.
  const AnomalyFlag({
    required this.date,
    required this.price,
    required this.zScore,
    required this.kind,
    required this.description,
  });

  @override
  String toString() => 'AnomalyFlag($kind, $date, z=$zScore)';
}

/// Bollinger band reading for the latest observation.
class BollingerBands {
  /// Simple moving average over the band period (20 by default).
  final double middle;

  /// `middle + mult * sigma`, where sigma is the *population* standard deviation.
  final double upper;

  /// `middle - mult * sigma`.
  final double lower;

  /// Position of the latest price inside the band:
  /// `(p - lower) / (upper - lower)`. Exactly `0.5` when the band has zero width.
  final double percentB;

  /// Band width relative to the middle band: `(upper - lower) / middle`.
  final double bandwidth;

  /// Creates a Bollinger reading.
  const BollingerBands(
      this.middle, this.upper, this.lower, this.percentB, this.bandwidth);

  @override
  String toString() => 'BollingerBands(mid=$middle, up=$upper, lo=$lower, '
      '%B=$percentB, bw=$bandwidth)';
}

/// MACD reading for the latest observation.
class MacdResult {
  /// Fast EMA minus slow EMA (12 and 26 by default).
  final double macd;

  /// Signal line: 9-period EMA of the MACD line.
  final double signal;

  /// `macd - signal`.
  final double histogram;

  /// Creates a MACD reading.
  const MacdResult(this.macd, this.signal, this.histogram);

  @override
  String toString() =>
      'MacdResult(macd=$macd, signal=$signal, histogram=$histogram)';
}

/// Ordinary-least-squares fit of `ln(price)` against time.
class RegressionResult {
  /// Fitted slope per day, in log space.
  final double slope;

  /// Fitted intercept, in log space.
  final double intercept;

  /// Coefficient of determination, clamped to `0..1`.
  final double rSquared;

  /// t-statistic of the slope, capped at +/-1e6 for perfectly linear data.
  final double tStat;

  /// Number of observations used in the fit.
  final int n;

  /// Creates a regression result.
  const RegressionResult(
      this.slope, this.intercept, this.rSquared, this.tStat, this.n);

  @override
  String toString() =>
      'RegressionResult(slope=$slope, r2=$rSquared, t=$tStat, n=$n)';
}

/// Holt linear-trend forecast in price space, with Gaussian prediction bands.
class HoltForecast {
  /// Level smoothing parameter chosen by grid search (or 0.3 for short series).
  final double alpha;

  /// Trend smoothing parameter chosen by grid search (or 0.1 for short series).
  final double beta;

  /// Final level, in log space.
  final double level;

  /// Final trend, in log space per day.
  final double trend;

  /// Point forecasts in price space; index 0 is `t+1`.
  final List<double> point;

  /// Lower bound of the 80% prediction interval, in price space.
  final List<double> lower80;

  /// Upper bound of the 80% prediction interval, in price space.
  final List<double> upper80;

  /// Lower bound of the 95% prediction interval, in price space.
  final List<double> lower95;

  /// Upper bound of the 95% prediction interval, in price space.
  final List<double> upper95;

  /// One-step-ahead residual standard deviation, in log space.
  final double sigma;

  /// Creates a Holt forecast.
  const HoltForecast(
    this.alpha,
    this.beta,
    this.level,
    this.trend,
    this.point,
    this.lower80,
    this.upper80,
    this.lower95,
    this.upper95,
    this.sigma,
  );

  @override
  String toString() =>
      'HoltForecast(alpha=$alpha, beta=$beta, sigma=$sigma, h=${point.length})';
}

/// Local-linear-trend Kalman reading for the latest day of the analysis grid.
class KalmanTrend {
  /// RTS-smoothed level (log price) on the final grid day.
  final double level;

  /// RTS-smoothed slope (log price per day) on the final grid day.
  final double slope;

  /// Smoothed variance of [slope].
  final double slopeVariance;

  /// The full RTS-smoothed *log-price* path, one entry per calendar day of the
  /// analysis grid (missing days included), so its length can exceed the number
  /// of observations. Exponentiate an entry to get a price.
  final List<double> smoothed;

  /// `(exp(365 * slope) - 1) * 100`: the smoothed trend expressed as an
  /// annualised percentage.
  final double trendAnnualPct;

  /// Half-width of the 95% confidence interval of the annualised slope.
  final double slopeCi95;

  /// Creates a Kalman reading.
  const KalmanTrend(
    this.level,
    this.slope,
    this.slopeVariance,
    this.smoothed,
    this.trendAnnualPct,
    this.slopeCi95,
  );

  @override
  String toString() =>
      'KalmanTrend(level=$level, slope=$slope, annual=$trendAnnualPct)';
}

/// The complete analysis of one card's price history.
///
/// This object is designed to be rendered directly: [readings] drives the
/// indicators panel, [headline] and [summary] drive the text block, and every
/// nullable field is null exactly when the underlying statistic could not be
/// computed from the available history.
class CardAnalytics {
  /// Latest observed price (never smoothed), or null when there was no input.
  final double? currentPrice;

  /// Composite trend score in `0..100`; 50 is neutral.
  final double trendScore;

  /// Direction bucket implied by [trendScore].
  final TrendDirection direction;

  /// Confidence in `0..1`, driven by fit quality, data coverage and volatility.
  final double confidence;

  /// Very short label, e.g. `Rising`.
  final String headline;

  /// One to three sentences of plain English.
  final String summary;

  /// Annualised trend from the Kalman slope, in percent, or null.
  final double? trendAnnualPct;

  /// Wilder RSI(14) on the analysis series, or null.
  final double? rsi14;

  /// MACD(12,26,9) on the analysis series, or null when history is too short.
  final MacdResult? macd;

  /// Bollinger(20,2) on the analysis series, or null.
  final BollingerBands? bollinger;

  /// OLS log-price trend over the last 90 observations, or null.
  final RegressionResult? regression90;

  /// Percent change over 7 days, or null when history is shorter than that.
  final double? momentum7;

  /// Percent change over 30 days, or null.
  final double? momentum30;

  /// Percent change over 90 days, or null.
  final double? momentum90;

  /// Annualised volatility of realised log returns, in percent, or null.
  final double? volatilityAnnualized;

  /// Maximum peak-to-trough drawdown of observed prices, as a positive percent.
  final double? maxDrawdown;

  /// `(365 * meanDailyReturn - 0.04) / (dailyVol * sqrt(365))`; descriptive only.
  final double? riskAdjustedMomentum;

  /// Holt linear-trend forecast, or null when history is too short.
  final HoltForecast? forecast;

  /// Kalman local-linear-trend reading, or null when there was no input.
  final KalmanTrend? kalman;

  /// Statistically unusual observations, sorted by date.
  final List<AnomalyFlag> anomalies;

  /// Pre-formatted indicator rows for the UI panel.
  final List<IndicatorReading> readings;

  /// Number of real observations inside the window.
  final int effectiveSamples;

  /// Length of the analysis window in days.
  final int windowDays;

  /// True when fewer than 60% of the window's days carry a price.
  ///
  /// The UI is expected to show the price alone in that case: the statistics
  /// are still computed, but they are not trustworthy enough to headline.
  final bool thinData;

  /// The price series the indicators were computed on: the raw observations
  /// when the window is gap-free, or the Kalman-smoothed path evaluated at the
  /// observation timestamps when days are missing.
  final List<PricePoint> series;

  /// Creates an analysis result.
  const CardAnalytics({
    required this.currentPrice,
    required this.trendScore,
    required this.direction,
    required this.confidence,
    required this.headline,
    required this.summary,
    required this.anomalies,
    required this.readings,
    required this.effectiveSamples,
    required this.windowDays,
    required this.thinData,
    required this.series,
    this.trendAnnualPct,
    this.rsi14,
    this.macd,
    this.bollinger,
    this.regression90,
    this.momentum7,
    this.momentum30,
    this.momentum90,
    this.volatilityAnnualized,
    this.maxDrawdown,
    this.riskAdjustedMomentum,
    this.forecast,
    this.kalman,
  });

  @override
  String toString() => 'CardAnalytics($headline, score=${trendScore.round()}, '
      'confidence=$confidence, n=$effectiveSamples/$windowDays)';
}
