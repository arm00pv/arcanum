import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/scan/scan_resolver.dart';
import 'package:arcanum/data/scan/text_reader.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/scan/card_scan.dart';
import 'package:arcanum/features/card/add_to_collection_sheet.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/glass.dart';

/// Points the camera at a card and writes down what it is.
///
/// The reading is deliberately shown before anything is saved. A scanner that
/// adds silently is a scanner that quietly files a card under the wrong
/// printing, and a reprinted common is exactly where that goes unnoticed - so
/// the screen says what it read, offers the alternatives when there is more
/// than one, and lets the set and number be corrected by hand.
class ScanScreen extends ConsumerStatefulWidget {
  /// Creates the scanner for the active game.
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

/// Where the screen has got to.
enum _Stage { looking, reading, found }

class _ScanScreenState extends ConsumerState<ScanScreen>
    with WidgetsBindingObserver {
  final CardTextReader _reader = MlKitTextReader();
  final TextEditingController _setCode = TextEditingController();
  final TextEditingController _number = TextEditingController();

  CameraController? _controller;
  String? _cameraProblem;
  _Stage _stage = _Stage.looking;
  bool _torch = false;

  /// What the last photograph gave up, and what the catalogue made of it.
  CardScan? _scan;
  ScanResolution? _resolution;
  String? _photoPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _reader.close();
    _setCode.dispose();
    _number.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The camera is a shared resource: leaving it open behind a locked screen
    // holds it against every other app on the phone.
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      unawaited(controller.dispose());
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_startCamera());
    }
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() => _cameraProblem = 'This phone has no camera.');
        }
        return;
      }
      final back = cameras.firstWhere(
        (CameraDescription c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        // 1080p rather than the sensor's maximum: a collector number is two
        // millimetres of type, and this is the smallest setting that reads one
        // without a fifty-megapixel JPEG to decode on every tap.
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _cameraProblem = null;
      });
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _cameraProblem = error.code == 'CameraAccessDenied'
            ? 'Arcanum does not have permission to use the camera.'
            : 'The camera would not open (${error.code}).';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _cameraProblem = 'The camera would not open.');
      }
    }
  }

  /// Reads one picture: the reader first, then the catalogue.
  Future<void> _readPicture(String path) async {
    final game = ref.read(activeGameProvider);
    setState(() => _stage = _Stage.reading);
    try {
      final lines = await _reader.read(path);
      final scan = readCardText(
        lines,
        game: game,
        knownSetCodes: await _knownSetCodes(game),
      );
      final resolution = await _resolver.resolve(game, scan);
      if (!mounted) return;
      setState(() {
        _photoPath = path;
        _scan = scan;
        _resolution = resolution;
        _setCode.text = scan.setCode ?? '';
        _number.text = scan.collectorNumber ?? '';
        _stage = _Stage.found;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _stage = _Stage.looking);
      _say('Could not read that picture.');
    }
  }

  /// The resolver, built against the app's own catalogue.
  ScanResolver get _resolver => ScanResolver(
    catalogue: RepositoryScanCatalogue(ref.read(catalogRepositoryProvider)),
  );

  /// Every set code the catalogue holds, so a reading can be checked against it.
  Future<Set<String>> _knownSetCodes(CardGame game) async {
    try {
      final sets = await ref.read(setsProvider(game).future);
      return <String>{for (final TcgSet set in sets) set.code.toUpperCase()};
    } catch (_) {
      return const <String>{};
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      final shot = await controller.takePicture();
      final previous = _photoPath;
      await _readPicture(shot.path);
      // The camera writes every picture to the cache directory; keeping only
      // the one on screen stops a stack of scans becoming a stack of files.
      if (previous != null && previous != shot.path) {
        unawaited(File(previous).delete().catchError((Object _) => File('')));
      }
    } on CameraException catch (error) {
      _say('The camera did not take a picture (${error.code}).');
    }
  }

  Future<void> _pickPhoto() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Choose a photo of a card',
      type: FileType.image,
    );
    final path = picked?.path;
    if (path == null) return;
    await _readPicture(path);
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Looks the printing up again from what is in the two correction fields.
  Future<void> _lookUpByHand() async {
    final code = _setCode.text.trim().toUpperCase();
    final number = _number.text.trim();
    if (code.isEmpty || number.isEmpty) {
      _say('A set code and a number are both needed.');
      return;
    }
    setState(() => _stage = _Stage.reading);
    final game = ref.read(activeGameProvider);
    final resolution = await _resolver.resolve(
      game,
      CardScan(
        setCode: code,
        collectorNumber: number,
        name: _scan?.name,
        lines: _scan?.lines ?? const <String>[],
      ),
    );
    if (!mounted) return;
    setState(() {
      _resolution = resolution;
      _stage = _Stage.found;
    });
  }

  Future<void> _add(TcgCard card) async {
    final added = await showAddToCollectionSheet(context, ref, card);
    if (added && mounted) {
      _say('Added ${card.name}.');
      _scanAgain();
    }
  }

  void _scanAgain() {
    setState(() {
      _stage = _Stage.looking;
      _scan = null;
      _resolution = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = ref.watch(activeGameProvider);

    return Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.backdrop(c, tint: game.accent),
              ),
            ),
          ),
          if (_stage == _Stage.found)
            _Result(
              scan: _scan!,
              resolution: _resolution!,
              photoPath: _photoPath,
              setCode: _setCode,
              number: _number,
              onLookUp: _lookUpByHand,
              onAdd: _add,
              onAgain: _scanAgain,
            )
          else
            _Viewfinder(
              controller: _controller,
              problem: _cameraProblem,
              working: _stage == _Stage.reading,
              torch: _torch,
              onTorch: _controller == null
                  ? null
                  : () async {
                      final next = !_torch;
                      await _controller!.setFlashMode(
                        next ? FlashMode.torch : FlashMode.off,
                      );
                      if (mounted) setState(() => _torch = next);
                    },
              onCapture: _capture,
              onPickPhoto: _pickPhoto,
              onSettings: () => launchUrl(
                Uri.parse('app-settings:'),
                mode: LaunchMode.externalApplication,
              ),
            ),
        ],
      ),
    );
  }
}

