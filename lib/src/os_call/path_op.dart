/// The filesystem operation without a `Path.` prefix.
abstract final class PathOp {
  /// Python's lowercase `open` operation, routed with `Path.*`.
  static const open = 'open';
}
