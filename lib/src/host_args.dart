/// Typed accessors for the `Map<String, Object?>` argument map passed to
/// every `HostFunction` handler.
///
/// `HostFunctionSchema.mapAndValidate` validates argument types once, then
/// the typed info is dropped — every handler has to re-cast. This extension
/// is the thin layer that makes the recast ergonomic and consistent.
///
/// ```dart
/// Future<Object?> _handleRender(Map<String, Object?> args) {
///   final template = args.str('template');
///   final context = args.mapArg('context');
///   // ...
/// }
/// ```
extension HostArgs on Map<String, Object?> {
  /// Returns the required [String] value for [key].
  ///
  /// Throws [TypeError] if the value is missing or not a [String].
  String str(String key) => this[key]! as String;

  /// Returns the optional [String] value for [key], or `null` if absent.
  String? strOrNull(String key) => this[key] as String?;

  /// Returns the required [int] value for [key].
  ///
  /// Accepts any [num] (converts via [num.toInt]).
  /// Throws [TypeError] if the value is missing or not a number.
  int intArg(String key) => (this[key]! as num).toInt();

  /// Returns the optional [int] value for [key], or `null` if absent.
  ///
  /// Accepts any [num] (converts via [num.toInt]).
  int? intArgOrNull(String key) => (this[key] as num?)?.toInt();

  /// Returns the required [List] value for [key], narrowed to `List<T>`.
  ///
  /// Element types are not deeply validated — the returned list is a
  /// `cast<T>()` view. Throws [TypeError] if the value is missing or not a
  /// list.
  List<T> listOf<T>(String key) => (this[key]! as List).cast();

  /// Returns the required map value for [key] as `Map<String, Object?>`.
  ///
  /// Named `mapArg` (not `map`) so it does not shadow `Map.map`. Copies the
  /// incoming map so the returned value has the expected static type
  /// regardless of the runtime map shape (Python decoders often produce
  /// `Map<String, dynamic>`). Throws [TypeError] if the value is missing or
  /// not a map.
  Map<String, Object?> mapArg(String key) => Map.from(this[key]! as Map);
}
