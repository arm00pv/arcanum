import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/backup/backup_archive.dart';
import 'package:arcanum/data/backup/backup_service.dart';
import 'package:arcanum/domain/sync/merge.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';

/// Two phones, one collection.
///
/// A backup is a copy; this is the other half of the idea. The server already
/// knows which device wrote each archive, so the app can see that a second phone
/// has added something and merge it in - and merging, unlike restoring, never
/// takes anything away, because a card on either device is a card you own.
///
/// Nothing here runs on its own. The screen looks when the collector asks it to,
/// shows what would change before anything does, and only writes when they press
/// the button.
class SyncScreen extends ConsumerStatefulWidget {
  /// Creates the sync screen.
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  BackupStatus? _status;
  MergePlan? _plan;
  BackupArchive? _archive;
  MergeReport? _report;
  String? _error;
  bool _looking = false;
  bool _applying = false;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _looking = true;
    });
    try {
      final info = await PackageInfo.fromPlatform();
      _version = '${info.version}+${info.buildNumber}';
      final BackupStatus status = await ref
          .read(backupServiceProvider)
          .status();
      if (!mounted) return;
      setState(() {
        _status = status;
        _looking = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _looking = false;
      });
    }
  }

  /// Downloads the newest archive and works out what it would add.
  Future<void> _look() async {
    setState(() {
      _looking = true;
      _error = null;
      _plan = null;
      _report = null;
    });
    try {
      final (MergePlan plan, BackupArchive archive) = await ref
          .read(backupServiceProvider)
          .planSync(appVersion: _version);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _archive = archive;
        _looking = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _looking = false;
      });
    }
  }

  /// Adds what the other device has, and nothing else.
  Future<void> _apply() async {
    final BackupArchive? archive = _archive;
    if (archive == null) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final MergeReport report = await ref
          .read(backupServiceProvider)
          .merge(archive);
      if (!mounted) return;
      setState(() {
        _report = report;
        _plan = null;
        _applying = false;
      });
      // The collection changed under every screen that was showing it.
      ref.invalidate(collectionOverviewProvider);
      ref.read(sealedRevisionProvider.notifier).bump();
      _snack(report.summary);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _applying = false;
      });
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final settings = ref.watch(settingsProvider);
    final BackupStatus? status = _status;

    return Scaffold(
      appBar: AppBar(
        title: Text('Other devices', style: context.t.headlineSmall),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: <Widget>[
          const SectionHeader(
            title: 'What your server holds',
            subtitle: 'One copy per device, and who wrote it',
          ),
          _group(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _row('This device', settings.deviceLabel),
                _row('Its last backup', Fmt.ago(settings.lastBackupAt)),
                if (status != null) ...<Widget>[
                  Divider(height: 20, color: c.hairline),
                  _row('Archives kept', Fmt.count(status.count)),
                  _row('Newest', Fmt.ago(status.latest)),
                  for (final BackupDevice device in status.devices)
                    _row(
                      device.label == settings.deviceLabel
                          ? '${device.label} (this device)'
                          : device.label,
                      '${Fmt.ago(device.latest)} · '
                      '${Fmt.count(device.backups)} kept',
                      quiet: device.label != settings.deviceLabel,
                    ),
                  if (status.devices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'The server does not list devices. Update the companion '
                        'to see which of your machines has written.',
                        style: context.t.labelSmall?.copyWith(
                          color: c.textTertiary,
                        ),
                      ),
                    ),
                ] else if (_looking)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(minHeight: 3),
                  ),
              ],
            ),
          ),
          if (_error != null) ...<Widget>[
            const SectionHeader(title: 'That did not work'),
            _group(
              child: Text(
                _error!,
                style: context.t.bodySmall?.copyWith(color: c.negative),
              ),
            ),
          ],
          if (_report != null) ...<Widget>[
            const SectionHeader(title: 'What the merge did'),
            _group(child: Text(_report!.summary, style: context.t.bodyMedium)),
          ],
          if (_plan != null) ...<Widget>[
            const SectionHeader(
              title: 'What it would add',
              subtitle: 'Read this before it happens',
            ),
            _planCard(_plan!),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_plan == null)
                  FilledButton.icon(
                    onPressed: _looking || _applying ? null : _look,
                    icon: _looking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync_rounded, size: 18),
                    label: Text(
                      _looking
                          ? 'Looking...'
                          : "Look for another device's copy",
                    ),
                  )
                else ...<Widget>[
                  FilledButton.icon(
                    onPressed: _plan!.nothingToDo || _applying ? null : _apply,
                    icon: _applying
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_rounded, size: 18),
                    label: Text(_applying ? 'Adding...' : 'Add what it has'),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: _applying
                        ? null
                        : () => setState(() {
                            _plan = null;
                            _archive = null;
                          }),
                    child: const Text('Leave it alone'),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Text(
              'A backup is a copy of one device. This is how two of them become '
              'one collection again: the server holds a copy from each, and the '
              'app adds what it does not already have.',
              style: context.t.labelSmall?.copyWith(color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _planCard(MergePlan plan) {
    final c = context.c;
    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                plan.nothingToDo
                    ? Icons.check_circle_outline_rounded
                    : Icons.playlist_add_rounded,
                size: 20,
                color: plan.nothingToDo ? c.positive : c.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(plan.headline, style: context.t.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'That copy was written by Arcanum ${plan.remoteAppVersion} '
            '${Fmt.ago(plan.remoteCreated)}.',
            style: context.t.labelSmall?.copyWith(color: c.textTertiary),
          ),
          if (plan.freshPricePoints > 0) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '+${Fmt.count(plan.freshPricePoints)} price points this phone '
              'never recorded.',
              style: context.t.labelSmall?.copyWith(color: c.textTertiary),
            ),
          ],
          if (plan.changes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            for (final MergeChange change in plan.changes.take(12))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: <Widget>[
                    Icon(
                      change.action == 'add'
                          ? Icons.add_rounded
                          : Icons.arrow_upward_rounded,
                      size: 14,
                      color: c.textTertiary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        change.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.bodySmall,
                      ),
                    ),
                    Text(
                      change.action == 'add'
                          ? '${change.to}'
                          : '${change.from} to ${change.to}',
                      style: context.t.labelSmall?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            if (plan.changes.length > 12)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'and more.',
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ),
          ],
          const SizedBox(height: 14),
          Divider(height: 1, color: c.hairline),
          const SizedBox(height: 12),
          for (final String note in plan.notes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 7, right: 8),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: c.textTertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      note,
                      style: context.t.bodySmall?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool quiet = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.t.bodySmall?.copyWith(
              color: quiet ? context.c.textTertiary : context.c.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(value, style: context.t.titleSmall),
      ],
    ),
  );

  Widget _group({required Widget child}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: GlassCard(
      radius: 20,
      padding: const EdgeInsets.all(16),
      child: child,
    ),
  );
}
