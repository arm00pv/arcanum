import 'package:flutter/material.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/data/auth/account_service.dart';
import 'package:arcanum/widgets/glass.dart';

/// The screen a browser shows before it will show a vault.
///
/// An account exists here for one reason: a vault that lives on somebody else's
/// screen has to know whose it is. So this asks for the least that does that -
/// an address and a secret - and says plainly what happens to both, because a
/// collector being asked to hand over an email deserves to know why.
///
/// It is only ever shown by [AccountGate], and only where there is an account
/// server to talk to. The phone app never sees it.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.service});

  final AccountService service;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();

  /// Whether the form is creating an account rather than opening one.
  bool _creating = false;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  /// Set when a confirmation link has gone out and has to be opened first.
  String? _sentTo;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_busy && _email.text.trim().isNotEmpty && _password.text.length >= 6;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_creating) {
        final bool ready = await widget.service.signUp(
          email: _email.text,
          password: _password.text,
        );
        if (!mounted) return;
        if (!ready) setState(() => _sentTo = _email.text.trim());
      } else {
        await widget.service.signIn(
          email: _email.text,
          password: _password.text,
        );
      }
      // A successful sign-in is not handled here: the gate is listening to the
      // session and replaces this screen itself.
    } on AccountError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.resendConfirmation(_sentTo ?? _email.text);
    } on AccountError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The screen is the app's sibling rather than its child - the gate sits
    // above [ArcanumApp], because the vault it guards is the whole app - so it
    // has to bring what a MaterialApp brings with it. Without this there is no
    // Directionality and no theme above the Scaffold, and a release build
    // answers that with the least helpful error it has: a null check failed.
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(dark: true),
      // The Builder is not decoration. The theme above is only in scope below
      // it, and this widget's own context sits above the app it is building -
      // so reading a text style off that context reads the default light theme
      // instead, and headings come out near-black on near-black.
      home: Builder(builder: _body),
    );
  }

  Widget _body(BuildContext context) {
    final c = context.c;
    final sentTo = _sentTo;

    return Scaffold(
      backgroundColor: c.canvas,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Icon(Icons.diamond_rounded, size: 40, color: c.accent),
                  const SizedBox(height: 14),
                  Text(
                    'Arcanum',
                    textAlign: TextAlign.center,
                    style: context.t.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Your vault, wherever you open it.',
                    textAlign: TextAlign.center,
                    style: context.t.bodySmall?.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  GlassCard(
                    padding: const EdgeInsets.all(18),
                    child: sentTo == null
                        ? _form(context, c)
                        : _confirmation(context, c, sentTo),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Your collection belongs to your account and to nobody '
                    'else. Arcanum keeps the address, a hash of the password, '
                    'and the cards you add - nothing more, and none of it is '
                    'readable by another collector.',
                    textAlign: TextAlign.center,
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(BuildContext context, ArcanumColors c) {
    final error = _error;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          _creating ? 'Create an account' : 'Sign in',
          style: context.t.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          _creating
              ? 'One address, one password, and the vault is yours on any '
                    'screen you open it on.'
              : 'The vault you keep here is tied to this account.',
          style: context.t.bodySmall?.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _email,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autofillHints: const <String>[AutofillHints.email],
          autocorrect: false,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _passwordFocus.requestFocus(),
          decoration: const InputDecoration(
            labelText: 'Email',
            hintText: 'you@example.com',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          focusNode: _passwordFocus,
          enabled: !_busy,
          obscureText: !_showPassword,
          textInputAction: TextInputAction.done,
          autofillHints: <String>[
            _creating ? AutofillHints.newPassword : AutofillHints.password,
          ],
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Password',
            helperText: _creating ? 'Six characters or more.' : null,
            suffixIcon: IconButton(
              tooltip: _showPassword ? 'Hide password' : 'Show password',
              icon: Icon(
                _showPassword
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 18,
                color: c.textTertiary,
              ),
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ),
        ),
        if (error != null) ...<Widget>[
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.error_outline_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  error,
                  style: context.t.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_creating ? 'Create account' : 'Sign in'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _creating = !_creating;
                  _error = null;
                }),
          child: Text(
            _creating
                ? 'I already have an account'
                : 'I need an account instead',
          ),
        ),
      ],
    );
  }

  Widget _confirmation(BuildContext context, ArcanumColors c, String sentTo) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Nearly there', style: context.t.titleMedium),
          const SizedBox(height: 6),
          Text(
            'A confirmation link is on its way to $sentTo. Open it and this '
            'screen finishes the job.',
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _resend,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Send it again'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _sentTo = null;
                    _error = null;
                  }),
            child: const Text('Use a different address'),
          ),
        ],
      );
}
