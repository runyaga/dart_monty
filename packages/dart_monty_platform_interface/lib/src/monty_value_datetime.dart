part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// DateTime types
// ---------------------------------------------------------------------------

@immutable
final class MontyDate extends MontyValue {
  const MontyDate({required this.year, required this.month, required this.day});
  final int year;
  final int month;
  final int day;

  factory MontyDate._fromMap(Map<String, dynamic> map) => MontyDate(
        year: (map['year'] as num).toInt(),
        month: (map['month'] as num).toInt(),
        day: (map['day'] as num).toInt(),
      );

  @override
  Map<String, Object?> toJson() => {
        '__type': 'date',
        'year': year,
        'month': month,
        'day': day,
      };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDate &&
          other.year == year &&
          other.month == month &&
          other.day == day);

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      'MontyDate($year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')})';
}

@immutable
final class MontyDateTime extends MontyValue {
  const MontyDateTime({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    this.microsecond = 0,
    this.offsetSeconds,
    this.timezoneName,
  });

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;
  final int microsecond;
  final int? offsetSeconds;
  final String? timezoneName;

  factory MontyDateTime._fromMap(Map<String, dynamic> map) => MontyDateTime(
        year: (map['year'] as num).toInt(),
        month: (map['month'] as num).toInt(),
        day: (map['day'] as num).toInt(),
        hour: (map['hour'] as num).toInt(),
        minute: (map['minute'] as num).toInt(),
        second: (map['second'] as num).toInt(),
        microsecond: (map['microsecond'] as num?)?.toInt() ?? 0,
        offsetSeconds: (map['offset_seconds'] as num?)?.toInt(),
        timezoneName: map['timezone_name'] as String?,
      );

  @override
  Map<String, Object?> toJson() => {
        '__type': 'datetime',
        'year': year,
        'month': month,
        'day': day,
        'hour': hour,
        'minute': minute,
        'second': second,
        'microsecond': microsecond,
        'offset_seconds': offsetSeconds,
        'timezone_name': timezoneName,
      };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDateTime &&
          other.year == year &&
          other.month == month &&
          other.day == day &&
          other.hour == hour &&
          other.minute == minute &&
          other.second == second &&
          other.microsecond == microsecond &&
          other.offsetSeconds == offsetSeconds &&
          other.timezoneName == timezoneName);

  @override
  int get hashCode => Object.hash(
        year, month, day, hour, minute, second, microsecond,
        offsetSeconds, timezoneName,
      );

  @override
  String toString() => 'MontyDateTime($year-${month.toString().padLeft(2, '0')}'
      '-${day.toString().padLeft(2, '0')}T'
      '${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}:'
      '${second.toString().padLeft(2, '0')})';
}

@immutable
final class MontyTimeDelta extends MontyValue {
  const MontyTimeDelta({
    required this.days,
    required this.seconds,
    this.microseconds = 0,
  });

  final int days;
  final int seconds;
  final int microseconds;

  factory MontyTimeDelta._fromMap(Map<String, dynamic> map) => MontyTimeDelta(
        days: (map['days'] as num).toInt(),
        seconds: (map['seconds'] as num).toInt(),
        microseconds: (map['microseconds'] as num?)?.toInt() ?? 0,
      );

  @override
  Map<String, Object?> toJson() => {
        '__type': 'timedelta',
        'days': days,
        'seconds': seconds,
        'microseconds': microseconds,
      };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTimeDelta &&
          other.days == days &&
          other.seconds == seconds &&
          other.microseconds == microseconds);

  @override
  int get hashCode => Object.hash(days, seconds, microseconds);

  @override
  String toString() => 'MontyTimeDelta(days=$days, seconds=$seconds)';
}

@immutable
final class MontyTimeZone extends MontyValue {
  const MontyTimeZone({required this.offsetSeconds, this.name});
  final int offsetSeconds;
  final String? name;

  factory MontyTimeZone._fromMap(Map<String, dynamic> map) => MontyTimeZone(
        offsetSeconds: (map['offset_seconds'] as num).toInt(),
        name: map['name'] as String?,
      );

  @override
  Map<String, Object?> toJson() => {
        '__type': 'timezone',
        'offset_seconds': offsetSeconds,
        'name': name,
      };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTimeZone &&
          other.offsetSeconds == offsetSeconds &&
          other.name == name);

  @override
  int get hashCode => Object.hash(offsetSeconds, name);

  @override
  String toString() => 'MontyTimeZone(offset=$offsetSeconds, name=$name)';
}
