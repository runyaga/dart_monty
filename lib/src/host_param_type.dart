/// Parameter types for host function arguments.
enum HostParamType {
  /// String parameter. Monty Python `str`.
  string,

  /// Integer parameter. Monty Python `int`.
  integer,

  /// Floating-point parameter. Monty Python `float`.
  number,

  /// Boolean parameter. Monty Python `bool`.
  boolean,

  /// List parameter. Monty Python `list`.
  list,

  /// Map/dict parameter. Monty Python `dict`.
  map,

  /// Any type — passes through validation without type checking.
  ///
  /// Used for parameters like filter values that accept str, int, float, etc.
  any
  ;

  /// JSON Schema type name for display and serialization.
  ///
  /// For JSON Schema generation, prefer `HostParam.toJsonSchema()` which
  /// handles `any` by omitting the `type` key entirely (unconstrained).
  String get jsonSchemaType => switch (this) {
    string => 'string',
    integer => 'integer',
    number => 'number',
    boolean => 'boolean',
    list => 'array',
    map => 'object',
    any => 'any',
  };
}