/// The camera, a card-shaped hole to put the card in, and a shutter.
class _Viewfinder extends StatelessWidget {
  const _Viewfinder({
    required this.controller,
    required this.problem,
    required this.working,
    required this.torch,
    required this.onTorch,
    required this.onCapture,
    required this.onPickPhoto,
    required this.onSettings,
  });

  final CameraController? controller;
  final String? problem;
  final bool working;
  final bool torch;
  final VoidCallback? onTorch;
  final VoidCallback onCapture;
  final VoidCallback onPickPhoto;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final controller = this.controller;
    final ready = controller != null && controller.value.isInitialized;

    return SafeArea(
      child: Column(
        children: <Widget>[
          GlassAppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text('Scan a card', style: context.t.titleLarge),
                Text(
                  problem ?? 'Fill the frame with the card',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.t.bodySmall,
                ),
              ],
            ),
            actions: <Widget>[
              if (onTorch != null)
                IconButton(
                  tooltip: torch ? 'Turn the light off' : 'Light the card',
                  icon: Icon(
                    torch
                        ? Icons.flashlight_on_rounded
                        : Icons.flashlight_off_rounded,
                  ),
                  onPressed: onTorch,
                ),
            ],
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (ready)
                  _Preview(controller: controller)
                else
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        problem ?? 'Starting the camera...',
                        textAlign: TextAlign.center,
                        style: context.t.bodyMedium,
                      ),
                    ),
                  ),
                if (ready) const _CardGuide(),
                if (working)
                  const ColoredBox(
                    color: Color(0x88000000),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: working ? null : onPickPhoto,
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('From a photo'),
                  ),
                ),
                const SizedBox(width: 14),
                _Shutter(enabled: ready && !working, onPressed: onCapture),
                const SizedBox(width: 14),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: working ? null : onSettings,
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    label: const Text('Settings'),
                  ),
                ),
              ],
            ),
          ),
          if (ready)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
              child: Text(
                'The set code and collector number are printed at the bottom, '
                'and that is what Arcanum reads. Get the whole card in the '
                'frame and hold still.',
                textAlign: TextAlign.center,
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
            ),
        ],
      ),
    );
  }
}

/// The live camera picture.
class _Preview extends StatelessWidget {
  const _Preview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.previewSize;
    if (size == null || size.width == 0 || size.height == 0) {
      return const SizedBox.shrink();
    }
    return ClipRect(
      child: OverflowBox(
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            // The preview arrives landscape-shaped whichever way the phone is
            // held; swapping is what stops a portrait card looking squashed.
            width: size.height,
            height: size.width,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }
}

/// A hole the shape of a card, because framing is most of reading small print.
class _CardGuide extends StatelessWidget {
  const _CardGuide();

  /// A card is 63 by 88 millimetres, and every one of these games prints to it.
  static const double _cardAspect = 63 / 88;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final height = (constraints.maxHeight * 0.78).clamp(
          0.0,
          constraints.maxHeight,
        );
        final width = (height * _cardAspect).clamp(
          0.0,
          constraints.maxWidth * 0.9,
        );
        return Center(
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: c.accent.withValues(alpha: 0.9),
                width: 2,
              ),
            ),
            child: Align(
              alignment: const Alignment(0, 0.82),
              child: Container(
                height: 2,
                width: width * 0.8,
                color: c.accent.withValues(alpha: 0.55),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The button that takes the picture.
class _Shutter extends StatelessWidget {
  const _Shutter({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      label: 'Scan the card',
      child: InkWell(
        onTap: enabled ? onPressed : null,
        customBorder: const CircleBorder(),
        child: Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: c.hairlineStrong, width: 3),
            color: enabled ? c.accent : c.surfaceRaised,
          ),
          child: Icon(
            Icons.camera_alt_rounded,
            color: enabled ? c.canvas : c.textTertiary,
            size: 28,
          ),
        ),
      ),
    );
  }
}

