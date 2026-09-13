/// How much of one set the collector owns.
///
/// Completion is measured against the binder slots the app actually holds, not
/// against a published set size. Two reasons. Some providers state no size at
/// all (Lorcast states none anywhere), and a set the collector has not
/// downloaded yet would read as 0 of 180 - a number about the cache dressed up
/// as a number about the collection. Counting against what is on the phone
/// means the bar can reach the end, which is the only thing a progress bar is
/// allowed to imply.
class SetCompletion {
  const SetCompletion({
    required this.code,
    required this.name,
    required this.owned,
    required this.total,
    required this.published,
  });

  /// The set's code, which is how every screen addresses it.
  final String code;

  /// The set's name, carried along so a summary can be built without a join.
  final String name;

  /// Binder slots filled. Two copies of one card count once, and so do two
  /// versions of it: the question is which cards are missing, not how many
  /// printings are in the box.
  final int owned;

  /// Binder slots the app holds for this set.
  final int total;

  /// What the provider says the set contains, when it says anything.
  ///
  /// Kept because it is the honest answer when it differs from [total]: a set
  /// whose size is stated as 180 while 176 slots are cached is a set whose last
  /// four cards the app cannot yet offer.
  final int published;

  /// True once the set has been downloaded, and so has a meaningful bar.
  bool get known => total > 0;

  /// Never above 1: a provider that understates a set must not produce a bar
  /// that overflows its own track.
  double get fraction => total == 0 ? 0 : (owned / total).clamp(0.0, 1.0);

  int get missing => total > owned ? total - owned : 0;

  /// True when something has been collected from this set.
  bool get started => owned > 0;

  /// True when every slot the app holds is filled.
  bool get complete => total > 0 && owned >= total;

  /// True when the provider states a size the cache has not caught up with.
  bool get short => published > total;
}
