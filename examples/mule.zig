const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

pub fn main(init: std.process.Init) !void {
    _ = init;
    print("Hello, Mule!\n", .{});
}
