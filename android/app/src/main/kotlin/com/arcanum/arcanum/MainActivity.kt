package com.arcanum.arcanum

import io.flutter.embedding.android.FlutterFragmentActivity

/// A fragment activity rather than a plain one, because the biometric prompt
/// the app's lock uses is a fragment. FlutterFragmentActivity is Flutter's own
/// class, so the lock costs the app no new native code.
class MainActivity : FlutterFragmentActivity()
