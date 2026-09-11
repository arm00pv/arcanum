/// Statistical primitives for the Arcanum price-analytics engine.
///
/// Everything here is pure Dart (`dart:math` only) and total: no function
/// throws on degenerate input, they return `null` or an empty list instead.
/// These helpers are not exported from `quant.dart`; they are public only so
/// that they can be unit-tested directly.
library;

import 'dart:math' as math;

import 'models.dart';

/// Days per year used for every annualisation in the engine.
const double kDaysPerYear = 365;

/// Number of days without a price above which the gap is reported as an anomaly.
const int kGapAnomalyDays = 3;

/// Smallest median absolute deviation that is treated as a usable scale.
///
/// Log returns are O(0.01) in practice, so anything below this is numerical
/// dust from a deterministic series rather than a real dispersion estimate.
const double _minimumMad = 1e-12;

/// `exp` that never overflows: the exponent is clamped to the representable
/// range so that a pathological slope cannot produce a non-finite price.
double safeExp(double x) {
  if (x.isNaN) return double.nan;
  if (x > 709) return double.maxFinite;
  if (x < -745) return 0.0;
  return math.exp(x);
}

/// Arithmetic mean, or null when [values] is empty or contains non-finite data.
double? mean(List<double> values) {
  if (values.isEmpty) return null;
  var sum = 0.0;
  for (final v in values) {
    if (!v.isFinite) return null;
    sum += v;
  }
  final m = sum / values.length;
  return m.isFinite ? m : null;
}

/// Two-pass sample standard deviation (divides by `n - 1`).
///
/// Two passes over the data are used rather than the naive
/// `E[x^2] - E[x]^2` shortcut, which loses all precision when the mean is large
/// relative to the spread - exactly the situation for a log-price series.
double? sampleStdDev(List<double> values) {
  if (values.length < 2) return null;
  final m = mean(values);
  if (m == null) return null;
  var sumSquares = 0.0;
  for (final v in values) {
    final d = v - m;
    sumSquares += d * d;
  }
  final variance = sumSquares / (values.length - 1);
  if (!variance.isFinite || variance < 0) return null;
  return math.sqrt(variance);
}

/// Two-pass population standard deviation (divides by `n`).
///
/// Bollinger's original definition uses the population form; pass [about] to
/// measure dispersion around a value other than the sample mean.
double? populationStdDev(List<double> values, [double? about]) {
  if (values.isEmpty) return null;
  final m = about ?? mean(values);
  if (m == null) return null;
  var sumSquares = 0.0;
  for (final v in values) {
    final d = v - m;
    sumSquares += d * d;
  }
  final variance = sumSquares / values.length;
  if (!variance.isFinite || variance < 0) return null;
  return math.sqrt(variance);
}

/// Median of [values]; the average of the two central values for even counts.
double? median(List<double> values) {
  if (values.isEmpty) return null;
  final sorted = List<double>.of(values)..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Median absolute deviation about [center], which defaults to the median.
double? medianAbsoluteDeviation(List<double> values, [double? center]) {
  if (values.isEmpty) return null;
  final c = center ?? median(values);
  if (c == null) return null;
  return median(<double>[for (final v in values) (v - c).abs()]);
}

/// Consecutive log returns `ln(p_t / p_{t-1})`.
///
/// A non-positive or non-finite price breaks the chain: that return is skipped
/// rather than producing an infinity.
List<double> logReturns(List<double> prices) {
  final out = <double>[];
  for (var i = 1; i < prices.length; i++) {
    final previous = prices[i - 1];
    final current = prices[i];
    if (previous > 0 && current > 0 && previous.isFinite && current.isFinite) {
      final r = math.log(current / previous);
      if (r.isFinite) out.add(r);
    }
  }
  return out;
}

/// Simple moving average of the last [n] values, or null when there are fewer.
double? sma(List<double> values, int n) {
  if (n <= 0 || values.length < n) return null;
  var sum = 0.0;
  for (var i = values.length - n; i < values.length; i++) {
    sum += values[i];
  }
  final result = sum / n;
  return result.isFinite ? result : null;
}

/// Exponential moving average series with `alpha = 2 / (n + 1)`.
///
/// The first entry is seeded with the SMA of the first [n] values, so entry `k`
/// corresponds to input index `n - 1 + k`. Empty when there are fewer than [n]
/// values.
List<double> emaSeries(List<double> values, int n) {
  if (n <= 0 || values.length < n) return const <double>[];
  final alpha = 2.0 / (n + 1);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    sum += values[i];
  }
  var previous = sum / n;
  final out = <double>[previous];
  for (var i = n; i < values.length; i++) {
    previous = alpha * values[i] + (1 - alpha) * previous;
    out.add(previous);
  }
  return out;
}

