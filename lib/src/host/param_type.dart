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

  /// Accepts every core value without type checking.
  any;

  /// Provides the corresponding JSON Schema type name.
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
