import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/identity/identity_service.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';

/// The collector's account, which is an email address and nothing else.
///
/// Arcanum has no password to set, forget or reuse, because the companion
/// serves one collection and the only question worth asking is whether this is
/// the person who owns it. The answer is a code mailed to an address the server
/// already holds; the code buys this phone a token of its own, and from then on
/// the phone is a device the collector can see in a list and revoke.
///
/// Everything here is also the way back in when a phone is lost - which is the
/// part a backup alone cannot do, because the token that opens the backup is
/// the thing that was lost with it.
class AccountScreen extends ConsumerStatefulWidget {
  /// Creates the account screen.
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _code = TextEditingController();

  DeviceList? _list;
  CodeSent? _sent;
  String? _error;
  String? _note;
  String _busyWith = '';
  bool _looking = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  IdentityService get _service => ref.read(identityServiceProvider);

  Future<void> _load() async {
    setState(() {
      _looking = true;
      _error = null;
    });
    try {
      final DeviceList list = await _service.look();
      if (!mounted) return;
      setState(() {
        _list = list;
        _looking = false;
        if (_email.text.trim().isEmpty) _email.text = list.owner;
      });
    } on CompanionException catch (error) {
      if (!mounted) return;
      setState(() {
        _list = null;
        _looking = false;
        _error = error.message;
      });
    }
  }

  /// Asks for a code, and keeps whatever the companion said about it.
  Future<void> _askForCode() async {
    setState(() {
      _busyWith = 'ask';
      _error = null;
      _note = null;
    });
    try {
      final CodeSent sent = await _service.startCode(_email.text);
      if (!mounted) return;
      setState(() {
        _sent = sent;
        _busyWith = '';
        if (!sent.sent && sent.error != null) _error = sent.error;
      });
    } on CompanionException catch (error) {
      if (!mounted) return;
      setState(() {
        _busyWith = '';
        _error = error.message;
      });
    }
  }

  /// Trades the code for this phone's token, and starts using it.
  Future<void> _connect() async {
    setState(() {
      _busyWith = 'connect';
      _error = null;
      _note = null;
    });
    final settings = ref.read(settingsProvider);
    try {
      final String token = await _service.verify(
        email: _email.text,
        code: _code.text,
        device: settings.deviceLabel,
      );
      if (!mounted) return;
      // The device token replaces whatever was there: it is the same kind of
      // credential - minted for this phone rather than copied out of the
      // server's token file - and it is kept in the same place, the Keystore.
      settings.backupToken = token;
      _code.clear();
      setState(() {
        _busyWith = '';
        _sent = null;
        _note =
            'This phone is connected. It holds a token of its own, and it can '
            'be revoked from the list below.';
      });
      await _load();
    } on CompanionException catch (error) {
      if (!mounted) return;
      setState(() {
        _busyWith = '';
        _error = error.message;
      });
    }
  }

  Future<void> _revoke(SignedInDevice device) async {
    setState(() {
      _busyWith = 'revoke:${device.label}';
      _error = null;
      _note = null;
    });
    try {
      final bool removed = await _service.revoke(device.label);
      if (!mounted) return;
      setState(() {
        _busyWith = '';
        _note = removed
            ? '${device.label} can no longer write to your server.'
            : '${device.label} was already gone.';
      });
      await _load();
    } on CompanionException catch (error) {
      if (!mounted) return;
      setState(() {
        _busyWith = '';
        _error = error.message;
      });
    }
  }

  /// Forgets the token on this phone.
  ///
  /// The server is not told: revoking would need the very credential being
  /// thrown away. A token nobody holds is a token nobody can use - and if this
  /// phone was the only thing holding one, the root token in the server's own
  /// token file is still there to sign in with.
  void _signOut() {
    setState(() {
      _note =
          'The token was removed from this phone. Backups and price history '
          'stop working until it has one again.';
      _error = null;
    });
    ref.read(settingsProvider).backupToken = '';
    _load();
  }

