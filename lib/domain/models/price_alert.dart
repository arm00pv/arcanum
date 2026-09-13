import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';

/// What a price alert is watching for.
enum AlertKind {
  /// Fires when the price climbs past an absolute value.
  above('above', 'Price rises above', 'absolute'),

  /// Fires when the price drops below an absolute value.
  below('below', 'Price falls below', 'absolute'),

  /// Fires when the price gains a percentage on its baseline.
  percentUp('percent_up', 'Price rises by', 'percent'),

  /// Fires when the price loses a percentage on its baseline.
  percentDown('percent_down', 'Price falls by', 'percent');

  const AlertKind(this.code, this.label, this.mode);

  /// Stable code stored in SQLite.
  final String code;

  /// How the rule reads in the UI, e.g. "Price rises above".
  final String label;

  /// Whether [PriceAlert.threshold] is money or a percentage.
  final String mode;

  bool get isPercent => mode == 'percent';

  static AlertKind fromCode(String? c) => AlertKind.values.firstWhere(
    (k) => k.code == c,
    orElse: () => AlertKind.above,
  );
}

/// A standing instruction to watch one printing's price.
///
/// Percentage alerts are measured against the price at the moment the alert was
/// created rather than a rolling window, which is what a collector means by
/// "tell me if this goes up 20%": up 20% from when I started watching.
class PriceAlert {
  const PriceAlert({
    this.id,
    required this.game,
    required this.cardId,
    this.finish,
    required this.kind,
    required this.threshold,
    required this.createdAt,
    this.triggeredAt,
    this.baseline,
    this.lastValue,
    this.cardName = '',
    this.setCode = '',
  });

  /// Row id, null until persisted.
  final int? id;

  final CardGame game;
  final String cardId;

  /// The finish being watched. Defaults to the game's primary finish.
  final CardFinish? finish;

  final AlertKind kind;

  /// Money for absolute rules, a percentage for the others.
  final double threshold;

  final DateTime createdAt;

  /// When the rule last fired, or null while it is still armed.
  final DateTime? triggeredAt;

  /// The price the alert was armed at, used as the reference for percentages.
  final double? baseline;

  /// The most recent evaluated price, cached so the list can show it without a
  /// lookup.
  final double? lastValue;

  /// Denormalised for display only; refreshed whenever the alert is evaluated.
  final String cardName;
  final String setCode;

  /// The finish this alert evaluates, falling back to the game's first.
  CardFinish get effectiveFinish => finish ?? game.finishes.first;

  bool get isArmed => triggeredAt == null;

  /// The value the rule is compared against.
  double? get reference => kind.isPercent ? baseline : null;

  /// Progress toward firing, 0..1, for the UI's meter. Null when it cannot be
  /// computed (no current price, or a divide-by-zero baseline).
  double? progress(double? current) {
    if (current == null) return null;
    if (!kind.isPercent) {
      // Show how close the price is to the target line.
      final start = baseline ?? lastValue;
      if (start == null || start <= 0 || start == threshold) {
        return kind == AlertKind.above
            ? (current >= threshold ? 1 : 0)
            : (current <= threshold ? 1 : 0);
      }
      final span = (threshold - start).abs();
      if (span == 0) return null;
      final travelled = kind == AlertKind.above
          ? current - start
          : start - current;
      return (travelled / span).clamp(0.0, 1.0);
    }
    final base = baseline;
    if (base == null || base <= 0 || threshold <= 0) return null;
    final change = kind == AlertKind.percentUp
        ? (current / base - 1) * 100
        : (base / current - 1) * 100;
    return (change / threshold).clamp(0.0, 1.0);
  }

  /// A human sentence describing what this alert watches for.
  String describe() {
    final money = kind.isPercent ? null : threshold;
    final suffix = kind.isPercent
        ? '${threshold.toStringAsFixed(threshold % 1 == 0 ? 0 : 1)}%'
        : money!.toStringAsFixed(2);
    return '${kind.label} $suffix';
  }

  PriceAlert copyWith({
    int? id,
    AlertKind? kind,
    double? threshold,
    Object? triggeredAt = _unset,
    Object? baseline = _unset,
    Object? lastValue = _unset,
    String? cardName,
    String? setCode,
  }) => PriceAlert(
    id: id ?? this.id,
    game: game,
    cardId: cardId,
    finish: finish,
    kind: kind ?? this.kind,
    threshold: threshold ?? this.threshold,
    createdAt: createdAt,
    triggeredAt: triggeredAt == _unset
        ? this.triggeredAt
        : triggeredAt as DateTime?,
    baseline: baseline == _unset ? this.baseline : baseline as double?,
    lastValue: lastValue == _unset ? this.lastValue : lastValue as double?,
    cardName: cardName ?? this.cardName,
    setCode: setCode ?? this.setCode,
  );

  static const _unset = Object();

  Map<String, Object?> toRow() => {
    if (id != null) 'id': id,
    'game': game.id,
    'card_id': cardId,
    'finish': effectiveFinish.code,
    'kind': kind.code,
    'threshold': threshold,
    'created_at': createdAt.millisecondsSinceEpoch,
    'triggered_at': triggeredAt?.millisecondsSinceEpoch,
    'baseline': baseline,
    'last_value': lastValue,
  };

  factory PriceAlert.fromRow(Map<String, Object?> r) => PriceAlert(
    id: r['id'] as int?,
    game: CardGame.fromId(r['game'] as String?),
    cardId: r['card_id'] as String,
    finish: CardFinish.fromCode(r['finish'] as String?),
    kind: AlertKind.fromCode(r['kind'] as String?),
    threshold: (r['threshold'] as num?)?.toDouble() ?? 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (r['created_at'] as int?) ?? 0,
    ),
    triggeredAt: r['triggered_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['triggered_at'] as int),
    baseline: (r['baseline'] as num?)?.toDouble(),
    lastValue: (r['last_value'] as num?)?.toDouble(),
  );
}

/// The outcome of checking one alert against the current market.
class AlertEvaluation {
  const AlertEvaluation({
    required this.alert,
    required this.triggered,
    required this.current,
    this.message,
  });

  final PriceAlert alert;

  /// Whether the rule's condition is met right now.
  final bool triggered;

  /// The current unit price for the alert's finish, or null when unavailable.
  final double? current;

  /// A short explanation, present when [triggered].
  final String? message;
}
