import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:arcanum/core/legal.dart';
import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';

/// The Settings screen.
///
/// Everything here is stored in [AppSettings] (SharedPreferences), so it
/// survives a restart without a server round-trip. The screen is a plain
/// [ConsumerStatefulWidget] because settings are a [ChangeNotifier] rather than
/// a provider value: every mutation is followed by a local setState so the
/// controls reflect the new state immediately.
///
/// The collection, history and data sections are all scoped to the active game:
/// each game keeps its own endpoint, its own history providers, its own
/// snapshot timestamp and its own collection, and clearing one never touches
/// the other.
class SettingsScreen extends ConsumerStatefulWidget {
  /// Creates the settings screen.
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// The release shown in the About block.
  static const String _version = '1.0.0';

  /// Where the data that powers Arcanum is documented.
  static const String _scryfallApiUrl = 'https://scryfall.com/docs/api';

  static const List<String> _themeLabels = <String>['System', 'Light', 'Dark'];

  static const List<ThemeMode> _themeModes = <ThemeMode>[
    ThemeMode.system,
    ThemeMode.light,
    ThemeMode.dark,
  ];

  /// Magic's own companion endpoint.
  late final TextEditingController _endpointController;

  /// Pokémon's own, usually empty, companion endpoint.
  late final TextEditingController _pokemonEndpointController;

  late final TextEditingController _keyController;

  /// The mode the pill shows.
  ///
  /// [AppSettings] stores the mode by name, but its getter only maps 'light'
  /// and 'dark' - anything else, 'system' included, reads back as dark. This
  /// mirror keeps the control showing what the user actually picked while the
  /// value itself is still written through to the settings object.
  ThemeMode _themeMode = ThemeMode.dark;

  bool _obscureKey = true;
  bool _testing = false;
  bool _backfilling = false;
  int _backfillDone = 0;
  int _backfillTotal = 0;

  @override
  void initState() {
    super.initState();
    final AppSettings settings = ref.read(settingsProvider);
    _themeMode = settings.themeMode;
    _endpointController = TextEditingController(text: settings.historyEndpoint);
    _pokemonEndpointController =
        TextEditingController(text: settings.pokemonHistoryEndpoint);
    _keyController = TextEditingController(text: settings.justTcgKey);
  }

  @override
  void dispose() {
    _endpointController.dispose();
    _pokemonEndpointController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = ref.watch(settingsProvider);
    final CardGame game = ref.watch(activeGameProvider);

    return Scaffold(
      appBar: GlassAppBar(
        title: Text('Settings', style: context.t.headlineSmall),
        leading: Navigator.of(context).canPop()
            ? IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: <Widget>[
          const SectionHeader(
            title: 'Appearance',
            subtitle: 'How Arcanum looks',
          ),
          _appearance(context),
          SectionHeader(
            title: 'Price history',
            subtitle: 'Where ${game.shortLabel} trends come from',
          ),
          _priceHistory(context, settings, game),
          SectionHeader(
            title: 'Collection',
            subtitle: 'How your ${game.shortLabel} cards are tracked',
          ),
          _gameHeader(context, game),
          const SizedBox(height: 12),
          _collection(context, settings, game),
          SectionHeader(
            title: 'Data',
            subtitle: 'On this device only - ${game.shortLabel} figures',
          ),
          _data(context, settings, game),
          const SectionHeader(title: 'About'),
          _about(context, game),
        ],
      ),
    );
  }

