//! MS-DOS date and time (APPNOTE 4.4.6) to and from Unix seconds.

const std = @import("std");

/// An MS-DOS time of day, decoded. `second` is always even: DOS stores seconds / 2.
pub const DosTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
};

/// An MS-DOS date, decoded. Years run from 1980 to 2107.
pub const DosDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

/// Splits a packed DOS time (APPNOTE 4.4.6): bits 15-11 hour, 10-5 minute, 4-0 second / 2.
pub fn decodeDosTime(raw: u16) DosTime {
    // DOS stores seconds in 2-second units.
    return .{
        .hour = @as(u8, @truncate((raw >> 11) & 0b1_1111)),
        .minute = @as(u8, @truncate((raw >> 5) & 0b11_1111)),
        .second = @as(u8, @truncate((raw & 0b1_1111) * 2)),
    };
}

/// Splits a packed DOS date (APPNOTE 4.4.6): bits 15-9 year - 1980, 8-5 month, 4-0 day.
pub fn decodeDosDate(raw: u16) DosDate {
    return DosDate{
        .day = @as(u8, @truncate(raw & 0b1_1111)),
        .month = @as(u8, @truncate((raw >> 5) & 0b1111)),
        .year = 1980 + ((raw >> 9) & 0b111_1111),
    };
}

/// Packed DOS time and date, ready for the header fields (APPNOTE 4.4.6).
pub const DosDateTime = struct { time: u16, date: u16 };

/// Unix seconds to DOS time and date (APPNOTE 4.4.6). DOS covers 1980-01-01 to 2107-12-31
/// with 2-second steps, so earlier times clamp to 1980-01-01 00:00:00 and later ones to
/// 2107-12-31 23:59:58. Odd seconds round down.
///
/// DOS time has no time zone. The fields are filled as if `unix` were UTC, so pass the local
/// or UTC seconds you want to see stored.
pub fn encodeDosDateTime(unix: i64) DosDateTime {
    const epoch = std.time.epoch;
    const min: DosDateTime = .{ .time = 0, .date = (1 << 5) | 1 };
    const max: DosDateTime = .{
        .time = (23 << 11) | (59 << 5) | (58 / 2),
        .date = (127 << 9) | (12 << 5) | 31,
    };
    if (unix < epoch.dos) return min;
    // Clamp the top before the epoch maths: calculateYearDay loops once per year, so a huge
    // value would spin for ages.
    if (unix >= 4354819200) return max; // 2108-01-01 00:00:00 UTC

    const es: epoch.EpochSeconds = .{ .secs = @intCast(unix) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    return .{
        .time = (@as(u16, day_secs.getHoursIntoDay()) << 11) |
            (@as(u16, day_secs.getMinutesIntoHour()) << 5) |
            (day_secs.getSecondsIntoMinute() / 2),
        .date = ((year_day.year - 1980) << 9) |
            (@as(u16, month_day.month.numeric()) << 5) |
            (@as(u16, month_day.day_index) + 1),
    };
}

/// MS-DOS time and date (APPNOTE 4.4.6) to Unix seconds, the inverse of
/// `encodeDosDateTime`. DOS time has no time zone, so the fields are read as if they were
/// UTC. Fields outside their range (month 0 or 13 to 15, day 0, hour 24 to 31) aren't
/// checked: the result is then a nearby time, never a crash.
pub fn decodeDosDateTime(dt: DosDateTime) i64 {
    const d = decodeDosDate(dt.date);
    const t = decodeDosTime(dt.time);
    return daysFromCivil(d.year, d.month, d.day) * 86400 +
        @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
}

/// Days from 1970-01-01 to a date in the proleptic Gregorian calendar (Howard Hinnant's
/// `days_from_civil`, http://howardhinnant.github.io/date_algorithms.html). std only has
/// the other direction (`std.time.epoch.EpochDay.calculateYearDay`).
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    // Count years from March, so the leap day is the last day of the year.
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400; // 0 to 399
    const day_of_year = @divFloor(153 * @mod(month + 9, 12) + 2, 5) + day - 1; // March 1 is 0
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468; // 719468: days from 0000-03-01 to 1970-01-01
}

