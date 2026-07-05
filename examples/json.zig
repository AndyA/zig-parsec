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
};

const JsonContext = struct {
    allocator: Allocator,
    expr: *const P.Parser = undefined,
};

const P = zpc.Zpc(JsonContext, JsonTag);
