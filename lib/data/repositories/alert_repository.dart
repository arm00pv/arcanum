import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/db/alert_dao.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/price_alert.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// Creates, evaluates and re-arms price alerts.
///
/// Evaluation deliberately runs against the *stored* market prices rather than
/// fetching. Those prices are already refreshed daily — Scryfall and TCGdex both
/// update at most once a day — so going to the network here would add latency
/// and rate-limit pressure without producing a different answer. Callers that
/// genuinely want fresh data can refresh prices first via the catalogue
/// repository and then evaluate.
class AlertRepository {
  AlertRepository({required AlertDao dao, required CatalogDao catalogDao})
    : _dao = dao,
      _cat = catalogDao;

  final AlertDao _dao;
  final CatalogDao _cat;

  /// Every alert for a game.
  Future<List<PriceAlert>> all(CardGame game) => _dao.all(game);

  /// Armed alerts for one printing.
  Future<List<PriceAlert>> forCard(CardGame game, String cardId) =>
      _dao.forCard(game, cardId);

  Future<int> triggeredCount(CardGame game) => _dao.triggeredCount(game);

  Future<int> count(CardGame game) => _dao.count(game);

  /// Creates an alert, capturing the current price as the baseline so that
  /// percentage rules have something meaningful to measure against.
  Future<int> create({
    required TcgCard card,
    required AlertKind kind,
    required double threshold,
    CardFinish? finish,
  }) async {
    final f = finish ?? card.game.finishes.first;
    final current = card.prices.priceFor(f) ?? card.prices.from;
    return _dao.insert(
      PriceAlert(
        game: card.game,
        cardId: card.id,
        finish: f,
        kind: kind,
        threshold: threshold,
        createdAt: DateTime.now(),
        baseline: current,
        lastValue: current,
        cardName: card.name,
        setCode: card.setCode,
      ),
    );
  }

  Future<void> delete(int id) => _dao.delete(id);

  /// Re-arms a fired alert, rebasing it on the current price.
  Future<void> rearm(PriceAlert alert, TcgCard? card) async {
    if (alert.id == null) return;
    final current =
        card?.prices.priceFor(alert.effectiveFinish) ?? card?.prices.from;
    await _dao.rearm(alert.id!, baseline: current);
  }

  Future<void> deleteAllForCard(CardGame game, String cardId) async {
    final alerts = await _dao.forCard(game, cardId);
    for (final a in alerts) {
      if (a.id != null) await _dao.delete(a.id!);
    }
  }

  /// Checks every armed alert in the given games and records the outcome.
  ///
  /// Returns the evaluations that fired, newest first, so the caller can
  /// surface them. Armed alerts that did not fire still have their cached price
  /// updated so the list shows something current.
  Future<List<AlertEvaluation>> evaluate({
    Iterable<CardGame> games = CardGame.values,
    bool persist = true,
  }) async {
    final armed = await _dao.armed();
    if (armed.isEmpty) return const [];

    final wanted = games.toSet();
    final inScope = armed.where((a) => wanted.contains(a.game)).toList();
    if (inScope.isEmpty) return const [];

    // One round trip per game for the card data.
    final cardsByGame = <CardGame, Map<String, TcgCard>>{};
    for (final game in wanted) {
      final ids = inScope
          .where((a) => a.game == game)
          .map((a) => a.cardId)
          .toSet()
          .toList();
      if (ids.isEmpty) continue;
      cardsByGame[game] = await _cat.cardsByIds(game, ids);
    }

    final fired = <AlertEvaluation>[];
    for (final alert in inScope) {
      final card = cardsByGame[alert.game]?[alert.cardId];
      final current =
          card?.prices.priceFor(alert.effectiveFinish) ?? card?.prices.from;

      final triggered = _isTriggered(alert, current);
      if (persist && alert.id != null) {
        await _dao.markEvaluated(
          alert.id!,
          lastValue: current ?? alert.lastValue,
          triggered: triggered,
        );
      }
      if (triggered) {
        fired.add(
          AlertEvaluation(
            alert: alert,
            triggered: true,
            current: current,
            message: _describe(alert, current),
          ),
        );
      } else if (current != null && alert.lastValue != current) {
        await _dao.markEvaluated(
          alert.id!,
          lastValue: current,
          triggered: false,
        );
      }
    }

    fired.sort((a, b) => b.alert.createdAt.compareTo(a.alert.createdAt));
    return fired;
  }

  /// Evaluates one alert without persisting, for live preview in the UI.
  AlertEvaluation preview(PriceAlert alert, double? current) => AlertEvaluation(
    alert: alert,
    triggered: _isTriggered(alert, current),
    current: current,
    message: _isTriggered(alert, current) ? _describe(alert, current) : null,
  );

  static bool _isTriggered(PriceAlert alert, double? current) {
    if (current == null || current <= 0) return false;
    switch (alert.kind) {
      case AlertKind.above:
        return current > alert.threshold;
      case AlertKind.below:
        return current < alert.threshold;
      case AlertKind.percentUp:
        final base = alert.baseline;
        if (base == null || base <= 0) return false;
        return _percentUp(current, base) >= alert.threshold;
      case AlertKind.percentDown:
        final base = alert.baseline;
        if (base == null || base <= 0) return false;
        return _percentDown(current, base) >= alert.threshold;
    }
  }

  /// How far a price has risen above its baseline, as a percentage.
  ///
  /// Written as a difference over the baseline rather than as a ratio minus
  /// one. The two are the same arithmetic on paper, but in binary floating point
  /// `(120 / 100 - 1) * 100` comes out as 19.999999999999996 - so a 20% alert
  /// would quietly not fire on a price that had risen exactly 20%. The app and
  /// the companion both use this form so the two cannot disagree.
  static double _percentUp(double current, double base) =>
      (current - base) / base * 100;

  /// How far a price has fallen below its baseline, as a percentage.
  static double _percentDown(double current, double base) =>
      (base - current) / current * 100;

  static String _describe(PriceAlert alert, double? current) {
    if (current == null) return 'Price unavailable';
    switch (alert.kind) {
      case AlertKind.above:
        return 'Now ${Fmt.money(current)}, above your '
            '${Fmt.money(alert.threshold)} target.';
      case AlertKind.below:
        return 'Now ${Fmt.money(current)}, below your '
            '${Fmt.money(alert.threshold)} target.';
      case AlertKind.percentUp:
        final base = alert.baseline ?? 0;
        final pct = base > 0 ? _percentUp(current, base) : 0.0;
        return 'Up ${Fmt.percentPlain(pct)} since you set this alert '
            '(now ${Fmt.money(current)}, from ${Fmt.money(base)}).';
      case AlertKind.percentDown:
        final base = alert.baseline ?? 0;
        final pct = base > 0 ? _percentDown(current, base) : 0.0;
        return 'Down ${Fmt.percentPlain(pct)} since you set this alert '
            '(now ${Fmt.money(current)}, from ${Fmt.money(base)}).';
    }
  }
}