/// Wilder's RSI over [period] (14 by default), or null when history is shorter
/// than `period + 1` values.
///
/// The first average gain/loss is the simple mean of the first [period]
/// deltas; every later value uses Wilder's smoothing
/// `avg = ((period - 1) * avg + current) / period`.
///
/// Returns 100 when there were only gains (the textbook case). When there is
/// neither a gain nor a loss - a perfectly flat series - it returns the neutral
/// 50 rather than a meaningless 100, because a flat series carries no momentum.
double? rsiWilder(List<double> values, [int period = 14]) {
  if (period <= 0 || values.length < period + 1) return null;
  var gainSum = 0.0;
  var lossSum = 0.0;
  for (var i = 1; i <= period; i++) {
    final delta = values[i] - values[i - 1];
    if (delta > 0) {
      gainSum += delta;
    } else {
      lossSum -= delta;
    }
  }
  var avgGain = gainSum / period;
  var avgLoss = lossSum / period;
  for (var i = period + 1; i < values.length; i++) {
    final delta = values[i] - values[i - 1];
    final gain = delta > 0 ? delta : 0.0;
    final loss = delta < 0 ? -delta : 0.0;
    avgGain = (avgGain * (period - 1) + gain) / period;
    avgLoss = (avgLoss * (period - 1) + loss) / period;
  }
  if (avgLoss <= 0) {
    return avgGain > 0 ? 100.0 : 50.0;
  }
  final rs = avgGain / avgLoss;
  final rsi = 100 - 100 / (1 + rs);
  return rsi.isFinite ? rsi : 100.0;
}

/// Bollinger bands over [period] (20) with [mult] (2) population sigmas.
///
/// Returns null when there are fewer than [period] values. `percentB` falls
/// back to 0.5 when the band collapses to zero width; `bandwidth` falls back to
/// 0 when the middle band is zero.
BollingerBands? bollingerBands(List<double> values,
    {int period = 20, double mult = 2}) {
  if (period <= 1 || values.length < period) return null;
  final window = values.sublist(values.length - period);
  final middle = mean(window);
  if (middle == null) return null;
  final sigma = populationStdDev(window, middle);
  if (sigma == null) return null;
  final upper = middle + mult * sigma;
  final lower = middle - mult * sigma;
  final range = upper - lower;
  final last = values.last;
  final percentB = range.abs() < 1e-12 ? 0.5 : (last - lower) / range;
  final bandwidth = middle.abs() < 1e-12 ? 0.0 : range / middle.abs();
  return BollingerBands(
    middle,
    upper,
    lower,
    percentB.isFinite ? percentB : 0.5,
    bandwidth.isFinite ? bandwidth : 0.0,
  );
}

/// MACD(fast, slow, signal) evaluated at the latest observation.
///
/// Requires `slow + signalPeriod - 1` values; null otherwise. The signal line
/// is an EMA of the MACD line seeded with the SMA of its first `signalPeriod`
/// values.
MacdResult? macd(List<double> values,
    {int fast = 12, int slow = 26, int signalPeriod = 9}) {
  if (fast <= 0 || slow <= fast || signalPeriod <= 0) return null;
  if (values.length < slow + signalPeriod - 1) return null;
  final fastEma = emaSeries(values, fast);
  final slowEma = emaSeries(values, slow);
  if (fastEma.isEmpty || slowEma.isEmpty) return null;
  final macdLine = <double>[];
  for (var i = 0; i < slowEma.length; i++) {
    final fastIndex = slow - fast + i;
    if (fastIndex < 0 || fastIndex >= fastEma.length) return null;
    macdLine.add(fastEma[fastIndex] - slowEma[i]);
  }
  final signalLine = emaSeries(macdLine, signalPeriod);
  if (signalLine.isEmpty) return null;
  final macdValue = macdLine.last;
  final signalValue = signalLine.last;
  if (!macdValue.isFinite || !signalValue.isFinite) return null;
  return MacdResult(macdValue, signalValue, macdValue - signalValue);
}

