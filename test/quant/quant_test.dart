// Unit tests for the pure-Dart price-analytics engine.
//
// These are written against `package:flutter_test` rather than `package:test`:
// the project's dev_dependencies declare `flutter_test` only, and pubspec.yaml
// is out of scope for this change, so `dart test` cannot resolve a test runner
// here. `flutter_test` re-exports the same `test`, `group` and `expect` API,
// so run these with:  flutter test test/quant
import 'dart:math' as math;

import 'package:arcanum/domain/quant/quant.dart';
import 'package:flutter_test/flutter_test.dart';

/// UTC day `offset` days after 2024-01-01.
DateTime day(int offset) =>
    DateTime.utc(2024, 1, 1).add(Duration(days: offset));

/// Builds a daily, gap-free series from [prices].
List<PricePoint> daily(List<double> prices) =>
    [for (var i = 0; i < prices.length; i++) PricePoint(day(i), prices[i])];

/// A pure exponential ramp: `price(i) = 100 * exp(slope * i)`.
List<PricePoint> rampSeries(int n, double slope) =>
    daily([for (var i = 0; i < n; i++) 100 * math.exp(slope * i)]);

/// A deterministic wavy series, used as a "no trend" baseline.
List<PricePoint> wavySeries(int n) =>
    daily([for (var i = 0; i < n; i++) 10 * (1 + 0.05 * math.sin(i * 0.7))]);

/// Wilder's classic worked example (33 daily prices).
const List<double> wilderPrices = <double>[
  44.34, 44.09, 44.15, 43.61, 44.33, 44.83, 45.10, 45.42, 45.84, 46.08,
  45.89, 46.03, 45.61, 46.28, 46.28, 46.00, 46.03, 46.41, 46.22, 45.64,
  46.21, 46.25, 45.71, 46.45, 45.78, 45.35, 44.03, 44.18, 44.22, 44.57,
  43.42, 42.66, 43.13,
];

