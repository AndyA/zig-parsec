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
    expr: *const P.Parser = undefined,
};

const P = zpc.Zpc(JsonContext, JsonTag);

fn makeJsonParser() P.Parser {
    const intParser = P.takeWhile(.NONE, .oneOrMore, std.ascii.isDigit);
    _ = intParser;
    // const numberParser = P.

    const atomParser = P.alt(&.{
        P.keyword(.FALSE, "false"),
        P.keyword(.TRUE, "true"),
        P.keyword(.NULL, "null"),
    });
    _ = atomParser;
}
