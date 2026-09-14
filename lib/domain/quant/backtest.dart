/// Back-testing the app's own forecasts against the history it recorded.
///
/// The quant library makes two promises on the card screen: a trend reading
/// ("Rising", score 68) and a Holt forecast with prediction bands. Both are
/// claims about the future, and until this file existed nothing in Arcanum ever
/// checked them.
///
/// The method is deliberately plain and deliberately pessimistic. For every card
/// with enough recorded prices, the model is rewound to a day in the past, shown
/// only the prices that existed on that day, asked to predict $horizonDays
/// ahead, and then held to what actually happened. Nothing here may look at a
/// price the model would not have seen.
///
/// Three things are then scored on the same trials, so they cannot flatter each
/// other:
///
///  * the model's number - the Holt point forecast the card screen prints,
///    both its direction and its average distance from the truth;
///  * the app's reading - the composite trend direction the card screen prints;
///  * and two baselines that know nothing - assuming the price will not move,
///    and always calling the most common outcome.
///
/// A hit rate on its own proves nothing, so every hit rate here carries a Wilson
/// interval, and the summary says so when the interval still contains a coin
/// toss. Overlapping windows make the trials on one card far from independent,
/// which is stated in the caveats rather than hidden in the arithmetic.
library;

import 'dart:math' as math;

import 'analytics.dart';
import 'models.dart';

/// A price move coarse enough that predicting it is a real question.
enum MoveBucket {
  /// The price fell by more than the flat band.
  down,

  /// The price moved by no more than the flat band, either way.
  flat,

  /// The price rose by more than the flat band.
  up;

  /// The bucket a percentage change falls into.
  static MoveBucket of(double changePct, double band) {
    if (changePct > band) return MoveBucket.up;
    if (changePct < -band) return MoveBucket.down;
    return MoveBucket.flat;
  }

  /// One word, for a table.
  String get label => switch (this) {
    MoveBucket.down => 'down',
    MoveBucket.flat => 'flat',
    MoveBucket.up => 'up',
  };
}

/// Default dead band around "no move", as a fraction: a 1% drift either way is
/// called flat.
const double kFlatBandFraction = 0.01;

/// What a call made with no information at all would score.
///
/// There are three outcomes - down, flat, up - so guessing is one in three. It
/// is deliberately not a half: a hit rate of 50% on a three-way question would
/// sound like a coin toss and would in fact be a real edge.
const double kChanceHitRate = 1 / 3;

/// How far a forecast has to overshoot before it is called a runaway.
const double kRunawayFactor = 10;

/// The direction a five-way trend reading points, as a bucket.
MoveBucket _bucketOfDirection(TrendDirection direction) => switch (direction) {
  TrendDirection.rising || TrendDirection.slightlyRising => MoveBucket.up,
  TrendDirection.falling || TrendDirection.slightlyFalling => MoveBucket.down,
  TrendDirection.flat => MoveBucket.flat,
};

/// One prediction that was made in the past and can now be judged.
class ForecastTrial {
  /// Creates a trial.
  const ForecastTrial({
    required this.trainedThrough,
    required this.predictedFor,
    required this.observedOn,
    required this.trainedDays,
    required this.horizonDays,
    required this.anchor,
    required this.predicted,
    required this.lower80,
    required this.upper80,
    required this.lower95,
    required this.upper95,
    required this.actual,
    required this.trendScore,
    required this.direction,
  });

  /// The last day whose price the model was allowed to see.
  final DateTime trainedThrough;

  /// The day the prediction was aimed at.
  final DateTime predictedFor;

  /// The day the price it is judged against was actually observed. Never before
  /// [predictedFor]: a missing day is looked up forwards, never backwards.
  final DateTime observedOn;

  /// How many observations the model was trained on.
  final int trainedDays;

  /// How many days ahead the prediction reached.
  final int horizonDays;

  /// The price on [trainedThrough] - what the model started from.
  final double anchor;

  /// The Holt point forecast.
  final double predicted;

