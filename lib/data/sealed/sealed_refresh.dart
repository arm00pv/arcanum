import 'package:arcanum/data/db/sealed_dao.dart';
import 'package:arcanum/data/sealed/sealed_lookup.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/sealed_product.dart';

/// What one pass over the shelf changed.
class SealedRefresh {
  /// Creates a report.
  const SealedRefresh({
    required this.setsAsked,
    required this.priced,
    required this.unpriced,
    required this.unchanged,
    required this.asOf,
  });

  /// How many sets were looked up.
  final int setsAsked;

  /// Holdings whose price was written.
  final int priced;

  /// Holdings the price list did not answer for.
  final int unpriced;

  /// Holdings whose price had not moved.
  final int unchanged;

  /// When the prices were seen.
  final DateTime asOf;

  /// How many prices actually moved.
  int get moved => priced - unchanged;

  /// Whether anything moved.
  bool get changedAnything => moved > 0;

  /// The sentence the screen shows afterwards.
  String get summary {
    if (setsAsked == 0) {
      return 'Nothing on the shelf names a set, so there was nothing to look '
          'up.';
    }
    final List<String> parts = <String>[
      if (moved > 0) '$moved prices moved',
      if (unchanged > 0) '$unchanged already current',
      if (unpriced > 0) '$unpriced not in the price list',
    ];
    if (parts.isEmpty) return 'Nothing was priced.';
    return '${parts.join(', ')}.';
  }
}

/// Refreshes the price of everything on the sealed shelf.
///
/// A holding keeps the last figure anything saw for it, which is honest and goes
/// stale: a box added a year ago would still be valued at the price on the day
/// it was added. This asks the price list again - once per set, not once per box
/// - and writes what comes back.
///
/// It never invents a price. A product the list does not carry keeps the figure
/// it already had, and the report says how many of those there were rather than
/// quietly leaving them out of the count.
Future<SealedRefresh> refreshSealedPrices({
  required CardGame game,
  required List<SealedHolding> holdings,
  required SealedPriceSource source,
  required SealedDao dao,
  DateTime? now,
}) async {
  final DateTime at = now ?? DateTime.now();
  final Set<String> setCodes = <String>{
    for (final SealedHolding h in holdings)
      if (h.setCode.trim().isNotEmpty) h.setCode.trim(),
  };

  var priced = 0;
  var unpriced = 0;
  var unchanged = 0;
  var asked = 0;

  for (final String code in setCodes) {
    final List<SealedOffer> offers = await source.forSet(game, code);
    asked++;
    final Map<String, double> byProduct = <String, double>{
      for (final SealedOffer offer in offers)
        if (offer.productId.isNotEmpty && offer.isPriced)
          offer.productId: offer.market!,
    };
    final Map<String, double> byName = <String, double>{
      for (final SealedOffer offer in offers)
        if (offer.isPriced) offer.name.trim().toLowerCase(): offer.market!,
    };

    for (final SealedHolding holding in holdings) {
      if (holding.setCode.trim() != code) continue;
      // A product this app looked up carries the price list's own id; one typed
      // in by hand has none, and its exact name is the only thing left to match
      // on. An exact match is a fact; a near one would be a guess dressed up as
      // a price, so nothing looser than this is tried.
      final double? market = holding.productId.isNotEmpty
          ? byProduct[holding.productId]
          : byName[holding.name.trim().toLowerCase()];
      if (market == null) {
        unpriced++;
        continue;
      }
      if (holding.unitValue != null && holding.unitValue == market) {
        unchanged++;
        continue;
      }
      if (holding.productId.isNotEmpty) {
        await dao.priceByProductId(
          game: game,
          productId: holding.productId,
          unitValue: market,
          asOf: at,
        );
      } else if (holding.id != null) {
        await dao.update(holding.copyWith(unitValue: market, valueAsOf: at));
      }
      priced++;
    }
  }

  return SealedRefresh(
    setsAsked: asked,
    priced: priced,
    unpriced: unpriced,
    unchanged: unchanged,
    asOf: at,
  );
}