test "time: decodeDosTime reads hour, minute, second in APPNOTE 4.4.6 bit order" {
    // bits 15-11 hour, 10-5 minute, 4-0 second / 2. 11:17:56 built by hand (== 0x5A3C).
    const raw: u16 = (11 << 11) | (17 << 5) | (56 / 2);
    try std.testing.expectEqual(@as(u16, 0x5A3C), raw);
    const t = decodeDosTime(raw);
    try std.testing.expectEqual(DosTime{ .hour = 11, .minute = 17, .second = 56 }, t);

    // Max legal values: 23:59:58.
    const t_max = decodeDosTime((23 << 11) | (59 << 5) | (58 / 2));
    try std.testing.expectEqual(DosTime{ .hour = 23, .minute = 59, .second = 58 }, t_max);
}

test "time: decodeDosDate reads year, month, day in APPNOTE 4.4.6 bit order" {
    // bits 15-9 year - 1980, 8-5 month, 4-0 day. 2026-10-26 built by hand.
    const raw: u16 = ((2026 - 1980) << 9) | (10 << 5) | 26;
    try std.testing.expectEqual(DosDate{ .year = 2026, .month = 10, .day = 26 }, decodeDosDate(raw));
}

test "time: encodeDosDateTime round-trips through the decoders and clamps the DOS range" {
    const testing = std.testing;

    // 2026-10-26 11:17:57 UTC; DOS drops the odd second.
    const dt = encodeDosDateTime(1793013477);
    try testing.expectEqual(DosDate{ .year = 2026, .month = 10, .day = 26 }, decodeDosDate(dt.date));
    try testing.expectEqual(DosTime{ .hour = 11, .minute = 17, .second = 56 }, decodeDosTime(dt.time));

    // Before 1980 clamps to 1980-01-01 00:00:00.
    for ([_]i64{ 0, -1, 315532799 }) |t| {
        const lo = encodeDosDateTime(t);
        try testing.expectEqual(DosDate{ .year = 1980, .month = 1, .day = 1 }, decodeDosDate(lo.date));
        try testing.expectEqual(DosTime{ .hour = 0, .minute = 0, .second = 0 }, decodeDosTime(lo.time));
    }

    // After 2107 clamps to 2107-12-31 23:59:58.
    const hi = encodeDosDateTime(std.math.maxInt(i64));
    try testing.expectEqual(DosDate{ .year = 2107, .month = 12, .day = 31 }, decodeDosDate(hi.date));
    try testing.expectEqual(DosTime{ .hour = 23, .minute = 59, .second = 58 }, decodeDosTime(hi.time));
    try testing.expectEqual(hi, encodeDosDateTime(4354819200)); // 2108-01-01 00:00:00
}

test "time: decodeDosDateTime inverts encodeDosDateTime over the whole DOS range" {
    const testing = std.testing;
    try testing.expectEqual(@as(i64, 315532800), decodeDosDateTime(encodeDosDateTime(315532800))); // 1980-01-01
    try testing.expectEqual(@as(i64, 1793013476), decodeDosDateTime(encodeDosDateTime(1793013477))); // odd second drops
    try testing.expectEqual(@as(i64, 4354819198), decodeDosDateTime(encodeDosDateTime(4354819199))); // 2107-12-31 23:59:58

    // Every 3rd day from 1980 to 2107, at an even second that moves through the day.
    var day: i64 = 0;
    while (day < 46_752) : (day += 3) {
        const unix = 315532800 + day * 86400 + @mod(day * 7919, 43200) * 2;
        try testing.expectEqual(unix, decodeDosDateTime(encodeDosDateTime(unix)));
    }
}