  /// The 80% prediction interval for that day.
  final double lower80;

  /// The 80% prediction interval for that day.
  final double upper80;

  /// The 95% prediction interval for that day.
  final double lower95;

  /// The 95% prediction interval for that day.
  final double upper95;

  /// The price that actually happened, on [observedOn].
  final double actual;

  /// The composite trend score the card screen would have shown that day.
  final double trendScore;

  /// The trend direction the card screen would have shown that day.
  final TrendDirection direction;

  /// The move the model predicted, in percent of the anchor price.
  double get predictedChangePct => (predicted - anchor) / anchor * 100;

  /// The move that happened, in percent of the anchor price.
  double get actualChangePct => (actual - anchor) / anchor * 100;

  /// The bucket the model's number implies.
  MoveBucket get predictedBucket =>
      MoveBucket.of(predictedChangePct, kFlatBandFraction * 100);

  /// The bucket the app's reading pointed at.
  MoveBucket get readingBucket => _bucketOfDirection(direction);

  /// The bucket the price actually landed in.
  MoveBucket get actualBucket =>
      MoveBucket.of(actualChangePct, kFlatBandFraction * 100);

  /// Signed error, in percent of the truth. Positive means the model aimed high.
  double get errorPct => (predicted - actual) / actual * 100;

  /// How far the model's number was from the truth, in percent.
  double get absoluteErrorPct => errorPct.abs();

  /// How far "it will not move" would have been, on the same day.
  double get naiveAbsoluteErrorPct => (anchor - actual).abs() / actual * 100;

  /// Whether the model's direction was right.
  bool get numberHit => predictedBucket == actualBucket;

  /// Whether the app's reading was right.
  bool get readingHit => readingBucket == actualBucket;

  /// Whether the truth landed inside the 80% prediction interval.
  bool get inside80 => actual >= lower80 && actual <= upper80;

  /// Whether the truth landed inside the 95% prediction interval.
  bool get inside95 => actual >= lower95 && actual <= upper95;

  /// Whether the model aimed more than ten times too high.
  ///
  /// A forecast that extrapolates a single jump in a price can leave the
  /// credible range entirely. Those predictions are kept in the scores rather
  /// than quietly dropped - they are the model's real behaviour - but they are
  /// counted separately, because one of them can swamp an average.
  bool get aimedTooHigh => predicted > actual * kRunawayFactor;

  /// Whether the model aimed more than ten times too low.
  bool get aimedTooLow => predicted < actual / kRunawayFactor;

  @override
  String toString() =>
      'ForecastTrial($predictedFor.toIso8601String(), '
      'predicted=$predicted, actual=$actual, '
      '${numberHit ? 'hit' : 'miss'})';
}

/// Everything that can be said about one set of trials.
class ForecastScore {
  /// Creates a score.
  const ForecastScore({
    required this.trials,
    required this.numberHits,
    required this.readingHits,
    required this.inside80,
    required this.inside95,
    required this.actualUp,
    required this.actualFlat,
    required this.actualDown,
    required this.mape,
    required this.naiveMape,
    required this.biasPct,
    required this.medianAbsoluteErrorPct,
    required this.medianBiasPct,
    required this.naiveMedianAbsoluteErrorPct,
    required this.aimedTooHigh,
    required this.aimedTooLow,
  });

