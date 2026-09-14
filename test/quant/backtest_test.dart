import 'package:flutter_test/flutter_test.dart';

import 'package:arcanum/domain/quant/quant.dart';

/// A daily series starting 2024-01-01, one point per entry.
List<PricePoint> daily(List<double> prices, {int startYear = 2024}) {
  final base = DateTime.utc(startYear, 1, 1);
  return <PricePoint>[
    for (var i = 0; i < prices.length; i++)
      PricePoint(base.add(Duration(days: i)), prices[i]),
  ];
}

/// A ramp of [n] daily prices from [from] to [to], inclusive.
List<double> ramp(int n, double from, double to) => <double>[
  for (var i = 0; i < n; i++) from + (to - from) * (n == 1 ? 0 : i / (n - 1)),
];

List<PricePoint> gapSeries() {
  final base = DateTime.utc(2024, 1, 1);
  final points = <PricePoint>[];
  // Sixty calm days, then forty days with no observation at all, then sixty
  // more. The hole is wide enough that a seven-day forecast aimed into it
  // cannot be judged against a fresh price.
  for (var i = 0; i < 60; i++) {
    points.add(PricePoint(base.add(Duration(days: i)), 100 + i * 0.5));
  }
  for (var i = 0; i < 60; i++) {
    points.add(PricePoint(base.add(Duration(days: 100 + i)), 140 + i * 0.5));
  }
  return points;
}

