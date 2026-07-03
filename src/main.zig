const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;

test {
    _ = @import("zpc.zig");
}

pub fn main() void {
    print("Hello, World\n", .{});
}
