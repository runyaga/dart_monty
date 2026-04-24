/// Native-target implementation of `DartMonty.ensureInitialized()`.
///
/// On Dart VM / Flutter desktop / Flutter mobile, Monty uses FFI via
/// `dart_monty_core`'s native-asset hook — no JS bridge exists, so this
/// is a no-op. The conditional import in `ensure_initialized.dart`
/// selects this file whenever `dart.library.js_interop` is unavailable.
Future<void> ensureInitialized() async {
  // Intentionally empty.
}
