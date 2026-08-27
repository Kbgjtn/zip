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
    return .{
        .hour = @as(u8, @truncate((raw & 0b00000_000000_11111) * 2)),
        .minute = @as(u8, @truncate((raw >> 5) & 0b111111)),
        .second = @as(u8, @truncate((raw >> 11) & 0b11111)),
    };
}

pub fn decodeDosDate(raw: u16) DosDate {
    return DosDate{
        .day = @as(u8, @truncate(raw & 0b11111)),
        .month = @as(u8, @truncate((raw >> 5) & 0b1111)),
        .year = 1980 + ((raw >> 9) & 0b1111111),
    };
}
