/// Asks a browser to keep this origin's data, and does nothing elsewhere.
///
/// A browser build of Arcanum keeps two things in storage the browser owns: the
/// catalogue it has downloaded, and this device's copy of the collection. A
/// browser is entitled to delete either of them without asking, and iOS Safari
/// does exactly that for an origin the collector has not interacted with for
/// seven days - which is what the Storage API's persistent mode exists to be
/// exempt from. This is the one line in the app that asks for it.
///
/// Conditional on an export rather than on a runtime check, for the reason the
/// database factory is: the implementation imports JavaScript interop that the
/// phone build cannot compile, so the question has to be settled before the
/// compiler sees the code.
library;

export 'web_storage_stub.dart'
    if (dart.library.js_interop) 'web_storage_web.dart';