  /// Scores a list of trials. An empty list yields a score whose every rate is
  /// null rather than zero: nothing was tested, so nothing is known.
  factory ForecastScore.of(List<ForecastTrial> trials) {
    if (trials.isEmpty) {
      return const ForecastScore(
        trials: 0,
        numberHits: 0,
        readingHits: 0,
        inside80: 0,
        inside95: 0,
        actualUp: 0,
        actualFlat: 0,
        actualDown: 0,
        mape: null,
        naiveMape: null,
        biasPct: null,
        medianAbsoluteErrorPct: null,
        medianBiasPct: null,
        naiveMedianAbsoluteErrorPct: null,
        aimedTooHigh: 0,
        aimedTooLow: 0,
      );
    }
    var numberHits = 0;
    var readingHits = 0;
    var in80 = 0;
    var in95 = 0;
    var up = 0;
    var flat = 0;
    var down = 0;
    var sumAbs = 0.0;
    var sumNaive = 0.0;
    var sumError = 0.0;
    var tooHigh = 0;
    var tooLow = 0;
    final errors = <double>[];
    final naiveErrors = <double>[];
    final signedErrors = <double>[];
    for (final t in trials) {
      if (t.numberHit) numberHits++;
      if (t.readingHit) readingHits++;
      if (t.inside80) in80++;
      if (t.inside95) in95++;
      if (t.aimedTooHigh) tooHigh++;
      if (t.aimedTooLow) tooLow++;
      switch (t.actualBucket) {
        case MoveBucket.up:
          up++;
        case MoveBucket.flat:
          flat++;
        case MoveBucket.down:
          down++;
      }
      sumAbs += t.absoluteErrorPct;
      sumNaive += t.naiveAbsoluteErrorPct;
      sumError += t.errorPct;
      errors.add(t.absoluteErrorPct);
      naiveErrors.add(t.naiveAbsoluteErrorPct);
      signedErrors.add(t.errorPct);
    }
    final n = trials.length;
    return ForecastScore(
      trials: n,
      numberHits: numberHits,
      readingHits: readingHits,
      inside80: in80,
      inside95: in95,
      actualUp: up,
      actualFlat: flat,
      actualDown: down,
      mape: sumAbs / n,
      naiveMape: sumNaive / n,
      biasPct: sumError / n,
      medianAbsoluteErrorPct: _median(errors),
      medianBiasPct: _median(signedErrors),
      naiveMedianAbsoluteErrorPct: _median(naiveErrors),
      aimedTooHigh: tooHigh,
      aimedTooLow: tooLow,
    );
  }

  /// How many predictions were judged.
  final int trials;

  /// How often the model's direction was right.
  final int numberHits;

  /// How often the app's trend reading was right.
  final int readingHits;

  /// How often the truth landed inside the 80% band.
  final int inside80;

  /// How often the truth landed inside the 95% band.
  final int inside95;

  /// Trials where the price rose by more than the flat band.
  final int actualUp;

  /// Trials where the price stayed inside the flat band.
  final int actualFlat;

  /// Trials where the price fell by more than the flat band.
  final int actualDown;

  /// Mean absolute error of the model, in percent of the truth.
  final double? mape;

  /// Mean absolute error of "it will not move", on the same days.
  final double? naiveMape;

  /// Mean signed error: how far the model aimed high, on average.
  final double? biasPct;

  /// Median absolute error, which one wild card cannot distort.
  final double? medianAbsoluteErrorPct;

  /// Median signed error: which way the model usually leans, and by how much,
  /// without one runaway forecast deciding the answer.
  final double? medianBiasPct;

  /// Median absolute error of "it will not move", on the same days.
  final double? naiveMedianAbsoluteErrorPct;

  /// Predictions that aimed more than ten times too high.
  final int aimedTooHigh;

  /// Predictions that aimed more than ten times too low.
  final int aimedTooLow;

  /// Whether any prediction left the credible range.
  bool get hasRunaways => aimedTooHigh + aimedTooLow > 0;

  /// Whether anything was scored at all.
  bool get isEmpty => trials == 0;

  /// How often the app's reading was right, or null when nothing was scored.
  double? get readingHitRate => trials == 0 ? null : readingHits / trials;

  /// How often the model's number pointed the right way.
  double? get numberHitRate => trials == 0 ? null : numberHits / trials;

  /// How often the truth landed inside the 80% band. It should be near 0.80.
  double? get band80Coverage => trials == 0 ? null : inside80 / trials;

  /// How often the truth landed inside the 95% band. It should be near 0.95.
  double? get band95Coverage => trials == 0 ? null : inside95 / trials;