/// OLS fit of `ln(price)` against `x = 0..n-1` over the last [window]
/// observations (all of them when [window] is null or too large).
///
/// Returns null when fewer than two usable (strictly positive) prices are
/// available. `tStat` is 0 when `n <= 2`; for a perfect fit, where the
/// standard error is 0, it is capped at +/-1e6 instead of being infinite.
RegressionResult? olsLogTrend(List<double> prices, {int? window}) {
  var values = prices;
  if (window != null && window > 0 && values.length > window) {
    values = values.sublist(values.length - window);
  }
  final n = values.length;
  if (n < 2) return null;
  final y = <double>[];
  for (final p in values) {
    if (!p.isFinite || p <= 0) return null;
    y.add(math.log(p));
  }
  final xBar = (n - 1) / 2;
  final yBar = mean(y);
  if (yBar == null) return null;
  var sxx = 0.0;
  var sxy = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = i - xBar;
    sxx += dx * dx;
    sxy += dx * (y[i] - yBar);
  }
  if (!(sxx > 0)) return null;
  final slope = sxy / sxx;
  final intercept = yBar - slope * xBar;
  var ssRes = 0.0;
  var ssTot = 0.0;
  for (var i = 0; i < n; i++) {
    final residual = y[i] - intercept - slope * i;
    ssRes += residual * residual;
    final deviation = y[i] - yBar;
    ssTot += deviation * deviation;
  }
  final rSquared = ssTot <= 0 ? 0.0 : (1 - ssRes / ssTot).clamp(0.0, 1.0);
  double tStat;
  if (n <= 2) {
    tStat = 0.0;
  } else {
    final se = math.sqrt(ssRes / ((n - 2) * sxx));
    if (!se.isFinite || se <= 0) {
      tStat = slope == 0 ? 0.0 : (slope > 0 ? 1e6 : -1e6);
    } else {
      tStat = (slope / se).clamp(-1e6, 1e6);
    }
  }
  return RegressionResult(slope, intercept, rSquared, tStat, n);
}

/// One-step-ahead SSE of a Holt linear fit with the given parameters.
double _holtSse(List<double> y, double alpha, double beta) {
  var level = y[0];
  var trend = y[1] - y[0];
  var sse = 0.0;
  for (var t = 1; t < y.length; t++) {
    final error = y[t] - (level + trend);
    sse += error * error;
    final newLevel = alpha * y[t] + (1 - alpha) * (level + trend);
    final newTrend = beta * (newLevel - level) + (1 - beta) * trend;
    level = newLevel;
    trend = newTrend;
  }
  return sse;
}

/// Runs Holt's recursion once and returns `(level, trend, residuals)`.
(double, double, List<double>) _holtFit(
    List<double> y, double alpha, double beta) {
  var level = y[0];
  var trend = y[1] - y[0];
  final residuals = <double>[];
  for (var t = 1; t < y.length; t++) {
    residuals.add(y[t] - (level + trend));
    final newLevel = alpha * y[t] + (1 - alpha) * (level + trend);
    final newTrend = beta * (newLevel - level) + (1 - beta) * trend;
    level = newLevel;
    trend = newTrend;
  }
  return (level, trend, residuals);
}

