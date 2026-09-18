/// Where the Arcanum service lives, and the key a browser is allowed to hold.
///
/// The publishable key is public by design. It ships inside the web bundle and
/// anyone can read it out of the page, so it is not a secret and is not treated
/// as one. What makes that safe is that every table in the service has row level
/// security switched on: the key on its own reaches nothing, and a signed-in
/// request reaches only the rows belonging to that account. The secret key,
/// which bypasses all of that, lives on the server and never enters a browser.
///
/// Both are supplied at build time so a second deployment is a build flag rather
/// than a code change:
///
///   flutter build web --dart-define=ARCANUM_SUPABASE_URL=... \
///                     --dart-define=ARCANUM_SUPABASE_KEY=...
///
/// The defaults below are the live project's, so an ordinary build works and a
/// fork can point somewhere else without editing anything.
abstract final class SupabaseConfig {
  static const String url = String.fromEnvironment(
    'ARCANUM_SUPABASE_URL',
    defaultValue: 'https://wqycllzbwbhqiqlmbwcu.supabase.co',
  );

  static const String publishableKey = String.fromEnvironment(
    'ARCANUM_SUPABASE_KEY',
    defaultValue: 'sb_publishable_2RKicx3ySiVaE7fIRwF0Uw_42qm8Rqn',
  );

  /// Whether there is anywhere to sign in to.
  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;
}
