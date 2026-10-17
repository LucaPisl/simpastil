DateTime syncDate(Object? value) => DateTime.parse(value as String).toUtc();

DateTime? syncNullableDate(Object? value) =>
    value == null ? null : syncDate(value);

int? syncNullableInt(Object? value) =>
    value == null ? null : int.parse(value as String);