void main() {
  group('degenerate input never throws', () {
    test('empty list yields a neutral, thin, empty result', () {
      final a = analyzeSeries(const <PricePoint>[]);
      expect(a.currentPrice, isNull);
      expect(a.trendScore, 50);
      expect(a.direction, TrendDirection.flat);
      expect(a.confidence, 0);
      expect(a.thinData, isTrue);
      expect(a.readings, isEmpty);
      expect(a.anomalies, isEmpty);
      expect(a.series, isEmpty);
      expect(a.effectiveSamples, 0);
      expect(a.windowDays, 365);
      expect(a.rsi14, isNull);
      expect(a.macd, isNull);
      expect(a.bollinger, isNull);
      expect(a.regression90, isNull);
      expect(a.forecast, isNull);
      expect(a.kalman, isNull);
      expect(a.summary, isNotEmpty);
      expect(a.headline, 'No data');
    });

    test('NaN, zero and negative prices are discarded', () {
      final a = analyzeSeries(<PricePoint>[
        PricePoint(day(0), double.nan),
        PricePoint(day(1), 0),
        PricePoint(day(2), -4),
        PricePoint(day(3), double.infinity),
      ]);
      expect(a.currentPrice, isNull);
      expect(a.trendScore, 50);
      expect(a.effectiveSamples, 0);
      expect(a.readings, isEmpty);
    });

    test('a single point is analysed without a trend', () {
      final a = analyzeSeries(<PricePoint>[PricePoint(day(0), 3.5)]);
      expect(a.currentPrice, 3.5);
      expect(a.trendScore, 50);
      expect(a.direction, TrendDirection.flat);
      expect(a.thinData, isTrue);
      expect(a.effectiveSamples, 1);
      expect(a.series.length, 1);
      expect(a.regression90, isNull);
      expect(a.rsi14, isNull);
      expect(a.macd, isNull);
      expect(a.forecast, isNull);
      expect(a.volatilityAnnualized, isNull);
      expect(a.kalman, isNotNull);
      expect(a.headline, 'Insufficient data');
    });

    test('two points produce a degenerate regression with t = 0', () {
      final a = analyzeSeries(<PricePoint>[
        PricePoint(day(0), 1),
        PricePoint(day(1), 2),
      ]);
      expect(a.regression90, isNotNull);
      expect(a.regression90!.n, 2);
      expect(a.regression90!.slope, closeTo(math.log(2), 1e-12));
      expect(a.regression90!.rSquared, closeTo(1.0, 1e-12));
      expect(a.regression90!.tStat, 0);
      expect(a.rsi14, isNull);
      expect(a.forecast, isNull);
    });

    test('extreme magnitudes stay finite', () {
      final a = analyzeSeries(daily(<double>[1e-300, 1e300, 1e-300, 1e300, 5]));
      expect(a.trendScore.isFinite, isTrue);
      expect(a.trendScore, inInclusiveRange(0, 100));
      expect(a.confidence.isFinite, isTrue);
      for (final row in a.readings) {
        expect(row.value, isNotEmpty);
        if (row.signal != null) expect(row.signal!.isFinite, isTrue);
      }
      if (a.kalman != null) expect(a.kalman!.trendAnnualPct.isFinite, isTrue);
    });

    test('non-positive windowDays falls back to a year', () {
      final a = analyzeSeries(daily(<double>[1, 2, 3]), windowDays: 0);
      expect(a.windowDays, 365);
      expect(a.effectiveSamples, 3);
    });
  });

  group('input normalisation', () {
    test('unsorted input is sorted by date', () {
      final a = analyzeSeries(<PricePoint>[
        PricePoint(day(2), 3),
        PricePoint(day(0), 1),
        PricePoint(day(1), 2),
      ]);
      expect(a.series.map((p) => p.date).toList(), <DateTime>[
        day(0),
        day(1),
        day(2),
      ]);
      expect(a.currentPrice, 3);
    });

    test('duplicate days collapse, keeping the last supplied price', () {
      final a = analyzeSeries(<PricePoint>[
        PricePoint(day(0), 10),
        PricePoint(day(0), 11),
        PricePoint(day(1), 12),
      ]);
      expect(a.effectiveSamples, 2);
      expect(a.series.first.price, 11);
    });

    test('a dense window is analysed on the raw prices', () {
      final points = rampSeries(40, 0.001);
      final a = analyzeSeries(points, windowDays: 40);
      expect(a.series.length, 40);
      for (var i = 0; i < 40; i++) {
        expect(a.series[i].price, closeTo(points[i].price, 1e-9));
      }
    });

    test('only the trailing window is analysed', () {
      final a = analyzeSeries(rampSeries(60, 0.001), windowDays: 30);
      expect(a.effectiveSamples, 31);
      expect(a.series.first.date, day(29));
      expect(a.currentPrice, closeTo(100 * math.exp(0.001 * 59), 1e-9));
    });
  });

  group('linear ramp', () {
    const slope = 0.002;
    final points = rampSeries(120, slope);
    final a = analyzeSeries(points, windowDays: 120);

    test('regression recovers the exact log-linear slope with R-squared 1', () {
      expect(a.regression90, isNotNull);
      expect(a.regression90!.n, 90);
      expect(a.regression90!.slope, closeTo(slope, 1e-9));
      expect(a.regression90!.rSquared, closeTo(1.0, 1e-9));
      expect(a.regression90!.tStat.abs(), greaterThan(100));
    });

    test('the Kalman smoother recovers the same slope', () {
      expect(a.kalman, isNotNull);
      expect(a.kalman!.slope, closeTo(slope, 1e-6));
      expect(
        a.kalman!.trendAnnualPct,
        closeTo((math.exp(365 * slope) - 1) * 100, 0.01),
      );
      expect(a.trendAnnualPct, closeTo(107.51, 0.01));
      expect(a.kalman!.slopeCi95, greaterThan(0));
    });

    test('a frictionless ramp has zero volatility and no drawdown', () {
      expect(a.volatilityAnnualized, closeTo(0, 1e-6));
      expect(a.maxDrawdown, closeTo(0, 1e-9));
      expect(a.riskAdjustedMomentum, isNull);
      expect(a.anomalies, isEmpty);
    });

    test('momentum matches the compounded log growth', () {
      expect(a.momentum30, closeTo((math.exp(0.002 * 30) - 1) * 100, 1e-6));
      expect(a.momentum7, closeTo((math.exp(0.002 * 7) - 1) * 100, 1e-6));
      expect(a.momentum90, closeTo((math.exp(0.002 * 90) - 1) * 100, 1e-6));
    });

    test('the score saturates bullish', () {
      expect(a.trendScore, greaterThan(65));
      expect(a.direction, TrendDirection.rising);
      expect(a.headline, 'Rising');
      expect(a.confidence, greaterThan(0.9));
      expect(a.thinData, isFalse);
      expect(a.rsi14, closeTo(100, 1e-9));
      expect(a.summary, contains('Rising'));
    });
  });

  group('RSI(14), Wilder', () {
    test("reproduces Wilder's published example", () {
      final a = analyzeSeries(daily(wilderPrices));
      expect(a.rsi14, isNotNull);
      expect(a.rsi14!, closeTo(37.79, 0.05));
    });

    test('an alternating series with equal gains and losses is exactly 50', () {
      final prices = <double>[100];
      for (var i = 0; i < 14; i++) {
        prices.add(i.isEven ? 101 : 100);
      }
      final a = analyzeSeries(daily(prices));
      expect(a.rsi14, closeTo(50.0, 1e-12));
    });

    test('one further gain applies Wilder smoothing', () {
      final prices = <double>[100];
      for (var i = 0; i < 14; i++) {
        prices.add(i.isEven ? 101 : 100);
      }
      prices.add(101);
      final a = analyzeSeries(daily(prices));
      // avgGain = (13 * 0.5 + 1) / 14, avgLoss = (13 * 0.5) / 14
      final avgGain = (13 * 0.5 + 1) / 14;
      final avgLoss = (13 * 0.5) / 14;
      final expected = 100 - 100 / (1 + avgGain / avgLoss);
      expect(a.rsi14, closeTo(expected, 1e-9));
      expect(expected, closeTo(53.5714, 1e-3));
    });

    test('a strictly rising series is 100 and a strictly falling one is 0', () {
      expect(
        analyzeSeries(daily([for (var i = 0; i < 20; i++) 10.0 + i])).rsi14,
        closeTo(100, 1e-9),
      );
      expect(
        analyzeSeries(daily([for (var i = 0; i < 20; i++) 30.0 - i])).rsi14,
        closeTo(0, 1e-9),
      );
    });
  });

  group('constant series', () {
    final a = analyzeSeries(daily([for (var i = 0; i < 60; i++) 5.0]),
        windowDays: 60);

    test('zero volatility, zero drawdown, no anomalies', () {
      expect(a.volatilityAnnualized, 0);
      expect(a.maxDrawdown, 0);
      expect(a.anomalies, isEmpty);
      expect(a.riskAdjustedMomentum, isNull);
      expect(a.thinData, isFalse);
    });

    test('RSI is neutral rather than the degenerate 100', () {
      // Wilder's rule (avgLoss == 0 -> 100) is only meaningful when there were
      // actual gains; with no movement at all the reading is neutral.
      expect(a.rsi14, 50);
    });

    test('bands collapse and MACD is flat', () {
      expect(a.bollinger, isNotNull);
      expect(a.bollinger!.bandwidth, closeTo(0, 1e-12));
      expect(a.bollinger!.percentB, 0.5);
      expect(a.bollinger!.upper, closeTo(a.bollinger!.lower, 1e-12));
      expect(a.macd!.histogram, closeTo(0, 1e-12));
      expect(a.regression90!.rSquared, 0);
      expect(a.regression90!.slope, closeTo(0, 1e-12));
    });

    test('the forecast is flat and the score is exactly neutral', () {
      expect(a.forecast, isNotNull);
      for (final value in a.forecast!.point) {
        expect(value, closeTo(5.0, 1e-9));
      }
      expect(a.forecast!.trend, closeTo(0, 1e-12));
      expect(a.forecast!.sigma, closeTo(0, 1e-12));
      expect(a.trendScore, 50);
      expect(a.direction, TrendDirection.flat);
    });
  });

  group('anomaly detection', () {
    test('a one-day spike is flagged as a spike', () {
      final prices = <double>[
        for (var i = 0; i < 60; i++) 10 * (1 + 0.05 * math.sin(i * 0.7)),
      ];
      prices[30] = 15.0; // +44% in one day on a ~10 price
      final a = analyzeSeries(daily(prices), windowDays: 60);

      final spikes = a.anomalies.where((x) => x.kind == 'spike').toList();
      expect(spikes, hasLength(1));
      expect(spikes.single.date, day(30));
      expect(spikes.single.price, 15.0);
      expect(spikes.single.zScore, greaterThan(3.5));
      expect(spikes.single.description, contains('spiked'));
      expect(spikes.single.description, contains('one day'));

      // The day the price fell back is a crash.
      final crashes = a.anomalies.where((x) => x.kind == 'crash').toList();
      expect(crashes, hasLength(1));
      expect(crashes.single.date, day(31));
      expect(crashes.single.zScore, lessThan(-3.5));

      expect(a.maxDrawdown, greaterThan(20));
      expect(a.volatilityAnnualized, greaterThan(50));
    });

    test('ordinary noise is not flagged', () {
      final a = analyzeSeries(wavySeries(90), windowDays: 90);
      expect(a.anomalies, isEmpty);
    });

    test('a long hole is a gap, not a spike', () {
      final points = <PricePoint>[];
      for (var i = 0; i < 60; i++) {
        if (i >= 20 && i < 26) continue; // six days with no price
        points.add(PricePoint(day(i), 10 + 0.02 * i));
      }
      final a = analyzeSeries(points, windowDays: 60);

      final gaps = a.anomalies.where((x) => x.kind == 'gap').toList();
      expect(gaps, hasLength(1));
      expect(gaps.single.date, day(26));
      expect(gaps.single.description, contains('6 days'));
      expect(a.anomalies.where((x) => x.kind == 'spike'), isEmpty);
      expect(a.anomalies.where((x) => x.kind == 'crash'), isEmpty);
    });
  });

  group('missing data', () {
    final points = <PricePoint>[];
    for (var i = 0; i < 60; i++) {
      if (i >= 20 && i < 26) continue;
      points.add(PricePoint(day(i), 10 + 0.02 * i));
    }
    final a = analyzeSeries(points, windowDays: 60);

    test('the grid keeps every calendar day but the series does not', () {
      expect(a.effectiveSamples, 54);
      expect(a.series, hasLength(54));
      expect(a.kalman, isNotNull);
      expect(a.kalman!.smoothed, hasLength(60));
      expect(
        a.series.map((p) => p.date).toSet(),
        isNot(contains(day(22))),
      );
    });

    test('the smoother interpolates monotonically across the hole', () {
      final smoothed = a.kalman!.smoothed;
      for (var i = 19; i < 26; i++) {
        expect(smoothed[i + 1], greaterThan(smoothed[i]));
      }
      // Smoothed log prices sit between the observations that bracket the hole.
      expect(smoothed[20], greaterThan(smoothed[19]));
      expect(smoothed[25], lessThan(smoothed[26]));
    });

    test('the smoothed path still recovers the underlying trend', () {
      expect(a.regression90!.slope, greaterThan(0));
      expect(a.regression90!.rSquared, greaterThan(0.9));
      expect(a.direction, TrendDirection.rising);
    });

    test('coverage drives the thinData flag', () {
      expect(a.thinData, isFalse); // 54 / 60
      final sparse = analyzeSeries(points, windowDays: 365);
      expect(sparse.thinData, isTrue);
      expect(sparse.effectiveSamples, 54);
    });
  });

  group('forecast', () {
    test('horizon is respected and bands nest', () {
      final a = analyzeSeries(rampSeries(120, 0.002),
          windowDays: 120, forecastHorizon: 7);
      final f = a.forecast!;
      expect(f.point, hasLength(7));
      expect(f.lower80, hasLength(7));
      expect(f.upper95, hasLength(7));
      for (var i = 0; i < 7; i++) {
        expect(f.point[i], greaterThan(a.currentPrice!));
        expect(f.lower80[i], lessThan(f.point[i]));
        expect(f.upper80[i], greaterThan(f.point[i]));
        expect(f.lower95[i], lessThanOrEqualTo(f.lower80[i]));
        expect(f.upper95[i], greaterThanOrEqualTo(f.upper80[i]));
      }
      expect(f.point[0], closeTo(a.currentPrice! * math.exp(0.002), 0.5));
      expect(f.alpha, greaterThan(0));
      expect(f.beta, greaterThan(0));
    });

    test('band width grows with the horizon', () {
      final a = analyzeSeries(wavySeries(120), windowDays: 120);
      final f = a.forecast!;
      final first = f.upper95.first - f.lower95.first;
      final last = f.upper95.last - f.lower95.last;
      expect(last, greaterThan(first));
      expect(f.sigma, greaterThan(0));
    });

    test('a non-positive horizon suppresses the forecast', () {
      final a = analyzeSeries(wavySeries(60), forecastHorizon: 0);
      expect(a.forecast, isNull);
      expect(a.trendScore.isFinite, isTrue);
    });
  });

  group('score contract', () {
    final cases = <String, CardAnalytics>{
      'ramp': analyzeSeries(rampSeries(120, 0.002), windowDays: 120),
      'down': analyzeSeries(
          daily([for (var i = 0; i < 120; i++) 100 * math.exp(-0.002 * i)]),
          windowDays: 120),
      'flat': analyzeSeries(daily([for (var i = 0; i < 60; i++) 5.0]),
          windowDays: 60),
      'wavy': analyzeSeries(wavySeries(120), windowDays: 120),
      'short': analyzeSeries(wilderPrices.isEmpty
          ? const <PricePoint>[]
          : daily(wilderPrices)),
    };

    test('scores stay in range and agree with the direction buckets', () {
      for (final entry in cases.entries) {
        final a = entry.value;
        expect(a.trendScore, inInclusiveRange(0, 100), reason: entry.key);
        expect(a.confidence, inInclusiveRange(0, 1), reason: entry.key);
        final score = a.trendScore;
        final expected = score >= 65
            ? TrendDirection.rising
            : score >= 55
                ? TrendDirection.slightlyRising
                : score >= 45
                    ? TrendDirection.flat
                    : score >= 35
                        ? TrendDirection.slightlyFalling
                        : TrendDirection.falling;
        expect(a.direction, expected, reason: entry.key);
      }
    });

    test('a falling ramp scores bearish and a rising one bullish', () {
      expect(cases['down']!.trendScore, lessThan(35));
      expect(cases['down']!.direction, TrendDirection.falling);
      expect(cases['down']!.headline, 'Falling');
      expect(cases['ramp']!.trendScore, greaterThan(65));
    });

    test('the panel is populated with display-ready rows', () {
      final a = cases['ramp']!;
      expect(a.readings.length, inInclusiveRange(8, 12));
      expect(a.readings.first.label, 'Trend score');
      expect(a.readings.first.value, contains('/ 100'));
      for (final row in a.readings) {
        expect(row.label, isNotEmpty);
        expect(row.value, isNotEmpty);
        if (row.signal != null) {
          expect(row.signal!, inInclusiveRange(-1, 1));
        }
      }
      final labels = a.readings.map((r) => r.label).toList();
      expect(labels, contains('RSI (14)'));
      expect(labels, contains('MACD (12,26,9)'));
      expect(labels, contains('Bollinger %B (20,2)'));
      expect(labels, contains('Volatility (annualised)'));
      expect(labels, contains('Max drawdown'));
    });

    test('the summary is honest about data coverage', () {
      final thin = analyzeSeries(wilderPrices.isEmpty
          ? const <PricePoint>[]
          : daily(wilderPrices));
      expect(thin.thinData, isTrue);
      expect(thin.summary, contains('low trust'));
      expect(thin.summary, contains('not a prediction'));
      expect(cases['ramp']!.summary, contains('R-squared'));
    });

    test('repeated calls are deterministic', () {
      final first = analyzeSeries(wavySeries(80), windowDays: 80);
      final second = analyzeSeries(wavySeries(80), windowDays: 80);
      expect(second.trendScore, first.trendScore);
      expect(second.confidence, first.confidence);
      expect(second.rsi14, first.rsi14);
      expect(second.summary, first.summary);
      expect(second.anomalies.length, first.anomalies.length);
    });
  });
}