/// Holt's linear trend on `ln(price)`, with prediction intervals.
///
/// `alpha` and `beta` are chosen by a grid search over
/// `{0.05, 0.10, ..., 0.95}^2` (361 fits) that minimises the one-step-ahead
/// sum of squared errors; series shorter than 30 observations use the
/// conventional `alpha = 0.3, beta = 0.1` instead, because a grid search over so
/// few points overfits. Pass both [alpha] and [beta] to bypass the search.
///
/// The intervals use
/// `sigma_h^2 = sigma^2 * (1 + sum_{j=1}^{h-1} (alpha + beta * j)^2)`, so
/// uncertainty grows with the horizon. They are a statistical range, not a
/// prediction. Returns null when there are fewer than 3 observations or when
/// [horizon] is not positive.
HoltForecast? holtLinearForecast(List<double> prices,
    {int horizon = 30, double? alpha, double? beta}) {
  final n = prices.length;
  if (n < 3 || horizon < 1) return null;
  final y = <double>[];
  for (final p in prices) {
    if (!p.isFinite || p <= 0) return null;
    y.add(math.log(p));
  }
  var a = alpha ?? 0.3;
  var b = beta ?? 0.1;
  if (alpha == null || beta == null) {
    if (n < 30) {
      a = 0.3;
      b = 0.1;
    } else {
      var bestSse = double.infinity;
      for (var i = 1; i <= 19; i++) {
        final candidateAlpha = i * 0.05;
        for (var j = 1; j <= 19; j++) {
          final candidateBeta = j * 0.05;
          final sse = _holtSse(y, candidateAlpha, candidateBeta);
          if (sse < bestSse) {
            bestSse = sse;
            a = candidateAlpha;
            b = candidateBeta;
          }
        }
      }
    }
  }
  final fit = _holtFit(y, a, b);
  final level = fit.$1;
  final trend = fit.$2;
  final residuals = fit.$3;
  final m = residuals.length;
  var sumSquares = 0.0;
  for (final e in residuals) {
    sumSquares += e * e;
  }
  final variance = m > 0 ? sumSquares / m : 0.0;
  final sigma = variance > 0 ? math.sqrt(variance) : 0.0;

  final point = <double>[];
  final lower80 = <double>[];
  final upper80 = <double>[];
  final lower95 = <double>[];
  final upper95 = <double>[];
  var cumulative = 0.0;
  for (var h = 1; h <= horizon; h++) {
    if (h > 1) {
      final term = a + b * (h - 1);
      cumulative += term * term;
    }
    final sigmaH = sigma * math.sqrt(1 + cumulative);
    final forecast = level + h * trend;
    point.add(safeExp(forecast));
    lower80.add(safeExp(forecast - 1.2816 * sigmaH));
    upper80.add(safeExp(forecast + 1.2816 * sigmaH));
    lower95.add(safeExp(forecast - 1.96 * sigmaH));
    upper95.add(safeExp(forecast + 1.96 * sigmaH));
  }
  return HoltForecast(
      a, b, level, trend, point, lower80, upper80, lower95, upper95, sigma);
}

/// Annualised volatility of realised log returns, in percent, or null when
/// there are fewer than two returns.
///
/// `sigma_d * sqrt(365) * 100`, with `sigma_d` the sample standard deviation of
/// daily log returns.
double? annualizedVolatility(List<double> prices) {
  final returns = logReturns(prices);
  final sigmaDaily = sampleStdDev(returns);
  if (sigmaDaily == null) return null;
  final annual = sigmaDaily * math.sqrt(kDaysPerYear) * 100;
  return annual.isFinite ? annual : null;
}

/// Maximum peak-to-trough drawdown of [prices] as a positive percentage.
///
/// Returns 0 for an empty or never-declining series, and null only when the
/// input contains no usable price at all.
double? maxDrawdownPct(List<double> prices) {
  double? peak;
  var worst = 0.0;
  for (final p in prices) {
    if (!p.isFinite || p <= 0) continue;
    if (peak == null || p > peak) peak = p;
    final drawdown = (peak - p) / peak;
    if (drawdown > worst) worst = drawdown;
  }
  if (peak == null) return null;
  return worst * 100;
}

/// Percent change from the last observation at or before `latest - days` to the
/// latest observation, or null when the history does not reach back that far.
///
/// The comparison uses real observations only - never an interpolated price.
double? momentumPct(List<PricePoint> observations, int days) {
  if (days <= 0 || observations.length < 2) return null;
  final latest = observations.last;
  final target = latest.date.subtract(Duration(days: days));
  var index = -1;
  for (var i = observations.length - 2; i >= 0; i--) {
    if (!observations[i].date.isAfter(target)) {
      index = i;
      break;
    }
  }
  if (index < 0) return null;
  final base = observations[index].price;
  if (!(base > 0) || !latest.price.isFinite) return null;
  final change = (latest.price / base - 1) * 100;
  return change.isFinite ? change : null;
}

