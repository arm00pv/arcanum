import 'dart:async';

import 'package:dio/dio.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// Pokémon Trading Card Game card data, served by TCGdex.
///
/// TCGdex was chosen over the older pokemontcg.io API for two reasons: it is
/// free and keyless with no deprecation clock, and its card responses embed
/// live prices **and** the TCGplayer product id, which is the join key needed to
/// pull real price history from JustTCG.
///
/// The id, collector number and name the set list gives for one card.
typedef _CardStub = ({String id, String localId, String name});

/// The shape of the API drives the design here: the set list is one cheap call,
/// but a set's card list carries only names and image URLs, so rarity, types and
/// prices require one call per card. That is a one-time cost per set — the
/// results are cached in SQLite forever — and it is reported through
/// [onProgress] so the UI can show a real progress bar rather than a spinner.
class PokemonCatalog implements CardCatalog {
  PokemonCatalog({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: _base,
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 25),
              headers: const {
                'Accept': 'application/json',
                'User-Agent': 'Arcanum/1.0 (+https://github.com/arcanum)',
              },
            ));

  static const _base = 'https://api.tcgdex.net/v2/en';

  /// Card images are served from this CDN without a file extension.
  static const _assets = 'https://assets.tcgdex.net/en';

  /// How many card detail requests run at once.
  static const _concurrency = 8;

  /// Retries per request before giving up on a single card.
  static const _maxRetries = 3;

  /// Upper bound on the detail calls one search will make.
  ///
  /// The search endpoint answers with ids and names only, so every hit worth
  /// showing costs another request. 60 keeps a search to a handful of round
  /// trips at [_concurrency] while covering far more than the first screen of
  /// results; a name like "Pikachu" matches over two hundred printings, and the
  /// user is choosing between the first few dozen of them, not the last.
  static const _maxSearchResults = 60;

  final Dio _dio;

  @override
  CardGame get game => CardGame.pokemon;

  @override
  String get sourceName => 'TCGdex';

  // ------------------------------------------------------------------- sets

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async {
    final List<dynamic> raw;
    try {
      final res = await _dio.get<dynamic>('/sets');
      raw = res.data as List<dynamic>;
    } on DioException catch (e) {
      throw CatalogException(
        e.message ?? 'Could not reach TCGdex',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }

    final stubs = <TcgSet>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final id = item['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final counts = item['cardCount'];
      final total = counts is Map ? (counts['total'] as num?)?.toInt() ?? 0 : 0;
      stubs.add(TcgSet(
        game: CardGame.pokemon,
        id: id,
        code: id,
        name: item['name']?.toString() ?? id,
        setType: 'expansion',
        // The list endpoint does not carry release dates; they are filled in
        // when each set is enriched below.
        cardCount: total,
      ));
    }

    // The list endpoint omits the release date, series and logo, so each set is
    // enriched individually. Bounded concurrency keeps this polite.
    final enriched = List<TcgSet?>.filled(stubs.length, null);
    var done = 0;
    onProgress?.call(0, stubs.length);

    final queue = List<int>.generate(stubs.length, (i) => i);
    Future<void> worker() async {
      while (true) {
        if (queue.isEmpty) return;
        final i = queue.removeAt(0);
        try {
          final res = await _retry(() => _dio.get<dynamic>('/sets/${stubs[i].id}'));
          final data = res.data;
          enriched[i] = data is Map ? _setFromJson(stubs[i], data) : stubs[i];
        } catch (_) {
          enriched[i] = stubs[i];
        }
        done++;
        onProgress?.call(done, stubs.length);
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));
    return [for (final s in enriched) s ?? stubs.first];
  }

  TcgSet _setFromJson(TcgSet stub, Map<dynamic, dynamic> data) {
    final serie = data['serie'];
    final logo = data['logo']?.toString();
    final release = data['releaseDate']?.toString();
    final counts = data['cardCount'];
    final official = counts is Map ? (counts['official'] as num?)?.toInt() : null;
    return TcgSet(
      game: CardGame.pokemon,
      id: stub.id,
      code: stub.code,
      name: data['name']?.toString() ?? stub.name,
      setType: 'expansion',
      releasedAt: release == null ? null : DateTime.tryParse(release),
      cardCount: official ?? stub.cardCount,
      printedSize: official,
      // Pokémon sets have logos rather than the monochrome symbols Magic uses.
      logoUri: logo == null ? null : '$logo.webp',
      series: serie is Map ? serie['name']?.toString() : null,
      collectorNumberStart: 1,
    );
  }

  /// Fetches a set's metadata, its series and its card list in one request.
  ///
  /// The series slug is carried back out because TCGdex's asset CDN addresses
  /// art as `en/<serie>/<set>/<number>/high.webp`. A card whose own detail call
  /// fails has no `image` field to copy, and a URL built from the set id alone
  /// - `en/<set>/<number>/high.webp` - answers 404, so without the slug those
  /// cards could never be given working art.
  Future<({TcgSet? set, List<_CardStub> cards, String? serie})> _setDetail(
    String setId,
  ) async {
    final Response<dynamic> res;
    try {
      res = await _retry(() => _dio.get<dynamic>('/sets/$setId'));
    } on DioException catch (e) {
      // An unknown set is an empty set, not a failure: the caller asked for
      // something TCGdex does not hold, and the screen should say there is
      // nothing rather than that something went wrong. Anything else is a real
      // error and is typed like every other catalogue error, so the UI can
      // report it in the same words whichever game it came from.
      if (e.response?.statusCode == 404) {
        return (set: null, cards: const <_CardStub>[], serie: null);
      }
      throw CatalogException(
        e.message ?? 'Could not reach TCGdex',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }
    final data = res.data;
    if (data is! Map) {
      return (set: null, cards: const <_CardStub>[], serie: null);
    }

    final stub = TcgSet(
      game: CardGame.pokemon,
      id: setId,
      code: setId,
      name: data['name']?.toString() ?? setId,
      setType: 'expansion',
    );
    final set = _setFromJson(stub, data);

    final serie = data['serie'];
    final serieId = serie is Map ? serie['id']?.toString() : null;

    final cards = <_CardStub>[];
    final rawCards = data['cards'];
    if (rawCards is List) {
      for (final c in rawCards) {
        if (c is! Map) continue;
        final id = c['id']?.toString();
        if (id == null || id.isEmpty) continue;
        cards.add((
          id: id,
          localId: c['localId']?.toString() ?? '',
          name: c['name']?.toString() ?? '',
        ));
      }
    }
    return (set: set, cards: cards, serie: serieId);
  }

  // ------------------------------------------------------------------ cards

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async {
    final detail = await _setDetail(setCode.toLowerCase());
    final set = detail.set;
    final stubs = detail.cards;
    if (stubs.isEmpty) return const [];

    final results = List<TcgCard?>.filled(stubs.length, null);
    var done = 0;
    onProgress?.call(0, stubs.length);

    final queue = List<int>.generate(stubs.length, (i) => i);
    Future<void> worker() async {
      while (true) {
        if (queue.isEmpty) return;
        final i = queue.removeAt(0);
        try {
          final res = await _retry(() => _dio.get<dynamic>('/cards/${stubs[i].id}'));
          final data = res.data;
          if (data is Map) {
            results[i] = _cardFromJson(
              set,
              data,
              stubs[i].localId,
              stubs[i].name,
              serie: detail.serie,
            );
          }
        } catch (_) {
          // A single missing card must not sink the whole set.
        }
        done++;
        onProgress?.call(done, stubs.length);
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));

    // A card whose detail call failed still belongs in the list, with its name
    // and image, so the set stays complete.
    return [
      for (var i = 0; i < stubs.length; i++)
        results[i] ??
            TcgCard(
              game: CardGame.pokemon,
              id: stubs[i].id,
              setCode: setCode.toLowerCase(),
              setName: set?.name ?? setCode,
              name: stubs[i].name,
              collectorNumber: stubs[i].localId,
              rarity: 'unknown',
              imageUris: _images(
                stubs[i].id,
                setCode.toLowerCase(),
                serie: detail.serie,
              ),
              oracleId: TcgCard.normaliseName(stubs[i].name),
            ),
    ];
  }

  @override
  Future<TcgCard?> fetchCardById(String id) async {
    try {
      final res = await _retry(() => _dio.get<dynamic>('/cards/$id'));
      final data = res.data;
      if (data is! Map) return null;
      final dash = id.lastIndexOf('-');
      final setId = dash > 0 ? id.substring(0, dash) : '';
      final localId = dash > 0 ? id.substring(dash + 1) : id;
      return _cardFromJson(null, data, localId, data['name']?.toString() ?? '', setId: setId);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      throw CatalogException(
        e.message ?? 'Could not reach TCGdex',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }
  }

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    final List<dynamic> hits;
    try {
      final res = await _retry(() => _dio.get<dynamic>(
            '/cards',
            queryParameters: {
              'name': query,
              'pagination:itemsPerPage': limit.clamp(1, 100),
            },
          ));
      final data = res.data;
      if (data is! List) return const [];
      hits = data;
    } on DioException {
      return const [];
    }

    // The search endpoint returns id, name and a thumbnail - enough to count
    // the matches but not to show them with a rarity and a price - so each hit
    // gets its own detail call. Those calls fan out across the same workers the
    // set download uses rather than running one after another, which is the
    // difference between a search that answers in one round trip and one that
    // answers in thirty.
    final ids = <String>[
      for (final item in hits)
        if (item is Map && item['id'] != null) item['id'].toString(),
    ].take(limit.clamp(1, _maxSearchResults)).toList();
    if (ids.isEmpty) return const [];

    final results = List<TcgCard?>.filled(ids.length, null);
    final queue = List<int>.generate(ids.length, (i) => i);
    Future<void> worker() async {
      while (true) {
        if (queue.isEmpty) return;
        final i = queue.removeAt(0);
        try {
          results[i] = await fetchCardById(ids[i]);
        } catch (_) {
          // One unresolvable hit must not sink the whole search.
        }
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));
    // Order is the provider's relevance order, not the order the workers
    // happened to finish in.
    return [for (final card in results) ?card];
  }

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async {
    // Pokémon indexes reprints by name, which the repository's local cache
    // already handles; there is no distinct oracle id to query by.
    return const [];
  }

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    if (cards.isEmpty) return const [];
    final out = <TcgCard>[];
    final queue = List<TcgCard>.from(cards);
    Future<void> worker() async {
      while (true) {
        if (queue.isEmpty) return;
        final card = queue.removeAt(0);
        final fresh = await fetchCardById(card.id);
        if (fresh != null) out.add(fresh);
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));
    return out;
  }

  // ---------------------------------------------------------------- mapping

  /// Builds the image URL set. TCGdex serves extension-less base URLs that need
  /// a size suffix.
  ///
  /// The series segment is not optional decoration: `en/base1/4/high.webp` is a
  /// 404 and `en/base/base1/4/high.webp` is the card. A URL is only built this
  /// way as a last resort, when the response carried no `image` of its own, and
  /// callers that know the series are expected to pass it.
  static Map<String, String> _images(String cardId, String setId, {String? serie}) {
    final base = serie == null
        ? '$_assets/$setId/${cardId.split('-').last}'
        : '$_assets/$serie/$setId/${cardId.split('-').last}';
    return {
      'small': '$base/low.webp',
      'normal': '$base/high.webp',
      'large': '$base/high.png',
    };
  }

  TcgCard _cardFromJson(
    TcgSet? set,
    Map<dynamic, dynamic> data,
    String localId,
    String name, {
    String? setId,
    String? serie,
  }) {
    final id = data['id']?.toString() ?? '';
    final resolvedSetId = setId ?? set?.id ?? (id.contains('-') ? id.split('-').first : '');
    final image = data['image']?.toString();
    // The response's own image URL is authoritative and already includes the
    // series segment, which the set id alone does not.
    final images = <String, String>{
      if (image != null && image.isNotEmpty) ...{
        'small': '$image/low.webp',
        'normal': '$image/high.webp',
        'large': '$image/high.png',
      } else
        ..._images(id, resolvedSetId, serie: serie),
    };

    final pricing = data['pricing'];
    final tcg = pricing is Map ? pricing['tcgplayer'] : null;
    final cm = pricing is Map ? pricing['cardmarket'] : null;

    final byFinish = <String, double?>{};
    String? tcgplayerId;
    if (tcg is Map) {
      tcg.forEach((key, value) {
        if (value is! Map) return;
        final price = (value['marketPrice'] as num?)?.toDouble() ??
            (value['midPrice'] as num?)?.toDouble();
        final finish = _finishForVariant(key.toString());
        if (finish != null) {
          // A later variant must not overwrite an existing price with null.
          if (price != null) byFinish[finish.code] = price;
          byFinish.putIfAbsent(finish.code, () => null);
        }
        tcgplayerId ??= value['productId']?.toString();
      });
    }

    // Variant metadata tells us which physical printings actually exist.
    final variants = data['variants'];
    final variantTypes = <String>[];
    if (variants is Map) {
      if (variants['normal'] == true) variantTypes.add(CardFinish.nonfoil.code);
      if (variants['holo'] == true) variantTypes.add(CardFinish.holofoil.code);
      if (variants['reverse'] == true) {
        variantTypes.add(CardFinish.reverseHolofoil.code);
      }
      if (variants['firstEdition'] == true) {
        variantTypes.add(CardFinish.firstEdition.code);
      }
    }

    final types = <String>[];
    final rawTypes = data['types'];
    if (rawTypes is List) {
      for (final t in rawTypes) {
        if (t is String) types.add(t);
      }
    }

    final category = data['category']?.toString() ?? '';
    final stage = data['stage']?.toString();
    final typeLine = _typeLine(category, stage);

    return TcgCard(
      game: CardGame.pokemon,
      id: id,
      setCode: resolvedSetId,
      setName: set?.name ??
          ((data['set'] is Map) ? (data['set']['name']?.toString() ?? '') : ''),
      name: data['name']?.toString() ?? name,
      collectorNumber: data['localId']?.toString() ?? localId,
      rarity: data['rarity']?.toString() ?? 'unknown',
      typeLine: typeLine,
      oracleText: _rulesText(data),
      artist: data['illustrator']?.toString(),
      flavorText: data['description']?.toString(),
      cmc: (data['hp'] as num?)?.toDouble(),
      colors: types,
      colorIdentity: types,
      prices: TcgPrices(
        byFinish: byFinish,
        secondary: {
          if (cm is Map) 'eur': (cm['trend'] as num?)?.toDouble() ?? (cm['avg'] as num?)?.toDouble(),
          if (cm is Map) 'eurLow': (cm['low'] as num?)?.toDouble(),
        },
      ),
      imageUris: images,
      releasedAt: set?.releasedAt,
      oracleId: TcgCard.normaliseName(data['name']?.toString() ?? name),
      extras: {
        'tcgplayerId': ?tcgplayerId,
        if (variantTypes.isNotEmpty) 'variants': variantTypes,
        if (data['dexId'] is List && (data['dexId'] as List).isNotEmpty)
          'pokedex': (data['dexId'] as List).first,
        if (category.isNotEmpty) 'category': category,
      },
    );
  }

  /// Composes a Pokémon type line the way the card reads, e.g.
  /// `Pokémon - Stage 2`, `Trainer - Supporter`, `Energy - Special`.
  static String _typeLine(String category, String? stage) {
    switch (category.toLowerCase()) {
      case 'pokemon':
        return stage == null || stage.isEmpty ? 'Pokémon' : 'Pokémon - $stage';
      case 'trainer':
        return 'Trainer';
      case 'energy':
        return 'Energy';
      default:
        return category;
    }
  }

  /// Flattens abilities, attacks and rules into a readable block.
  static String? _rulesText(Map<dynamic, dynamic> data) {
    final buffer = StringBuffer();

    final abilities = data['abilities'];
    if (abilities is List) {
      for (final a in abilities) {
        if (a is! Map) continue;
        final type = a['type']?.toString() ?? 'Ability';
        final name = a['name']?.toString() ?? '';
        final effect = a['effect']?.toString() ?? '';
        buffer.writeln('$type: $name');
        if (effect.isNotEmpty) buffer.writeln(effect);
        buffer.writeln();
      }
    }

    final attacks = data['attacks'];
    if (attacks is List) {
      for (final a in attacks) {
        if (a is! Map) continue;
        final cost = a['cost'];
        final costText = cost is List ? cost.join(' · ') : '';
        final name = a['name']?.toString() ?? '';
        final damage = a['damage']?.toString() ?? '';
        final effect = a['effect']?.toString() ?? '';
        final header = [costText, name, damage].where((s) => s.isNotEmpty).join('  ');
        buffer.writeln(header);
        if (effect.isNotEmpty) buffer.writeln(effect);
        buffer.writeln();
      }
    }

    final out = buffer.toString().trim();
    return out.isEmpty ? null : out;
  }

  /// Maps a TCGdex/TCGplayer variant key onto a physical finish.
  static CardFinish? _finishForVariant(String key) {
    switch (key.toLowerCase()) {
      case 'normal':
        return CardFinish.nonfoil;
      case 'holofoil':
      case 'unlimitedholofoil':
        return CardFinish.holofoil;
      case 'reverseholofoil':
        return CardFinish.reverseHolofoil;
      case '1steditionnormal':
        return CardFinish.firstEdition;
      case '1steditionholofoil':
        return CardFinish.firstEditionHolofoil;
      default:
        return null;
    }
  }

  /// Retries transient failures with backoff.
  Future<Response<dynamic>> _retry(Future<Response<dynamic>> Function() call) async {
    var attempt = 0;
    while (true) {
      try {
        return await call();
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        final retryable = status == null || status == 429 || status >= 500;
        if (!retryable || attempt >= _maxRetries) rethrow;
        attempt++;
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
  }
}
