/// Set and card codes as they are printed, and as the app keeps them.
///
/// Bandai prints **BT-26** on the box and the catalogue keeps **BT26**; the same
/// for **ST-23** and **EX-13**. Yu-Gi-Oh! prints **MAMA-EN001**. Magic prints
/// **BLB** and Lorcana **1**. A collector typing what is in their hand should
/// not have to know which form the app happens to keep, so a search folds both
/// sides to letters and digits before comparing them - and the fold runs the
/// other way too, so "bt26" finds a code stored as "BT-26".
///
/// Only separators are dropped. Case is folded, but nothing else: "sv1" is not
/// made to match "sv01", because a leading zero is part of the number a
/// collector reads off the card.
abstract final class Codes {
  /// The comparison form of a code or a query: lower case, no separators.
  ///
  /// `"BT-26"` -> `"bt26"`, `"ST-23"` -> `"st23"`, `"MAMA-EN001"` ->
  /// `"mamaen001"`. A query of nothing but punctuation folds to the empty
  /// string, which matches nothing and is left to the caller to handle.
  static String fold(String raw) =>
      raw.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// Whether [code] answers to [needle], where the needle is already folded.
  ///
  /// Folding the code here rather than asking every caller to fold first keeps
  /// the two sides of the comparison from drifting apart.
  static bool matches(String code, String foldedNeedle) =>
      foldedNeedle.isEmpty ? false : fold(code).contains(foldedNeedle);

  /// The separators [fold] drops, spelled out for SQLite.
  ///
  /// SQL has no regular expressions here, so a folded column has to be built
  /// one `replace()` at a time - see [foldedSql]. The list lives beside [fold]
  /// so the two agree on what a separator is.
  static const List<String> separators = <String>['-', ' ', '.', '/', '_', ':'];

  /// A SQL expression for [column] with its separators removed and its case
  /// folded, e.g. `replace(replace(lower(code),'-',''),' ','')`.
  ///
  /// SQLite's [separators] are stripped one at a time; anything outside the list
  /// that [fold] would drop stays, which is why the two are kept together.
  static String foldedSql(String column) {
    var expr = 'lower($column)';
    for (final String separator in separators) {
      expr = "replace($expr, '$separator', '')";
    }
    return expr;
  }
}
