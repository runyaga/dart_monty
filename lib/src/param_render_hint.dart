/// How a parameter value should be rendered in activity-log tiles and
/// other developer-facing surfaces.
///
/// Plugin authors attach a hint at the source of truth — the
/// `HostParam` declaration — so every consumer (Soliplex activity-log,
/// VFS demo, CLI) fences the value in the matching code block without
/// guessing by argument name.
///
/// The hint is advisory: it does not change validation or runtime
/// behavior. Unknown or absent hints default to [plain].
enum ParamRenderHint {
  /// Unformatted string — no syntax highlighting.
  plain,

  /// Python source code.
  python,

  /// Jinja2 template source.
  jinja,

  /// JSON literal.
  json,

  /// SQL query.
  sql,

  /// Markdown document.
  markdown,
}