  Future<void> _mail(String what) async {
    setState(() {
      _busyWith = what;
      _error = null;
      _note = null;
    });
    try {
      final IdentityService service = _service;
      if (what == 'vault') {
        await service.emailVaultLink();
      } else {
        await service.emailBackup();
      }
      if (!mounted) return;
      setState(() {
        _busyWith = '';
        _note = what == 'vault'
            ? 'A link is on its way. It opens the vault page and lasts a week.'
            : 'The newest backup is on its way, attached.';
      });
    } on CompanionException catch (error) {
      if (!mounted) return;
      setState(() {
        _busyWith = '';
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final settings = ref.watch(settingsProvider);
    final DeviceList? list = _list;
    final bool hasToken = settings.backupToken.trim().isNotEmpty;
    final bool connected = list != null;

    /// Whether the token on this phone is one of the server's devices.
    ///
    /// Not the same question as whether the companion answered: the token typed
    /// into Settings by hand is the server wide one, and it works without ever
    /// appearing in the device list. Signing in is what gives this phone a
    /// credential of its own - which is the only kind that can be revoked.
    final bool mine =
        list != null && list.devices.any((SignedInDevice d) => d.current);
    final CodeSent? sent = _sent;

    return Scaffold(
      appBar: AppBar(
        title: Text('Account', style: context.t.headlineSmall),
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
            title: 'Your account',
            subtitle: 'An address, not a password',
          ),
          _group(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Arcanum has no sign-up and no password. Your companion '
                  'serves one collection, so the only question it asks is '
                  'whether this is the person who owns it - and it asks by '
                  'mailing a code to the address it already knows. Losing a '
                  'phone then costs a code, not a collection.',
                  style: context.t.bodySmall?.copyWith(
                    color: c.textSecondary,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),
                _row(
                  'Your server',
                  settings.backupEndpoint.isEmpty
                      ? 'not set'
                      : settings.backupEndpoint,
                ),
                _row(
                  'Owner',
                  list == null
                      ? (connected ? '-' : 'unknown')
                      : (list.hasOwner ? list.owner : 'not set on the server'),
                ),
                _row('This phone', settings.deviceLabel),
                _row(
                  'Token',
                  !hasToken
                      ? 'none on this phone'
                      : (list == null
                            ? 'not accepted'
                            : (mine
                                  ? "this phone's own"
                                  : 'the server wide one')),
                  quiet: !hasToken,
                ),
                if (list != null && !list.emailEnabled)
                  _aside(
                    'Email is switched off on the companion: it has no Resend '
                    'key, so no code can be sent until one is installed.',
                    c.negative,
                  ),
                if (list != null && !list.hasOwner)
                  _aside(
                    'The companion has no owner yet. On the server, run: '
                    'sync_server.py --set-owner you@example.com',
                    c.textTertiary,
                  ),
              ],
            ),
          ),
          if (_error != null) _message(_error!, negative: true),
          if (_note != null) _message(_note!, negative: false),
          if (!mine) ...<Widget>[
            const SectionHeader(
              title: 'Sign in',
              subtitle: 'A code by email, good for ten minutes',
            ),
            _group(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (hasToken && connected)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Text(
                        'This phone is using the server wide token, typed in by '
                        'hand. A code gives it one of its own instead - the same '
                        'access, but listed below and revocable.',
                        style: context.t.bodySmall?.copyWith(
                          color: c.textSecondary,
                          height: 1.45,
                        ),
                      ),
                    ),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Your email address',
                      hintText: 'you@example.com',
                      helperText: 'the address that owns the server',
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (_busyWith != '' || !_service.isConfigured)
                          ? null
                          : _askForCode,
                      icon: _busyWith == 'ask'
                          ? const _Spinner()
                          : const Icon(Icons.mail_outline_rounded, size: 18),
                      label: const Text('Email me a code'),
                    ),
                  ),
                  if (sent != null) ...<Widget>[
                    const SizedBox(height: 18),
                    if (sent.sent)
                      Text(
                        'A code is on its way. It works for ten minutes, and '
                        'once.',
                        style: context.t.labelSmall?.copyWith(
                          color: c.textTertiary,
                        ),
                      )
                    else if (sent.retryIn > 0)
                      Text(
                        'A code was sent a moment ago. Try again in '
                        '${sent.retryIn} seconds.',
                        style: context.t.labelSmall?.copyWith(
                          color: c.textTertiary,
                        ),
                      )
                    else if (sent.invited.isNotEmpty)
                      Text(
                        'This server only sends codes to '
                        '${sent.invited.join(", ")}.',
                        style: context.t.labelSmall?.copyWith(
                          color: c.textTertiary,
                        ),
                      ),
                    if (sent.sent) ...<Widget>[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _code,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: const InputDecoration(
                          labelText: 'The six digits',
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _busyWith != '' ? null : _connect,
                          icon: _busyWith == 'connect'
                              ? const _Spinner()
                              : const Icon(Icons.login_rounded, size: 18),
                          label: const Text('Connect this phone'),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
          if (list != null && list.devices.isNotEmpty) ...<Widget>[
            const SectionHeader(
              title: 'Devices',
              subtitle: 'Every phone and link your server trusts',
            ),
            _group(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final SignedInDevice device in list.devices)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            device.current
                                ? Icons.smartphone_rounded
                                : Icons.devices_other_rounded,
                            size: 18,
                            color: device.current ? c.accent : c.textTertiary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  device.current
                                      ? '${device.label} (this phone)'
                                      : device.label,
                                  style: context.t.titleSmall,
                                ),
                                Text(
                                  _deviceCaption(device),
                                  style: context.t.labelSmall?.copyWith(
                                    color: c.textTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!device.current)
                            IconButton(
                              tooltip: 'Revoke',
                              icon: _busyWith == 'revoke:${device.label}'
                                  ? const _Spinner()
                                  : Icon(
                                      Icons.link_off_rounded,
                                      size: 18,
                                      color: c.negative,
                                    ),
                              onPressed: _busyWith != ''
                                  ? null
                                  : () => _revoke(device),
                            ),
                        ],
                      ),
                    ),
                  if (hasToken) ...<Widget>[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _busyWith != '' ? null : _signOut,
                        icon: Icon(
                          Icons.logout_rounded,
                          size: 18,
                          color: c.negative,
                        ),
                        label: const Text('Sign this phone out'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (list != null) ...<Widget>[
            const SectionHeader(
              title: 'By email',
              subtitle: 'The vault, and the archive itself',
            ),
            _group(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'A link that opens your collection in a browser is a '
                    'credential, so it is a device: it appears above, and '
                    'revoking it is what turns a leaked link off. The archive '
                    'is the same file the app uploads, attached.',
                    style: context.t.bodySmall?.copyWith(
                      color: c.textSecondary,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              (_busyWith != '' ||
                                  !list.emailEnabled ||
                                  !hasToken)
                              ? null
                              : () => _mail('vault'),
                          icon: _busyWith == 'vault'
                              ? const _Spinner()
                              : const Icon(
                                  Icons.open_in_browser_rounded,
                                  size: 18,
                                ),
                          label: const Text('Vault link'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              (_busyWith != '' ||
                                  !list.emailEnabled ||
                                  !hasToken)
                              ? null
                              : () => _mail('backup'),
                          icon: _busyWith == 'backup'
                              ? const _Spinner()
                              : const Icon(Icons.attach_file_rounded, size: 18),
                          label: const Text('A backup'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Until a sending domain is verified with Resend, the '
                    'companion can only mail its own address. Everything else '
                    'about signing in works the same way, and the refusal '
                    'says so in as many words.',
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_looking)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: LinearProgressIndicator(minHeight: 3),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              mine
                  ? 'This phone holds a token of its own now, listed above: '
                        'revoking it from another phone is what signs this one '
                        'out. The server wide token in Settings, Backup stays '
                        'as the way back in, and it cannot be revoked - that is '
                        'what stops a server being locked out of itself.'
                  : 'The token in Settings, Backup is the server wide one, '
                        'typed in by hand, and it cannot be revoked from here - '
                        'that is what stops a server being locked out of '
                        'itself. Signing in replaces it on this phone with a '
                        'token of this phone\u2019s own.',
              style: context.t.labelSmall?.copyWith(color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  String _deviceCaption(SignedInDevice device) {
    final List<String> parts = <String>[
      if (device.created != null) 'added ${Fmt.ago(device.created)}',
      if (device.lastSeen != null) 'last used ${Fmt.ago(device.lastSeen)}',
      if (device.expires != null)
        device.hasExpired(DateTime.now())
            ? 'expired'
            : 'expires ${Fmt.away(device.expires)}',
    ];
    return parts.isEmpty ? 'no date recorded' : parts.join(' \u00b7 ');
  }

  Widget _message(String text, {required bool negative}) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
    child: GlassCard(
      radius: 16,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            negative
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
            size: 18,
            color: negative ? context.c.negative : context.c.positive,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: context.t.bodySmall?.copyWith(
                color: negative ? context.c.negative : context.c.positive,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _aside(String text, Color colour) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(
      text,
      style: context.t.labelSmall?.copyWith(color: colour, height: 1.4),
    ),
  );

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
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: context.t.titleSmall?.copyWith(
              color: quiet ? context.c.textTertiary : null,
            ),
          ),
        ),
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

/// The small spinner a button wears while it is working.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 16,
    height: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