  /// The bucket that happened most often, and how often.
  (MoveBucket, int) get commonest {
    if (actualUp >= actualFlat && actualUp >= actualDown) {
      return (MoveBucket.up, actualUp);
    }
    if (actualFlat >= actualDown) return (MoveBucket.flat, actualFlat);
    return (MoveBucket.down, actualDown);
  }

  /// What "always call the most common outcome" would have scored.
  double? get majorityHitRate {
    if (trials == 0) return null;
    return commonest.$2 / trials;
  }

  /// The share of the do-nothing error the model removed, as
  /// "1 minus median miss over median miss of standing still". Zero or below
  /// means it did no better, or worse, than assuming the price would not move.
  /// Null when neither figure exists.
  ///
  /// Built from the medians rather than the means on purpose: two runaway
  /// forecasts out of a thousand can turn the mean-based version into a number
  /// in the thousands of percent, which says nothing about anything.
  double? get skill {
    final m = medianAbsoluteErrorPct;
    final base = naiveMedianAbsoluteErrorPct;
    if (m == null || base == null || base <= 0) return null;
    return 1 - m / base;
  }

  /// The 95% Wilson interval around the reading's hit rate, or null.
  (double, double)? get readingInterval {
    if (trials == 0) return null;
    return wilsonInterval(readingHits, trials);
  }

  /// The 95% Wilson interval around the model number's hit rate, or null.
  (double, double)? get numberInterval {
    if (trials == 0) return null;
    return wilsonInterval(numberHits, trials);
  }
}

