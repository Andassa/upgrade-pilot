/// The value of [values] named [name], or a [FormatException].
T enumByName<T extends Enum>(List<T> values, String name) =>
    values.asNameMap()[name] ??
    (throw FormatException('unknown value "$name"'));

/// Typed access to decoded JSON that reports problems as
/// [FormatException] instead of type errors.
extension type const JsonReader(Map<String, Object?> json) {
  T _get<T>(String key) {
    final value = json[key];
    if (value is T) return value;
    throw FormatException('"$key" must be a $T, found ${value.runtimeType}');
  }

  String string(String key) => _get<String>(key);
  String? optionalString(String key) => _get<String?>(key);
  int integer(String key) => _get<int>(key);
  int? optionalInt(String key) => json[key] is int ? json[key]! as int : null;
  bool boolean(String key, {bool fallback = false}) =>
      json[key] is bool ? json[key]! as bool : fallback;

  JsonReader object(String key) => JsonReader(_get<Map<String, Object?>>(key));

  JsonReader optionalObject(String key) => json[key] is Map<String, Object?>
      ? JsonReader(json[key]! as Map<String, Object?>)
      : const JsonReader({});

  List<JsonReader> objects(String key) => [
        for (final item in _get<List<Object?>>(key))
          if (item is Map<String, Object?>)
            JsonReader(item)
          else
            throw FormatException('"$key" must contain objects'),
      ];

  List<String> strings(String key) => [
        for (final item in _get<List<Object?>>(key))
          if (item is String)
            item
          else
            throw FormatException('"$key" must contain strings'),
      ];

  Object? operator [](String key) => json[key];
}