  /// A grouped glass block: 20px radius, 16px padding, 20px page gutters.
  Widget _group({required Widget child, EdgeInsetsGeometry? padding}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GlassCard(
        radius: 20,
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  // -------------------------------------------------------------- appearance

  Widget _appearance(BuildContext context) {
    final c = context.c;
    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Theme', style: context.t.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Arcanum is dark by design - card art carries the colour and the '
            'chrome stays out of the way. System follows your device setting.',
            style: context.t.bodySmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 14),
          PillToggle(
            options: _themeLabels,
            selected: _themeIndex,
            semanticLabel: 'Theme mode',
            onChanged: _setThemeMode,
          ),
        ],
      ),
    );
  }

  int get _themeIndex {
    final int index = _themeModes.indexOf(_themeMode);
    return index < 0 ? _themeModes.length - 1 : index;
  }

  void _setThemeMode(int index) {
    final int safe = index.clamp(0, _themeModes.length - 1).toInt();
    final ThemeMode mode = _themeModes[safe];
    setState(() => _themeMode = mode);
    ref.read(settingsProvider).themeMode = mode;
  }

  // ------------------------------------------------------------ game header

  /// Names the game every collection figure below belongs to.
  Widget _gameHeader(BuildContext context, CardGame game) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GlassCard(
        radius: 20,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: game.gradient,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    game.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${game.dataSource} · cards since ${game.catalogueSince}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: game.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                game.abbreviation,
                style: context.t.labelSmall?.copyWith(color: game.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ price history

  Widget _priceHistory(
    BuildContext context,
    AppSettings settings,
    CardGame game,
  ) {
    final c = context.c;
    final bool isMtg = game == CardGame.mtg;
    final bool configured = settings.hasHistoryProvider(game);
    // A Pokémon companion is genuinely optional, so the probe only appears
    // once an endpoint has actually been typed in.
    final bool canTest =
        isMtg || _pokemonEndpointController.text.trim().isNotEmpty;

    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (isMtg) ...<Widget>[
            Text(
              'Scryfall publishes only current Magic prices, so it cannot answer '
              'what a card was worth last month. Arcanum fills that gap from '
              'three places: a daily snapshot it records itself for every card '
              'you own, an optional Arcanum Sync companion you host yourself, '
              'and MTGStocks (free, no API key) for longer daily series.',
              style: context.t.bodySmall
                  ?.copyWith(color: c.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 18),
            Text('Arcanum Sync endpoint', style: context.t.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _endpointController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (String value) {
                ref.read(settingsProvider).historyEndpoint = value;
                setState(() {});
              },
              decoration: const InputDecoration(
                hintText: 'http://host:port',
                helperText: 'e.g. http://100.90.30.95:8787',
              ),
            ),
          ] else ...<Widget>[
            Text('Pokémon price history', style: context.t.titleSmall),
            const SizedBox(height: 8),
            Text(
              'TCGdex supplies live current prices for Pokémon cards but keeps no '
              'history of them, so it cannot answer what a card was worth last '
              'month. The free TCGdex price archive on GitHub carries roughly two '
              'years of daily prices, but it stopped updating in September 2024, '
              'so it is a historical archive rather than a live feed. Live '
              'Pokémon history therefore needs a JustTCG API key - the free tier '
              'allows 100 requests a day. On top of that, Arcanum records its own '
              'daily snapshot of everything you own, which is the one series that '
              'always stays current.',
              style: context.t.bodySmall
                  ?.copyWith(color: c.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 18),
            Text('Self-hosted history endpoint', style: context.t.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _pokemonEndpointController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (String value) {
                ref.read(settingsProvider).pokemonHistoryEndpoint = value;
                setState(() {});
              },
              decoration: const InputDecoration(
                hintText: 'https://host:port',
                helperText: 'optional — leave blank unless you host one',
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (canTest)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _testing ? null : () => _testConnection(game),
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_rounded, size: 16),
                label: Text(_testing ? 'Testing...' : 'Test connection'),
              ),
            ),
          const SizedBox(height: 20),
          Text('JustTCG API key', style: context.t.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _keyController,
            obscureText: _obscureKey,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (String value) {
              ref.read(settingsProvider).justTcgKey = value;
              setState(() {});
            },
            decoration: InputDecoration(
              hintText: 'Optional',
              helperText: isMtg
                  ? 'The free tier is rate limited, so long backfills take a '
                      'while. Leave empty to rely on snapshots only.'
                  : 'The free tier allows 100 requests a day and is the only '
                      'source of live Pokémon history. Leave empty to rely on '
                      'snapshots and the 2024 TCGdex archive.',
              suffixIcon: IconButton(
                tooltip: _obscureKey ? 'Show key' : 'Hide key',
                icon: Icon(
                  _obscureKey
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: 18,
                  color: c.textSecondary,
                ),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Icon(
                configured
                    ? Icons.check_circle_rounded
                    : Icons.remove_circle_outline_rounded,
                size: 16,
                color: configured ? c.positive : c.textTertiary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  configured
                      ? 'History provider configured for ${game.shortLabel}'
                      : 'No history provider configured - trends fall back to '
                          'the snapshots Arcanum records itself.',
                  style: context.t.bodySmall?.copyWith(
                    color: configured ? c.positive : c.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Probes /v1/health on the endpoint configured for [game] and reports what
  /// it said.
  Future<void> _testConnection(CardGame game) async {
    final TextEditingController controller =
        game == CardGame.mtg ? _endpointController : _pokemonEndpointController;
    final String raw = controller.text.trim();
    if (raw.isEmpty) {
      _snack('Enter an endpoint URL first.', error: true);
      return;
    }
    final String endpoint =
        raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;

    setState(() => _testing = true);

    final Dio dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );

    try {
      final Response<dynamic> response =
          await dio.get<dynamic>('$endpoint/v1/health');
      if (!mounted) return;
      _snack(_healthSummary(response.data, response.statusCode));
    } on DioException catch (error) {
      if (!mounted) return;
      _snack('Connection failed: ${error.message ?? error.type.name}', error: true);
    } catch (error) {
      if (!mounted) return;
      _snack('Connection failed: $error', error: true);
    } finally {
      dio.close(force: true);
      if (mounted) setState(() => _testing = false);
    }
  }

  /// Turns a /v1/health payload into one readable line.
  String _healthSummary(Object? data, int? statusCode) {
    final int code = statusCode ?? 200;
    if (data is Map) {
      final String printings = _healthValue(data['printings']);
      final String points = _healthValue(data['points']);
      final String days = _healthValue(data['days']);
      final List<String> parts = <String>[
        if (printings.isNotEmpty) '$printings printings',
        if (points.isNotEmpty) '$points price points',
        if (days.isNotEmpty) '$days days of history',
      ];
      if (parts.isEmpty) {
        return 'Connected (HTTP $code) - no counters reported.';
      }
      return 'Connected - ${parts.join(' · ')}';
    }
    return 'Connected (HTTP $code).';
  }

  String _healthValue(Object? value) {
    if (value == null) return '';
    if (value is int) return Fmt.count(value);
    if (value is num) return Fmt.count(value.round());
    final int? parsed = int.tryParse(value.toString().trim());
    return parsed == null ? value.toString() : Fmt.count(parsed);
  }

  // -------------------------------------------------------------- collection

  Widget _collection(
    BuildContext context,
    AppSettings settings,
    CardGame game,
  ) {
    final c = context.c;
    return _group(
      padding: EdgeInsets.zero,
      child: Column(
        children: <Widget>[
          SwitchListTile(
            value: settings.autoSnapshot,
            onChanged: (bool value) {
              setState(() => settings.autoSnapshot = value);
            },
            contentPadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
            title: Text(
              'Record a daily price snapshot',
              style: context.t.titleSmall,
            ),
            subtitle: Text(
              "Writes today's ${game.dataSource} price for every ${game.shortLabel} "
              'card you own, once a day. This is what builds a trend with no '
              'external service at all.',
              style: context.t.bodySmall?.copyWith(color: c.textTertiary),
            ),
            isThreeLine: true,
          ),
          Divider(height: 1, color: c.hairline),
          SwitchListTile(
            value: settings.conditionAdjust,
            onChanged: (bool value) {
              setState(() => settings.conditionAdjust = value);
            },
            contentPadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
            title: Text(
              'Apply condition discounts to valuations',
              style: context.t.titleSmall,
            ),
            subtitle: Text(
              'Values lower-grade copies below the Near Mint reference price '
              'using the grading multipliers ${game.shortLabel} collectors use.',
              style: context.t.bodySmall?.copyWith(color: c.textTertiary),
            ),
            isThreeLine: true,
          ),
          Divider(height: 1, color: c.hairline),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _backfilling ? null : () => _backfill(game),
                  icon: const Icon(Icons.history_rounded, size: 18),
                  label: const Text('Backfill price history now'),
                ),
                if (_backfilling) ...<Widget>[
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: _backfillTotal > 0
                          ? (_backfillDone / _backfillTotal)
                              .clamp(0.0, 1.0)
                              .toDouble()
                          : null,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _backfillTotal > 0
                        ? 'Fetched $_backfillDone of $_backfillTotal cards...'
                        : 'Contacting the history provider...',
                    style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Pulls real price history for the active game's collection from whatever
  /// providers that game has configured.
  Future<void> _backfill(CardGame game) async {
    setState(() {
      _backfilling = true;
      _backfillDone = 0;
      _backfillTotal = 0;
    });

    try {
      final int improved = await ref
          .read(bootstrapProvider)
          .collectionFor(game)
          .backfillCollection(
        onProgress: (int done, int total) {
          if (!mounted) return;
          setState(() {
            _backfillDone = done;
            _backfillTotal = total;
          });
        },
      );
      if (!mounted) return;
      ref.invalidate(collectionOverviewProvider(game));
      _snack(
        improved == 0
            ? 'No new price points were available.'
            : 'Recorded $improved new price points for ${game.shortLabel}.',
      );
    } catch (error) {
      if (!mounted) return;
      _snack('Backfill failed: $error', error: true);
    } finally {
      if (mounted) setState(() => _backfilling = false);
    }
  }

  // -------------------------------------------------------------------- data

  Widget _data(BuildContext context, AppSettings settings, CardGame game) {
    final c = context.c;
    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _StatRow(
            icon: Icons.grid_view_rounded,
            label: 'Sets cached',
            value: _asyncText<int>(
              ref.watch(setCountProvider(game)),
              (int count) => Fmt.count(count),
            ),
          ),
          const SizedBox(height: 12),
          _StatRow(
            icon: Icons.style_rounded,
            label: 'Cards owned',
            value: _asyncText(
              ref.watch(collectionOverviewProvider(game)),
              (overview) => Fmt.count(overview.totalCards),
            ),
          ),
          const SizedBox(height: 12),
          _StatRow(
            icon: Icons.schedule_rounded,
            label: 'Last snapshot',
            value: Text(
              Fmt.ago(settings.lastSnapshotFor(game)),
              maxLines: 1,
              style: context.t.titleSmall,
            ),
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: c.hairline),
          const SizedBox(height: 16),
          Text(
            'Clearing deletes every card in your ${game.shortLabel} collection, '
            'along with its purchase prices and binders. The cached set catalogue '
            'and the recorded price history are kept, and your other games are '
            'left untouched.',
            style: context.t.bodySmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _confirmClear(game),
            style: OutlinedButton.styleFrom(
              foregroundColor: c.negative,
              side: BorderSide(color: c.negative.withValues(alpha: 0.45)),
            ),
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('Clear collection'),
          ),
        ],
      ),
    );
  }

  /// Renders a value that may still be loading, or may have failed.
  Widget _asyncText<T>(AsyncValue<T> value, String Function(T data) format) {
    final c = context.c;
    return value.when(
      data: (T data) => Text(
        format(data),
        maxLines: 1,
        style: context.t.titleSmall,
      ),
      loading: () => const LoadingShimmer(
        width: 56,
        height: 16,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      error: (Object error, StackTrace stackTrace) => Text(
        'unavailable',
        maxLines: 1,
        style: context.t.titleSmall?.copyWith(color: c.negative),
      ),
    );
  }

  /// Clears one game's collection, and says so before doing it.
  Future<void> _confirmClear(CardGame game) async {
    final ArcanumColors c = context.c;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Clear ${game.shortLabel} collection?'),
        content: Text(
          'This removes every card in your ${game.shortLabel} collection. Other '
          'games are not affected. Purchase prices, binders and this game\'s '
          'daily snapshots go with it; cached sets and recorded price history '
          'stay. This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: c.negative,
              minimumSize: const Size(0, 44),
            ),
            child: Text('Delete ${game.shortLabel} cards'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref.read(bootstrapProvider).collectionDao.clear(game: game);
      ref.invalidate(collectionOverviewProvider(game));
      ref.invalidate(ownedQuantityProvider(game));
      ref.invalidate(ownedBySetProvider(game));
      ref.invalidate(gameSummariesProvider);
      if (!mounted) return;
      _snack('${game.shortLabel} collection cleared.');
    } catch (error) {
      if (!mounted) return;
      _snack('Could not clear the collection: $error', error: true);
    }
  }

  // ------------------------------------------------------------------- about

  Widget _about(BuildContext context, CardGame game) {
    final c = context.c;
    final bool isMtg = game == CardGame.mtg;
    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.diamond_rounded, size: 20, color: c.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Arcanum', style: context.t.titleMedium),
                    Text(
                      'Version $_version',
                      style: context.t.bodySmall?.copyWith(color: c.textTertiary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Both notices are shown at all times, not just for the active game:
          // the app ships both catalogues, so both licences apply to it.
          Text(
            Legal.wizardsFanContent,
            style: context.t.bodySmall
                ?.copyWith(color: c.textTertiary, height: 1.4),
          ),
          const SizedBox(height: 10),
          Text(
            Legal.pokemonNotice,
            style: context.t.bodySmall
                ?.copyWith(color: c.textTertiary, height: 1.4),
          ),
          const SizedBox(height: 14),
          Text(
            Legal.nonCommercial,
            style: context.t.bodySmall
                ?.copyWith(color: c.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 14),
          Text(
            'YOUR DATA',
            style: context.t.labelSmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 6),
          Text(
            Legal.privacySummary,
            style: context.t.bodySmall
                ?.copyWith(color: c.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 14),
          Text(
            'DATA SOURCES',
            style: context.t.labelSmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 6),
          for (final source in Legal.dataSources)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: RichText(
                text: TextSpan(
                  style: context.t.bodySmall?.copyWith(color: c.textSecondary),
                  children: [
                    TextSpan(
                      text: source.name,
                      style: context.t.bodySmall?.copyWith(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(text: ' — ${source.purpose}'),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _openScryfallApi,
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Scryfall API documentation'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openScryfallApi() async {
    final Uri uri = Uri.parse(_scryfallApiUrl);
    try {
      final bool launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) {
        _snack('Could not open $_scryfallApiUrl', error: true);
      }
    } catch (error) {
      if (mounted) _snack('Could not open the link: $error', error: true);
    }
  }

  // ------------------------------------------------------------------ shared

  /// Shows a transient result message.
  void _snack(String message, {bool error = false}) {
    final ArcanumColors c = context.c;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Row(
          children: <Widget>[
            Icon(
              error
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              size: 18,
              color: error ? c.negative : c.positive,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

/// A label/value line used by the Data section.
class _StatRow extends StatelessWidget {
  const _StatRow({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      children: <Widget>[
        Icon(icon, size: 16, color: c.textTertiary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.t.bodyMedium?.copyWith(color: c.textSecondary),
          ),
        ),
        const SizedBox(width: 10),
        value,
      ],
    );
  }
}
