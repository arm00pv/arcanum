import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// Points sqflite at the browser's own SQLite.
///
/// sqlite3 compiled to WebAssembly, kept in the browser's storage. The app's
/// data layer was written against sqflite's global factory and never against a
/// platform, so this is the whole of what a browser needs from it.
///
/// A *dedicated* worker rather than the shared one the package defaults to. A
/// shared worker outlives the page that started it, and the second page load
/// then waits on a database connection whose other end belongs to a page that
/// no longer exists - which is what a reload looked like: the app stopped at
/// "opening the database" and stayed there. A dedicated worker is created by
/// the page, dies with it, and leaves nothing behind to wait on. The work still
/// happens off the main thread, which is the part worth keeping: a set of a
/// hundred and thirty-five cards is written in one go.
void useWebDatabaseFactory() {
  databaseFactory = databaseFactoryFfiWebBasicWebWorker;
}
