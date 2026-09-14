import 'package:intl/intl.dart';

/// Centralised formatting so every number in the app reads consistently.
abstract final class Fmt {
  static final _money = NumberFormat.currency(symbol: r'$', decimalDigits: 2);
  static final _moneyCompact = NumberFormat.compactCurrency(
    symbol: r'$',
    decimalDigits: 1,
  );
  static final _int = NumberFormat.decimalPattern();
  static final _compact = NumberFormat.compact();
  static final _date = DateFormat('d MMM yyyy');
  static final _dateShort = DateFormat('d MMM');
  static final _monthYear = DateFormat('MMM yyyy');

  /// `$1,234.56`
  static String money(double? v) => v == null ? '--' : _money.format(v);

  /// `$12.3K` for headline figures.
  static String moneyCompact(double? v) =>
      v == null ? '--' : _moneyCompact.format(v);

  /// Money that adapts precision to magnitude: cents matter under $100, not above.
  static String moneyAdaptive(double? v) {
    if (v == null) return '--';
    if (v.abs() >= 1000) return _moneyCompact.format(v);
    if (v.abs() >= 100) {
      return NumberFormat.currency(symbol: r'$', decimalDigits: 1).format(v);
    }
    return _money.format(v);
  }

  /// Signed money, e.g. `+$12.40`.
  static String moneySigned(double? v) {
    if (v == null) return '--';
    final s = money(v.abs());
    return v >= 0 ? '+$s' : '-$s';
  }

  /// A plain integer with thousands separators, e.g. \`12,480\`.
  static String count(int? v) => v == null ? '--' : _int.format(v);

  /// A count with its noun, singular where the count is one: `1 card`,
  /// `2 cards`.
  ///
  /// Every noun it is given pluralises with an `s`. The line above a
  /// collection is read by someone with a single card in it as often as by
  /// someone with ten thousand, and "1 cards" is wrong for the first of them.
  static String countOf(int? v, String noun) =>
      '${count(v)} $noun${v == 1 ? '' : 's'}';
  static String compact(num? v) => v == null ? '--' : _compact.format(v);

  /// `+12.4%`
  static String percent(double? v, {int digits = 1, bool signed = true}) {
    if (v == null || v.isNaN || v.isInfinite) return '--';
    final s = '${v.abs().toStringAsFixed(digits)}%';
    if (!signed) return s;
    return v >= 0 ? '+$s' : '-$s';
  }

  static String percentPlain(double? v, {int digits = 0}) =>
      v == null || v.isNaN || v.isInfinite
      ? '--'
      : '${v.toStringAsFixed(digits)}%';

  static String date(DateTime? d) => d == null ? '--' : _date.format(d);
  static String dateShort(DateTime? d) =>
      d == null ? '--' : _dateShort.format(d);
  static String monthYear(DateTime? d) =>
      d == null ? '--' : _monthYear.format(d);

  /// Relative time, e.g. `3 h ago`.
  static String ago(DateTime? d) {
    if (d == null) return 'never';
    final diff = DateTime.now().difference(d);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays < 30) return '${diff.inDays} d ago';
    if (diff.inDays < 365) return '${(diff.inDays / 30).round()} mo ago';
    return '${(diff.inDays / 365).toStringAsFixed(1)} y ago';
  }

  /// Relative time in the other direction, e.g. `in 6 d`.
  ///
  /// [ago] reads a moment that has passed, and a moment still to come handed to
  /// it comes back as "just now" - which is how a link that lasts a week came
  /// to say it expired the minute it was made.
  static String away(DateTime? d) {
    if (d == null) return 'never';
    final diff = d.difference(DateTime.now());
    if (diff.inSeconds <= 0) return 'now';
    if (diff.inSeconds < 60) return 'in ${diff.inSeconds} s';
    if (diff.inMinutes < 60) return 'in ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'in ${diff.inHours} h';
    if (diff.inDays < 30) return 'in ${diff.inDays} d';
    if (diff.inDays < 365) return 'in ${(diff.inDays / 30).round()} mo';
    return 'in ${(diff.inDays / 365).toStringAsFixed(1)} y';
  }

  /// Turns a Scryfall set_type into something readable.
  static String setType(String raw) {
    switch (raw) {
      case 'expansion':
        return 'Expansion';
      case 'core':
        return 'Core Set';
      case 'masters':
        return 'Masters';
      case 'commander':
        return 'Commander';
      case 'draft_innovation':
        return 'Draft Innovation';
      case 'funny':
        return 'Un-Set';
      case 'promo':
        return 'Promo';
      case 'token':
        return 'Token';
      case 'memorabilia':
        return 'Memorabilia';
      case 'box':
        return 'Box Set';
      case 'from_the_vault':
        return 'From the Vault';
      case 'spellbook':
        return 'Spellbook';
      case 'premium_deck':
        return 'Premium Deck';
      case 'duel_deck':
        return 'Duel Deck';
      case 'planechase':
        return 'Planechase';
      case 'archenemy':
        return 'Archenemy';
      case 'vanguard':
        return 'Vanguard';
      case 'treasure_chest':
        return 'Treasure Chest';
      case 'alchemy':
        return 'Alchemy';
      case 'minigame':
        return 'Minigame';
      default:
        return raw
            .split('_')
            .map(
              (w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}',
            )
            .join(' ');
    }
  }
}
