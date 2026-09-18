/// Puts a database factory in place on a browser, and does nothing elsewhere.
///
/// Arcanum's store is SQLite, opened through `sqflite`'s global factory. On
/// Android and iOS that factory is the platform's own; a browser has none, so
/// the data layer would open nothing at all there. This is the one line that
/// differs: the same schema, the same migrations and the same queries, run
/// against sqlite3 compiled to WebAssembly.
///
/// Conditional on an export rather than on a runtime check, because the web
/// implementation imports JavaScript interop that the phone build cannot
/// compile - the check has to be made before the compiler sees the code.
library;

export 'web_database_stub.dart'
    if (dart.library.js_interop) 'web_database_web.dart';