/// The 95% Wilson score interval for a proportion of successes in n trials.
///
/// Used instead of the textbook normal interval because a hit rate near 0 or 1,
/// or a small sample, makes the normal interval claim impossible things such as
/// a 110% upper bound. Returns a zero-width interval for an empty sample, which
/// the callers
/// here read as "nothing measured".
/// The middle value of a list, averaged across the two middle values when the
/// list has an even length. Sorts a copy, so the caller's list is untouched.
double? _median(List<double> values) {
  if (values.isEmpty) return null;
  final sorted = <double>[...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

(double, double) wilsonInterval(int successes, int n, {double z = 1.96}) {
  if (n <= 0) return (0, 0);
  final p = successes / n;
  final z2 = z * z;
  final denominator = 1 + z2 / n;
  final centre = (p + z2 / (2 * n)) / denominator;
  final spread =
      z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / denominator;
  final lower = (centre - spread).clamp(0.0, 1.0);
  final upper = (centre + spread).clamp(0.0, 1.0);
  return (lower, upper);
}

/// One card's record in the audit.
class CardBacktest {
  /// Creates a card score.
  const CardBacktest({
    required this.cardId,
    required this.score,
    required this.trainedDays,
    required this.firstTrial,
    required this.lastTrial,
  });

  /// The printing this row is about.
  final String cardId;

  /// How it scored.
  final ForecastScore score;

  /// The longest training window any of its trials used.
  final int trainedDays;

  /// The first day a prediction was made for.
  final DateTime firstTrial;

  /// The last day a prediction was made for.
  final DateTime lastTrial;

  @override
  String toString() => 'CardBacktest($cardId, ${score.trials} trials)';
}

/// Series handed to the audit: one card and its recorded prices.
class BacktestSeries {
  /// Creates a series.
  const BacktestSeries(this.cardId, this.points);

  /// The printing.
  final String cardId;

  /// Its recorded prices, in any order.
  final List<PricePoint> points;
}

/// The whole audit: every trial, every card, and what it adds up to.
class ForecastAudit {
  /// Creates an audit.
  const ForecastAudit({
    required this.gameLabel,
    required this.horizonDays,
    required this.minTrainingDays,
    required this.flatBandFraction,
    required this.overall,
    required this.trials,
    required this.cards,
    required this.cardsOffered,
    required this.cardsTested,
    required this.cardsTooShort,
    required this.trialsPerCard,
    required this.budgetCapped,
    required this.trainedDaysMedian,
    required this.earliestPrediction,
    required this.latestPrediction,
  });

  /// The collection this audit ran against, by name.
  final String gameLabel;

  /// How many days ahead every prediction reached.
  final int horizonDays;

  /// The shortest training window allowed.
  final int minTrainingDays;

  /// The dead band, as a fraction, below which a move counts as flat.
  final double flatBandFraction;

  /// Every trial pooled.
  final ForecastScore overall;

  /// Every trial, in the order the cards were tested.
  final List<ForecastTrial> trials;

  /// Per-card scores, most trials first.
  final List<CardBacktest> cards;

  /// Printings with any recorded history at all.
  final int cardsOffered;

  /// Printings that produced at least one trial.
  final int cardsTested;

  /// Printings whose history was too short to test.
  final int cardsTooShort;

  /// How many predictions each card contributed.
  final int trialsPerCard;

  /// Whether the work budget forced fewer predictions per card than allowed.
  final bool budgetCapped;

  /// The median number of observations available to the model at prediction
  /// time, which is the honest description of how much it had to go on.
  final int trainedDaysMedian;

  /// The first day any prediction was aimed at.
  final DateTime? earliestPrediction;

  /// The last day any prediction was aimed at.
  final DateTime? latestPrediction;

  /// True when the evidence is too thin for the rates to mean anything.
  ///
  /// The thresholds are deliberately blunt: fewer than 30 predictions, or fewer
  /// than 3 cards behind them, cannot support a claim either way.
  bool get thinData => overall.trials < 30 || cardsTested < 3;

  /// How far ahead of a blind guess the reading is, in percentage points.
  double? get edgeOverChance {
    final rate = overall.readingHitRate;
    if (rate == null) return null;
    return rate - kChanceHitRate;
  }

  /// How far ahead of always calling the most common move the reading is, in
  /// percentage points. Negative means the reading did worse than a rule that
  /// never looks at a price.
  double? get edgeOverMajority {
    final rate = overall.readingHitRate;
    final majority = overall.majorityHitRate;
    if (rate == null || majority == null) return null;
    return rate - majority;
  }

  /// One line saying what the audit found.
  ///
  /// The comparison is against guessing, which on a three-way call is one in
  /// three - not a coin toss. The bar that matters more is the one beside it:
  /// always calling the most common move, which looks at nothing and still
  /// scores whatever the market happened to do.
  String get headline {
    final rate = overall.readingHitRate;
    if (rate == null) return 'Nothing to test yet';
    if (thinData) return 'Not enough history to judge the forecast';
    final (low, high) = overall.readingInterval ?? (0.0, 1.0);
    final double majority = overall.majorityHitRate ?? 0;
    if (rate <= majority) {
      return 'A rule that never looks at a price has done as well';
    }
    if (low > kChanceHitRate) {
      return 'The trend reading has beaten guessing, by a little';
    }
    if (high < kChanceHitRate) {
      return 'The trend reading has done worse than guessing';
    }
    return 'The trend reading cannot be told apart from guessing';
  }

  /// The figures, as label/value pairs, in the order they should be read.
  List<(String, String)> get summary {
    final (low, high) = overall.readingInterval ?? (0.0, 0.0);
    return <(String, String)>[
      ('Predictions judged', '${overall.trials}'),
      ('Cards tested', '$cardsTested of $cardsOffered'),
      if (budgetCapped) ('Predictions per card', '$trialsPerCard'),
      (
        'Right about direction',
        overall.readingHitRate == null
            ? '--'
            : '${_pct(overall.readingHitRate!)}  '
                  '(${_pct(low)}-${_pct(high)})',
      ),
      (
        'Right by always calling it ${overall.commonest.$1.label}',
        overall.majorityHitRate == null ? '--' : _pct(overall.majorityHitRate!),
      ),
      (
        'The model number, right about direction',
        overall.numberHitRate == null ? '--' : _pct(overall.numberHitRate!),
      ),
      (
        'Typical miss (the middle one)',
        overall.medianAbsoluteErrorPct == null
            ? '--'
            : '${_fmt(overall.medianAbsoluteErrorPct!)}% of the price',
      ),
      (
        'Typical miss assuming no move',
        overall.naiveMedianAbsoluteErrorPct == null
            ? '--'
            : '${_fmt(overall.naiveMedianAbsoluteErrorPct!)}%',
      ),
      if (overall.hasRunaways)
        (
          'Average miss (dragged by ${overall.aimedTooHigh + overall.aimedTooLow} '
              'predictions)',
          overall.mape == null ? '--' : '${_fmt(overall.mape!)}%',
        ),
      if (overall.hasRunaways)
        (
          'Predictions over ten times too high',
          '${overall.aimedTooHigh} of ${overall.trials}',
        ),
      if (overall.skill != null)
        ('Miss against assuming no move', _pct(overall.skill!)),
      if (overall.medianBiasPct != null)
        (
          'Typical lean',
          '${_fmt(overall.medianBiasPct!)}% (positive aims high)',
        ),
      if (overall.hasRunaways && overall.biasPct != null)
        ('Average lean (dragged by runaways)', '${_fmt(overall.biasPct!)}%'),
      (
        'Truth inside the 80% band',
        overall.band80Coverage == null
            ? '--'
            : '${_pct(overall.band80Coverage!)} of the time',
      ),
      (
        'Truth inside the 95% band',
        overall.band95Coverage == null
            ? '--'
            : '${_pct(overall.band95Coverage!)} of the time',
      ),
    ];
  }

  /// What this audit does not prove, in the app's own words.
  List<String> get caveats {
    final List<String> notes = <String>[
      'Every prediction was made by a model that could see only the prices '
          'recorded before it. A card appears here only once it has prices to be '
          'judged against.',
      'Predictions from the same card overlap: one made a month apart shares '
          'weeks of history with the next, so ${overall.trials} predictions are '
          'far fewer than ${overall.trials} independent tests. The ranges above '
          'are therefore narrower than the truth.',
      if (overall.hasRunaways)
        'Predictions that aim more than ten times away from the price that '
            'followed are counted rather than hidden, and there are '
            '${overall.aimedTooHigh + overall.aimedTooLow} of them here. A '
            'forecast that extrapolates one jump in a price is the failure this '
            'page exists to find, and it is also why the average miss is so much '
            'larger than the typical one.',
      'The model had at most $trainedDaysMedian days of prices to work from. '
          'That is what the app really had to go on, not what it would have with '
          'years of history.',
      'A move of under ${_pct(flatBandFraction)} either way counts as flat, so a '
          'call of up is only wrong when the price actually fell.',
      'This measures Arcanum on the cards you own. It says nothing about how the '
          'same figures would do on cards you do not.',
    ];
    if (budgetCapped) {
      notes.add(
        'The audit ran $trialsPerCard predictions per card to keep itself quick. '
        'With $cardsTested printings to test, judging every window it could have '
        'would have taken far longer; the windows it did use are spread across '
        'each card.',
      );
    }
    if (thinData) {
      notes.add(
        'With ${overall.trials} predictions across $cardsTested cards, no figure '
        'here is strong enough to change how the forecast should be read.',
      );
    }
    return notes;
  }

  static String _pct(double fraction) =>
      '${(fraction * 100).toStringAsFixed(fraction * 100 >= 10 ? 0 : 1)}%';

  static String _fmt(double value) => value.toStringAsFixed(2);
}

/// Runs the audit: rewinds the model over every series it is given.
///
/// [maxTrialsTotal] bounds the work so the screen stays responsive on a large
/// collection. It is divided evenly between the cards, with at least one
/// prediction each, and the audit says so when the ceiling bit.
ForecastAudit runForecastAudit({
  required String gameLabel,
  required List<BacktestSeries> series,
  int horizonDays = 30,
  int minTrainingDays = 21,
  int maxTrialsPerCard = 12,
  int maxTrialsTotal = 3000,
  double flatBandFraction = kFlatBandFraction,
}) {
  final horizon = horizonDays < 1 ? 1 : horizonDays;
  final floor = minTrainingDays < 3 ? 3 : minTrainingDays;
  final trials = <ForecastTrial>[];
  final perCard = <CardBacktest>[];
  var offered = 0;
  var tooShort = 0;
  final trainLengths = <int>[];
  DateTime? earliest;
  DateTime? latest;

  // Clean every series once, before any fitting, so the budget can be divided
  // over the cards up front.
  final usable = <(String, List<PricePoint>)>[];
  for (final entry in series) {
    final points = _sanitize(entry.points);
    if (points.isEmpty) continue;
    offered++;
    if (points.length < floor + 1) {
      tooShort++;
      continue;
    }
    usable.add((entry.cardId, points));
  }

  // The budget is divided evenly instead of being spent in order: a collection
  // tested from A to Z until the clock runs out would answer a question about
  // the alphabet. Every card gets at least one prediction, so a collection
  // larger than the budget takes a little longer than the budget suggests.
  final share = usable.isEmpty ? 0 : maxTrialsTotal ~/ usable.length;
  final allocation = share < 1
      ? 1
      : (share > maxTrialsPerCard ? maxTrialsPerCard : share);
  final capped = usable.isNotEmpty && allocation < maxTrialsPerCard;

  for (final (cardId, points) in usable) {
    final cardTrials = <ForecastTrial>[];
    for (final end in _trainingEnds(
      floor: floor,
      lastEnd: _lastJudgeableEnd(points, horizon, floor),
      maxTrials: allocation,
    )) {
      final trainedThrough = points[end].date;
      final target = trainedThrough.add(Duration(days: horizon));
      final observed = _firstAtOrAfter(points, target, end + 1);
      if (observed == null) break;
      // A day the price was never recorded is looked up forwards, but only so
      // far: a stale observation would flatter the model with a price the
      // market had already left behind. Skipping this window rather than
      // stopping is the difference between a hole in the middle of a series
      // costing one prediction and costing every prediction after it.
      final lateness = observed.date.difference(target).inDays;
      if (lateness > _latenessTolerance(horizon)) continue;

      final training = points.sublist(0, end + 1);
      final prices = <double>[for (final p in training) p.price];
      // Asked for the same window and the same horizon, the engine returns the
      // trend reading and the forecast the card screen would have shown, fitted
      // to the same series in the same way. There is no second model here to
      // drift away from the one that ships.
      final analytics = analyzeSeries(
        training,
        windowDays: effectiveWindow(training),
        forecastHorizon: horizon,
      );
      final forecast = analytics.forecast;
      if (forecast == null) continue;
      final index = horizon - 1;
      cardTrials.add(
        ForecastTrial(
          trainedThrough: trainedThrough,
          predictedFor: target,
          observedOn: observed.date,
          trainedDays: training.length,
          horizonDays: horizon,
          anchor: prices.last,
          predicted: forecast.point[index],
          lower80: forecast.lower80[index],
          upper80: forecast.upper80[index],
          lower95: forecast.lower95[index],
          upper95: forecast.upper95[index],
          actual: observed.price,
          trendScore: analytics.trendScore,
          direction: analytics.direction,
        ),
      );
    }
    if (cardTrials.isEmpty) {
      tooShort++;
      continue;
    }
    trials.addAll(cardTrials);
    perCard.add(
      CardBacktest(
        cardId: cardId,
        score: ForecastScore.of(cardTrials),
        trainedDays: cardTrials
            .map((t) => t.trainedDays)
            .reduce((a, b) => a > b ? a : b),
        firstTrial: cardTrials.first.predictedFor,
        lastTrial: cardTrials.last.predictedFor,
      ),
    );
    for (final t in cardTrials) {
      trainLengths.add(t.trainedDays);
      if (earliest == null || t.predictedFor.isBefore(earliest)) {
        earliest = t.predictedFor;
      }
      if (latest == null || t.predictedFor.isAfter(latest)) {
        latest = t.predictedFor;
      }
    }
  }

  trainLengths.sort();
  final median = trainLengths.isEmpty
      ? 0
      : trainLengths[trainLengths.length ~/ 2];
  perCard.sort((a, b) => b.score.trials.compareTo(a.score.trials));

  return ForecastAudit(
    gameLabel: gameLabel,
    horizonDays: horizon,
    minTrainingDays: floor,
    flatBandFraction: flatBandFraction,
    overall: ForecastScore.of(trials),
    trials: List<ForecastTrial>.unmodifiable(trials),
    cards: perCard,
    cardsOffered: offered,
    cardsTested: perCard.length,
    cardsTooShort: tooShort,
    trialsPerCard: allocation,
    budgetCapped: capped,
    trainedDaysMedian: median,
    earliestPrediction: earliest,
    latestPrediction: latest,
  );
}

/// The latest training window whose target day can actually be judged.
///
/// The last observation of a series can never be used as a training end for a
/// forecast that reaches past the end of that series, so a spread taken over
/// every index would waste its longest slots on windows with nothing to check
/// them against.
int _lastJudgeableEnd(List<PricePoint> points, int horizon, int floor) {
  final tolerance = _latenessTolerance(horizon);
  for (var end = points.length - 2; end >= floor - 1; end--) {
    final target = points[end].date.add(Duration(days: horizon));
    final observed = _firstAtOrAfter(points, target, end + 1);
    if (observed == null) continue;
    // A gap can push the observation past the tolerance; that window is not
    // judgeable either, but an earlier one may be.
    if (observed.date.difference(target).inDays > tolerance) continue;
    return end;
  }
  return floor - 2;
}

/// How late an observation may be and still stand in for the target day.
int _latenessTolerance(int horizon) {
  final quarter = (horizon / 4).ceil();
  return quarter < 3 ? 3 : quarter;
}

/// The observation at [from] or the first one after it, within the series.
PricePoint? _firstAtOrAfter(List<PricePoint> points, DateTime date, int from) {
  for (var i = from; i < points.length; i++) {
    if (!points[i].date.isBefore(date)) return points[i];
  }
  return null;
}

/// Training-window ends to test, spread evenly from the shortest allowed window
/// to the latest one that still has a price to be judged against.
///
/// When only one window is allowed the earliest legal one is used, so that
/// asking for a single prediction gives the same answer however much more
/// history accumulates afterwards.
List<int> _trainingEnds({
  required int floor,
  required int lastEnd,
  required int maxTrials,
}) {
  final first = floor - 1;
  final last = lastEnd;
  if (last < first) return const <int>[];
  final span = last - first;
  final wanted = maxTrials < 1 ? 1 : maxTrials;
  if (wanted <= 1) return <int>[first];
  if (span + 1 <= wanted) {
    return <int>[for (var i = first; i <= last; i++) i];
  }
  final ends = <int>{};
  for (var k = 0; k < wanted; k++) {
    ends.add(first + (span * k / (wanted - 1)).round());
  }
  final sorted = ends.toList()..sort();
  return sorted;
}

/// Sorted, de-duplicated, positive prices - the same cleaning the analytics
/// library does, because a zero or a gap here would silently poison a fit.
List<PricePoint> _sanitize(List<PricePoint> input) {
  final byDay = <int, PricePoint>{};
  for (final p in input) {
    if (!p.price.isFinite || p.price <= 0) continue;
    final day = DateTime.utc(p.date.year, p.date.month, p.date.day);
    byDay[day.millisecondsSinceEpoch] = PricePoint(day, p.price);
  }
  final keys = byDay.keys.toList()..sort();
  return <PricePoint>[for (final k in keys) byDay[k]!];
}
