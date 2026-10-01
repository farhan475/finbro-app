import 'package:drift/drift.dart';

import 'enums.dart';

class DbEnumConverter<T extends DbEnum> extends TypeConverter<T, String> {
  const DbEnumConverter(this.values);
  final List<T> values;

  @override
  T fromSql(String fromDb) => enumFromDb(values, fromDb);

  @override
  String toSql(T value) => value.db;
}

/// Local wall-clock timestamp stored as ISO 8601 without offset
/// (`2026-09-30T20:30:00`). Single-user, single-timezone app: lexicographic
/// order equals chronological order, so range filters work on the raw text.
class LocalDateTimeConverter extends TypeConverter<DateTime, String> {
  const LocalDateTimeConverter();

  @override
  DateTime fromSql(String fromDb) => DateTime.parse(fromDb);

  @override
  String toSql(DateTime value) => isoLocal(value);
}

/// Calendar date stored as `yyyy-MM-dd`, exposed as local midnight.
class DateOnlyConverter extends TypeConverter<DateTime, String> {
  const DateOnlyConverter();

  @override
  DateTime fromSql(String fromDb) => DateTime.parse(fromDb);

  @override
  String toSql(DateTime value) => isoDate(value);
}

String _two(int v) => v.toString().padLeft(2, '0');

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

String isoLocal(DateTime d) {
  final l = d.isUtc ? d.toLocal() : d;
  return '${isoDate(l)}T${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}