/// What the scan found, and what can be done about it.
class _Result extends StatelessWidget {
  const _Result({
    required this.scan,
    required this.resolution,
    required this.photoPath,
    required this.setCode,
    required this.number,
    required this.onLookUp,
    required this.onAdd,
    required this.onAgain,
  });

  final CardScan scan;
  final ScanResolution resolution;
  final String? photoPath;
  final TextEditingController setCode;
  final TextEditingController number;
  final VoidCallback onLookUp;
  final Future<void> Function(TcgCard card) onAdd;
  final VoidCallback onAgain;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final best = resolution.best;

    return SafeArea(
      child: CustomScrollView(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: GlassAppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text('Scan a card', style: context.t.titleLarge),
                  Text(
                    best?.name ?? 'Nothing certain yet',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
            sliver: SliverList.list(
              children: <Widget>[
                if (best != null)
                  _Found(card: best, onAdd: () => onAdd(best))
                else
                  _NotFound(
                    scan: scan,
                    resolution: resolution,
                    photoPath: photoPath,
                  ),
                const SizedBox(height: 14),
                _Correction(
                  setCode: setCode,
                  number: number,
                  name: scan.name,
                  onLookUp: onLookUp,
                ),
                if (resolution.candidates.length > 1) ...<Widget>[
                  const SizedBox(height: 18),
                  Text('Or one of these', style: context.t.titleSmall),
                  const SizedBox(height: 8),
                  for (final TcgCard candidate in resolution.candidates)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _Candidate(
                        card: candidate,
                        onTap: () => onAdd(candidate),
                      ),
                    ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onAgain,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Scan another'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Everything Arcanum read:',
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
                const SizedBox(height: 4),
                Text(
                  scan.lines.isEmpty ? '(nothing)' : scan.lines.join('  ·  '),
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The printing the scan settled on.
class _Found extends StatelessWidget {
  const _Found({required this.card, required this.onAdd});

  final TcgCard card;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final price = card.prices.from;

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 64,
                child: CardThumbnail(
                  imageUrl: card.imageUrl(size: 'normal'),
                  aspectRatio: card.game.cardAspectRatio,
                  width: 64,
                  rarity: CardRarity.fromCode(card.rarity),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(card.name, style: context.t.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '${card.setCode.toUpperCase()} #${card.collectorNumber}'
                      '  ·  ${card.setName}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.t.bodySmall?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      price == null ? 'No price' : Fmt.money(price),
                      style: context.t.titleSmall?.copyWith(
                        color: price == null ? c.textTertiary : c.gold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add to collection'),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                tooltip: 'Open the card',
                icon: Icon(Icons.open_in_new_rounded, color: c.textSecondary),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        CardDetailScreen(game: card.game, cardId: card.id),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What is shown when the scan did not settle on a printing.
class _NotFound extends StatelessWidget {
  const _NotFound({
    required this.scan,
    required this.resolution,
    required this.photoPath,
  });

  final CardScan scan;
  final ScanResolution resolution;
  final String? photoPath;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final path = photoPath;

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.search_off_rounded, size: 18, color: c.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  resolution.note ?? 'That did not name a printing.',
                  style: context.t.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'The set code and number are the two things worth checking. They '
            'are at the bottom of the card, and they can be typed in below.',
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          if (path != null) ...<Widget>[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                File(path),
                height: 150,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One of the printings a name matched.
class _Candidate extends StatelessWidget {
  const _Candidate({required this.card, required this.onTap});

  final TcgCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 42,
              child: CardThumbnail(
                imageUrl: card.imageUrl(size: 'small'),
                aspectRatio: card.game.cardAspectRatio,
                width: 42,
                rarity: CardRarity.fromCode(card.rarity),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    card.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${card.setCode.toUpperCase()} #${card.collectorNumber}'
                    '  ·  ${card.setName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.add_circle_outline_rounded, color: c.accent),
          ],
        ),
      ),
    );
  }
}

/// The two fields that fix a misread card by hand.
class _Correction extends StatelessWidget {
  const _Correction({
    required this.setCode,
    required this.number,
    required this.name,
    required this.onLookUp,
  });

  final TextEditingController setCode;
  final TextEditingController number;
  final String? name;
  final VoidCallback onLookUp;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('What it read', style: context.t.titleSmall),
          const SizedBox(height: 4),
          Text(
            name == null ? 'No name came off the card.' : 'Name: $name',
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              SizedBox(
                width: 110,
                child: TextField(
                  controller: setCode,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Set',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: number,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Number',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                tooltip: 'Look it up',
                onPressed: onLookUp,
                icon: const Icon(Icons.search_rounded, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
