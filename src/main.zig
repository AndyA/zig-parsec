const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("../src/zpc.zig");

const JsonTag = enum {
    NONE,
    NUMBER,
    STRING,
    FALSE,
    TRUE,
    NULL,
    ARRAY,
    OBJECT,
    KEYVALUE,
};

const JsonContext = struct {
    allocator: Allocator,
    // expr: *const P.Parser = undefined,
};

const P = zpc.Zpc(JsonContext, JsonTag);

fn makeJsonParser() P.Parser {
    const intParser = P.takeWhile(.NONE, .oneOrMore, std.ascii.isDigit);
    const numberParser = P.span(
        .NUMBER,
        P.seq(.NONE, &.{
            intParser,
            P.optional(P.seq(.NONE, &.{ P.literal("."), intParser })),
        }),
    );

    const atomParser = P.alt(&.{
        P.keyword(.FALSE, "false"),
        P.keyword(.TRUE, "true"),
        P.keyword(.NULL, "null"),
        numberParser,
    });

    return atomParser;
}

pub fn main(init: std.process.Init) !void {
    const jsonParser = makeJsonParser();
    const ctx: JsonContext = .{ .allocator = init.gpa };
    const res = try jsonParser(ctx, "12.3");
    print("{f}\n", .{res});
}

test {
    _ = @import("zpc.zig");
}