/// Detects unusual daily moves and long gaps in [observations].
///
/// A day is a `spike` or `crash` when the robust modified z-score of its log
/// return, `0.6745 * (r - median(r)) / MAD`, exceeds +/-3.5 in absolute value.
/// The median/MAD pair is used instead of mean/standard deviation because a
/// single outlier inflates the standard deviation enough to hide itself.
///
/// Each return is first converted to an *average daily rate*, `r / spanDays`,
/// where `spanDays` is the number of calendar days between the two
/// observations. Without that step a return that spans a six-day gap - or every
/// return of a card that is only priced weekly - would be several times larger
/// than a genuine one-day return and would be reported as a spike on every
/// observation. With it, a real one-day move of 40% still scores enormously
/// while a 4% move spread over six days does not.
///
/// A day is a `gap` when more than [kGapAnomalyDays] calendar days separate it
/// from the previous observation. When MAD is 0 the return test is skipped
/// entirely, as required: the scale is undefined. MAD values below
/// [_minimumMad] are treated as 0 for the same reason - a perfectly linear
/// series has a MAD of ~1e-18 in floating point, and dividing by it would
/// report every single day as a wild outlier.
///
/// The result is sorted by date.
List<AnomalyFlag> detectAnomalies(List<PricePoint> observations,
    {double threshold = 3.5}) {
  final flags = <AnomalyFlag>[];
  if (observations.length < 2) return flags;

  final returns = <double>[];
  final returnIndex = <int>[];
  final spanDays = <int>[];
  for (var i = 1; i < observations.length; i++) {
    final previous = observations[i - 1].price;
    final current = observations[i].price;
    final span = observations[i].date.difference(observations[i - 1].date).inDays;
    if (previous > 0 && current > 0 && span > 0) {
      final total = math.log(current / previous);
      if (total.isFinite) {
        returns.add(total / span);
        returnIndex.add(i);
        spanDays.add(span);
      }
    }
  }

  final scores = <int, double>{};
  if (returns.length >= 3) {
    final center = median(returns);
    final mad = center == null ? null : medianAbsoluteDeviation(returns, center);
    if (center != null && mad != null && mad > _minimumMad) {
      for (var k = 0; k < returns.length; k++) {
        final z = 0.6745 * (returns[k] - center) / mad;
        if (z.isFinite) scores[returnIndex[k]] = z;
      }
    }
  }

  for (var i = 1; i < observations.length; i++) {
    final missing = observations[i].date.difference(observations[i - 1].date).inDays - 1;
    if (missing > kGapAnomalyDays) {
      flags.add(AnomalyFlag(
        date: observations[i].date,
        price: observations[i].price,
        zScore: scores[i] ?? 0.0,
        kind: 'gap',
        description: 'No price for $missing days between '
            '${_isoDay(observations[i - 1].date)} and '
            '${_isoDay(observations[i].date)}.',
      ));
    }
  }

  for (var k = 0; k < returns.length; k++) {
    final z = scores[returnIndex[k]];
    if (z == null || z.abs() <= threshold) continue;
    final index = returnIndex[k];
    final span = spanDays[k];
    final percent = (math.exp(returns[k] * span) - 1) * 100;
    final direction = percent >= 0 ? 'spiked' : 'dropped';
    final period = span == 1 ? 'in one day' : 'over $span days';
    flags.add(AnomalyFlag(
      date: observations[index].date,
      price: observations[index].price,
      zScore: z,
      kind: z > 0 ? 'spike' : 'crash',
      description: 'Price $direction ${percent.abs().toStringAsFixed(1)}% '
          '$period (robust z-score ${z.toStringAsFixed(1)}).',
    ));
  }

  flags.sort((a, b) => a.date.compareTo(b.date));
  return flags;
}

/// Formats a date as `YYYY-MM-DD`.
String _isoDay(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