void main() {
  group('wilsonInterval', () {
    test('an empty sample reports nothing rather than a rate', () {
      expect(wilsonInterval(0, 0), (0.0, 0.0));
    });

    test('bounds stay inside 0..1 at the extremes', () {
      final (low, high) = wilsonInterval(10, 10);
      expect(low, lessThan(1.0));
      expect(high, 1.0);
      final (lo0, hi0) = wilsonInterval(0, 10);
      expect(lo0, 0.0);
      expect(hi0, lessThan(0.35));
      expect(hi0, greaterThan(0.2));
    });

    test('a half-and-half sample straddles 0.5', () {
      final (low, high) = wilsonInterval(50, 100);
      expect(low, lessThan(0.5));
      expect(high, greaterThan(0.5));
      expect(high - low, lessThan(0.25));
    });
  });

  group('MoveBucket', () {
    test('the band boundary counts as flat', () {
      expect(MoveBucket.of(1.0, 1.0), MoveBucket.flat);
      expect(MoveBucket.of(1.01, 1.0), MoveBucket.up);
      expect(MoveBucket.of(-1.01, 1.0), MoveBucket.down);
      expect(MoveBucket.of(0, 1.0), MoveBucket.flat);
    });
  });

  group('ForecastScore', () {
    test('an empty score knows nothing, and does not report zeros', () {
      final score = ForecastScore.of(const <ForecastTrial>[]);
      expect(score.isEmpty, isTrue);
      expect(score.trials, 0);
      expect(score.readingHitRate, isNull);
      expect(score.numberHitRate, isNull);
      expect(score.band80Coverage, isNull);
      expect(score.majorityHitRate, isNull);
      expect(score.skill, isNull);
      expect(score.readingInterval, isNull);
    });

    test('a flat market leaves doing nothing with no error to beat', () {
      final audit = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[
          BacktestSeries('flat', daily(List<double>.filled(60, 12.0))),
        ],
        horizonDays: 7,
        minTrainingDays: 21,
      );
      expect(audit.overall.trials, greaterThan(0));
      expect(audit.overall.naiveMape, 0);
      expect(audit.overall.skill, isNull);
    });
  });

  group('runForecastAudit', () {
    test('a short series is reported as untested, not as a miss', () {
      final audit = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[
          BacktestSeries('tiny', daily(<double>[1, 2, 3, 4, 5])),
        ],
        horizonDays: 7,
      );
      expect(audit.overall.trials, 0);
      expect(audit.cardsTooShort, 1);
      expect(audit.cardsTested, 0);
      expect(audit.headline, 'Nothing to test yet');
    });

    test('no prediction is judged against a price from before its own day', () {
      final trials = _trialsOf(
        runForecastAudit(
          gameLabel: 'Magic',
          series: <BacktestSeries>[
            BacktestSeries('ramp', daily(ramp(120, 10, 40))),
          ],
          horizonDays: 30,
        ),
      );
      expect(trials, isNotEmpty);
      for (final t in trials) {
        expect(t.observedOn.isBefore(t.predictedFor), isFalse);
        expect(t.trainedThrough.isBefore(t.predictedFor), isTrue);
        expect(t.observedOn.isBefore(t.trainedThrough), isFalse);
      }
    });

    test('a model that cannot see the future cannot use it', () {
      // Two histories that are identical up to day 60 and wildly different
      // afterwards. The prediction made from day 60 must be the same number in
      // both, because a model that has already read the answer is not a model.
      final shared = ramp(61, 10, 25);
      final quiet = <double>[...shared, ...ramp(60, 25.1, 26)];
      final wild = <double>[...shared, ...ramp(60, 25.1, 900)];
      final a = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[BacktestSeries('x', daily(quiet))],
        horizonDays: 30,
        minTrainingDays: 61,
        maxTrialsPerCard: 1,
      );
      final b = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[BacktestSeries('x', daily(wild))],
        horizonDays: 30,
        minTrainingDays: 61,
        maxTrialsPerCard: 1,
      );
      final ta = _trialsOf(a).first;
      final tb = _trialsOf(b).first;
      expect(ta.predictedFor, tb.predictedFor);
      expect(ta.predicted, closeTo(tb.predicted, 1e-12));
      expect(ta.anchor, tb.anchor);
      expect(ta.lower80, closeTo(tb.lower80, 1e-12));
      expect(ta.trendScore, closeTo(tb.trendScore, 1e-12));
      // And they must disagree about what actually happened, or the test would
      // pass on a series that never diverged.
      expect(ta.actual, isNot(closeTo(tb.actual, 1e-6)));
    });

    test(
      'a hole in the middle does not end the test for the prices after it',
      () {
        final audit = runForecastAudit(
          gameLabel: 'Magic',
          series: <BacktestSeries>[BacktestSeries('holed', gapSeries())],
          horizonDays: 7,
          minTrainingDays: 21,
        );
        final trials = _trialsOf(audit);
        expect(trials, isNotEmpty);
        final afterTheHole = DateTime.utc(
          2024,
          1,
          1,
        ).add(const Duration(days: 100));
        expect(
          trials.any((t) => t.predictedFor.isAfter(afterTheHole)),
          isTrue,
          reason:
              'the history after the hole is as usable as the history before',
        );
      },
    );

    test('the work budget is divided over the cards, not spent in order', () {
      final audit = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[
          for (var i = 0; i < 6; i++)
            BacktestSeries('card$i', daily(ramp(120, 10, 20 + i.toDouble()))),
        ],
        horizonDays: 7,
        maxTrialsTotal: 20,
        maxTrialsPerCard: 10,
      );
      // Twenty predictions over six cards is three each, and every card is
      // tested: the last card must not be the one that pays for the first.
      expect(audit.trialsPerCard, 3);
      expect(audit.overall.trials, 18);
      expect(audit.cardsTested, 6);
      expect(audit.budgetCapped, isTrue);
      expect(
        audit.caveats.any((c) => c.contains('per card to keep itself quick')),
        isTrue,
      );
    });

    test('a budget too small to go round still tests every card once', () {
      final audit = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[
          for (var i = 0; i < 4; i++)
            BacktestSeries('card$i', daily(ramp(120, 10, 20 + i.toDouble()))),
        ],
        horizonDays: 7,
        maxTrialsTotal: 2,
      );
      expect(audit.trialsPerCard, 1);
      expect(audit.cardsTested, 4);
      expect(audit.overall.trials, 4);
    });

    test('one prediction per card is a legal request', () {
      final audit = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[BacktestSeries('a', daily(ramp(120, 10, 30)))],
        horizonDays: 7,
        maxTrialsPerCard: 1,
      );
      expect(audit.overall.trials, 1);
    });

    test('the same history always produces the same audit', () {
      ForecastAudit run() => runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[
          BacktestSeries('a', daily(ramp(120, 10, 30))),
          BacktestSeries('b', daily(ramp(120, 30, 12))),
        ],
        horizonDays: 14,
      );
      final first = run();
      final second = run();
      expect(second.overall.trials, first.overall.trials);
      expect(second.overall.readingHits, first.overall.readingHits);
      expect(second.overall.mape, first.overall.mape);
      expect(second.headline, first.headline);
    });

    test('a rising ramp is called correctly, and the baselines say why that is '
        'not impressive on its own', () {
      final audit = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[
          for (var i = 0; i < 4; i++)
            BacktestSeries(
              'card$i',
              daily(ramp(150, 10 + i.toDouble(), 30 + i.toDouble())),
            ),
        ],
        horizonDays: 30,
      );
      expect(audit.overall.trials, greaterThan(30));
      expect(audit.overall.readingHitRate, 1.0);
      expect(audit.overall.majorityHitRate, 1.0);
      // A perfect record on a one-way market is still a warning: always calling
      // it up scores the same, so the headline must be the honest one and must
      // not claim a skill that came from the market rather than the model.
      expect(
        audit.headline,
        'A rule that never looks at a price has done as well',
      );
      expect(audit.overall.majorityHitRate, audit.overall.readingHitRate);
      expect(audit.edgeOverMajority, 0);
      expect(audit.thinData, isFalse);
    });

    test('the caveats name the things the numbers cannot say', () {
      final audit = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[BacktestSeries('a', daily(ramp(120, 10, 30)))],
        horizonDays: 30,
      );
      expect(audit.caveats.any((c) => c.contains('overlap')), isTrue);
      expect(audit.caveats.any((c) => c.contains('only the prices')), isTrue);
      expect(audit.caveats.any((c) => c.contains('counts as flat')), isTrue);
      expect(audit.caveats.any((c) => c.contains('cards you own')), isTrue);
      expect(audit.thinData, isTrue);
      expect(audit.caveats.any((c) => c.contains('no figure')), isTrue);
    });

    test('a series with a single observation is not offered as evidence', () {
      final audit = runForecastAudit(
        gameLabel: 'Pokemon',
        series: <BacktestSeries>[
          BacktestSeries('one', daily(<double>[5.0])),
          BacktestSeries('none', const <PricePoint>[]),
        ],
        horizonDays: 7,
      );
      expect(audit.overall.trials, 0);
      expect(audit.cardsOffered, 1);
      expect(audit.cardsTested, 0);
    });

    test('a runaway forecast is counted, and does not decide the medians', () {
      // Twenty days at a dime, a ten-day climb to ten dollars, then two months
      // of calm. A window that ends inside the climb has nothing but a vertical
      // line in it, and the model, told to fit a line, carries on up: that is
      // real behaviour and is scored as such - but the typical miss has to stay
      // a description of the typical case.
      final surge = <double>[
        ...List<double>.filled(20, 0.10),
        ...ramp(10, 0.10, 10.0),
        ...List<double>.filled(60, 10.0),
      ];
      final audit = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[BacktestSeries('surge', daily(surge))],
        horizonDays: 30,
        minTrainingDays: 21,
      );
      final ForecastScore score = audit.overall;
      expect(score.trials, greaterThan(0));
      expect(score.aimedTooHigh, greaterThan(0));
      expect(score.hasRunaways, isTrue);
      expect(score.mape!, greaterThan(1000));
      expect(score.medianAbsoluteErrorPct!, lessThan(500));
      expect(score.medianAbsoluteErrorPct!, lessThan(score.mape!));
      // The skill figure has to survive the runaways too: a mean-based version
      // of it reads in the thousands of percent and means nothing. Here the
      // typical trial had a price that did not move at all, so standing still
      // has no error to beat and null is the right answer - but a figure in the
      // thousands is never right.
      if (score.skill != null) {
        expect(score.skill!, greaterThan(-10));
      }
      expect(score.medianBiasPct, isNotNull);
      expect(audit.caveats.any((c) => c.contains('ten times away')), isTrue);
      expect(
        audit.summary.any((r) => r.$1.contains('over ten times too high')),
        isTrue,
      );
    });

    test('a market with no runaways does not report any', () {
      final audit = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[
          for (var i = 0; i < 4; i++)
            BacktestSeries(
              'card$i',
              daily(ramp(150, 10 + i.toDouble(), 30 + i.toDouble())),
            ),
        ],
        horizonDays: 30,
      );
      expect(audit.overall.hasRunaways, isFalse);
      expect(audit.summary.any((r) => r.$1.contains('too high')), isFalse);
      expect(audit.summary.any((r) => r.$1.contains('Typical miss')), isTrue);
    });

    test('the chance level for a three-way call is a third, not a half', () {
      final audit = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[
          for (var i = 0; i < 6; i++)
            BacktestSeries(
              'card$i',
              daily(ramp(150, 10 + i.toDouble(), 30 + i.toDouble())),
            ),
        ],
        horizonDays: 30,
      );
      expect(kChanceHitRate, closeTo(1 / 3, 1e-12));
      expect(audit.edgeOverChance, isNotNull);
      expect(audit.edgeOverChance!, closeTo(1 - 1 / 3, 1e-12));
    });

    test('summary reads in plain figures, in percent', () {
      final audit = runForecastAudit(
        gameLabel: 'Magic',
        series: <BacktestSeries>[
          for (var i = 0; i < 4; i++)
            BacktestSeries(
              'card$i',
              daily(ramp(150, 10 + i.toDouble(), 30 + i.toDouble())),
            ),
        ],
        horizonDays: 30,
      );
      final rows = <String, String>{for (final r in audit.summary) r.$1: r.$2};
      expect(rows['Predictions judged'], isNotNull);
      expect(rows['Cards tested'], '4 of 4');
      expect(rows['Right about direction'], contains('%'));
      expect(
        rows.keys.any((k) => k.startsWith('Truth inside the 80%')),
        isTrue,
      );
      expect(rows.keys.any((k) => k.contains('80% band')), isTrue);
    });
  });
}

/// Every trial in an audit, flattened.
List<ForecastTrial> _trialsOf(ForecastAudit audit) => audit.trials;
