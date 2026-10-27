pub const DosTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
};

pub const DosDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

pub fn decodeDOSTime(raw: u16) DosTime {
    // DOS stores seconds in 2-second units.
    return .{
        .hour = @as(u8, @truncate((raw >> 11) & 0b1_1111)),
        .minute = @as(u8, @truncate((raw >> 5) & 0b11_1111)),
        .second = @as(u8, @truncate((raw & 0b1_1111) * 2)),
    };
}

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
    const epoch = @import("std").time.epoch;
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

test "time: decodeDOSTime reads hour, minute, second in APPNOTE 4.4.6 bit order" {
    // bits 15-11 hour, 10-5 minute, 4-0 second / 2. 11:17:56 built by hand (== 0x5A3C).
    const raw: u16 = (11 << 11) | (17 << 5) | (56 / 2);
    try @import("std").testing.expectEqual(@as(u16, 0x5A3C), raw);
    const t = decodeDOSTime(raw);
    try @import("std").testing.expectEqual(DosTime{ .hour = 11, .minute = 17, .second = 56 }, t);

    // Max legal values: 23:59:58.
    const t_max = decodeDOSTime((23 << 11) | (59 << 5) | (58 / 2));
    try @import("std").testing.expectEqual(DosTime{ .hour = 23, .minute = 59, .second = 58 }, t_max);
}

test "time: decodeDosDate reads year, month, day in APPNOTE 4.4.6 bit order" {
    // bits 15-9 year - 1980, 8-5 month, 4-0 day. 2026-10-26 built by hand.
    const raw: u16 = ((2026 - 1980) << 9) | (10 << 5) | 26;
    try @import("std").testing.expectEqual(DosDate{ .year = 2026, .month = 10, .day = 26 }, decodeDosDate(raw));
}

test "time: encodeDosDateTime round-trips through the decoders and clamps the DOS range" {
    const testing = @import("std").testing;

    // 2026-10-26 11:17:57 UTC; DOS drops the odd second.
    const dt = encodeDosDateTime(1793013477);
    try testing.expectEqual(DosDate{ .year = 2026, .month = 10, .day = 26 }, decodeDosDate(dt.date));
    try testing.expectEqual(DosTime{ .hour = 11, .minute = 17, .second = 56 }, decodeDOSTime(dt.time));

    // Before 1980 clamps to 1980-01-01 00:00:00.
    for ([_]i64{ 0, -1, 315532799 }) |t| {
        const lo = encodeDosDateTime(t);
        try testing.expectEqual(DosDate{ .year = 1980, .month = 1, .day = 1 }, decodeDosDate(lo.date));
        try testing.expectEqual(DosTime{ .hour = 0, .minute = 0, .second = 0 }, decodeDOSTime(lo.time));
    }

    // After 2107 clamps to 2107-12-31 23:59:58.
    const hi = encodeDosDateTime(@import("std").math.maxInt(i64));
    try testing.expectEqual(DosDate{ .year = 2107, .month = 12, .day = 31 }, decodeDosDate(hi.date));
    try testing.expectEqual(DosTime{ .hour = 23, .minute = 59, .second = 58 }, decodeDOSTime(hi.time));
    try testing.expectEqual(hi, encodeDosDateTime(4354819200)); // 2108-01-01 00:00:00
}
