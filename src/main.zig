const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    _ = init;
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}
