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
