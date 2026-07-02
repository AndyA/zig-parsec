const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ZpcError = error{OutOfMemory};
pub const ZpcPred = fn (char: u8) bool;

pub fn ZpcNode(comptime Tag: type) type {
    return struct {
        const Self = @This();
        tag: Tag,
        value: union(enum) {
            nothing: void,
            slice: []const u8,
            list: []const Self,
        },

        pub fn initSlice(tag: Tag, slice: []const u8) Self {
            return .{ .tag = tag, .value = .{ .slice = slice } };
        }

        pub fn deinit(self: Self, alloc: Allocator) void {
            switch (self.value) {
                .list => |list| {
                    for (list) |l| l.deinit(alloc);
                    alloc.free(list);
                },
                else => {},
            }
        }
    };
}

pub fn ZpcResult(comptime Tag: type) type {
    return struct {
        const Self = @This();
        tok: union(enum) {
            ok: ZpcNode(Tag),
            fail: void,
        },
        rest: []const u8,

        pub fn initFail(rest: []const u8) Self {
            return .{ .tok = .{ .fail = {} }, .rest = rest };
        }

        pub fn initOk(value: ZpcNode(Tag), rest: []const u8) Self {
            return .{ .tok = .{ .ok = value }, .rest = rest };
        }

        pub fn deinit(self: Self, alloc: Allocator) void {
            switch (self.tok) {
                .ok => |ok| ok.deinit(alloc),
                else => {},
            }
        }
    };
}

pub fn ZpcParser(comptime Context: type, comptime Tag: type) type {
    return fn (ctx: *Context, input: []const u8) ZpcError!ZpcResult(Tag);
}

const TestTag = enum { HELLO };
const TestContext = struct {
    allocator: Allocator,
    expr: *const ZpcParser(@This(), TestTag) = undefined,
};

const TZ = Zpc(TestContext, TestTag);

fn checkAndConsume(
    ctx: TestContext,
    expected: ZpcResult(TestTag),
    actual: ZpcResult(TestTag),
) !void {
    defer actual.deinit(ctx.allocator);
    try expectEqualDeep(expected, actual);
}

pub fn Zpc(comptime Context: type, comptime Tag: type) type {
    assert(@hasField(Context, "allocator"));
    return struct {
        pub const Result = ZpcResult(Tag);
        pub const Parser = ZpcParser(Context, Tag);
        pub const Mapper = fn (ctx: *Context, result: Result) ZpcError!Result;

        // Call a parser that is pointed to by a field on the context.
        pub fn recurse(comptime field_name: []const u8) Parser {
            const shim = struct {
                fn match(ctx: *Context, input: []const u8) ZpcError!Result {
                    const hook = @field(Context, field_name);
                    return hook(ctx, input);
                }
            };
            return shim.match;
        }

        pub fn lit(tag: Tag, str: []const u8) Parser {
            const shim = struct {
                fn litParser(_: *Context, input: []const u8) ZpcError!Result {
                    if (input.len >= str.len and std.mem.eql(u8, input[0..str.len], str))
                        return .initOk(.initSlice(tag, str), input[str.len..]);
                    return .initFail(input);
                }
            };
            return shim.litParser;
        }

        test lit {
            const hello = TZ.lit(.HELLO, "Hello");

            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.HELLO, "Hello"), ", World"),
                try hello(&ctx, "Hello, World"),
            );

            try checkAndConsume(
                ctx,
                .initFail("H"),
                try hello(&ctx, "H"),
            );

            try checkAndConsume(
                ctx,
                .initFail("Hell or bust"),
                try hello(&ctx, "Hell or bust"),
            );
        }

        // Succeeds if there is at least one character of input. Returns the parsed character.
        // pub fn any() Parser {
        //     const shim = struct {
        //         fn match(_: *Context, input: []const u8) ZpcError!Result {
        //             if (input.len == 0)
        //                 return .initErr(input, "end of input");
        //             return .initOk(.{ .slice = input[0..1] }, input[1..]);
        //         }
        //     };
        //     return shim.match;
        // }

        // test any {
        //     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        //     defer arena.deinit();

        //     const anything = TZ.any();
        //     var ctx: TestContext = .{ .allocator = arena.allocator() };

        //     try expectEqualDeep(
        //         Result.initOk(.{ .slice = "H" }, "ello, World"),
        //         anything(&ctx, "Hello, World"),
        //     );

        //     try expectEqualDeep(
        //         Result.initErr("", "end of input"),
        //         anything(&ctx, ""),
        //     );
        // }

        // Succeeds if the character is in the supplied string. Returns the parsed character.
        // pub fn oneOf(comptime chars: []const u8) Parser {
        //     const shim = struct {
        //         fn match(_: *Context, input: []const u8) ZpcError!Result {
        //             if (input.len == 0)
        //                 return .initErr(input, "end of input");
        //             if (!std.mem.containsAtLeastScalar(u8, chars, input[0], 1))
        //                 return .initErr(input, "non match");
        //             return .initOk(.{ .slice = input[0..1] }, input[1..]);
        //         }
        //     };
        //     return shim.match;
        // }

        // test oneOf {
        //     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        //     defer arena.deinit();

        //     const endLine = TZ.oneOf("\n\r");
        //     var ctx: TestContext = .{ .allocator = arena.allocator() };
        //     try expectEqualDeep(
        //         Result.initOk(.{ .slice = "\n" }, "\r"),
        //         endLine(&ctx, "\n\r"),
        //     );

        //     try expectEqualDeep(
        //         Result.initOk(.{ .slice = "\r" }, "\n"),
        //         endLine(&ctx, "\r\n"),
        //     );

        //     try expectEqualDeep(
        //         Result.initErr("Hello", "non match"),
        //         endLine(&ctx, "Hello"),
        //     );
        // }
    };
}

test Zpc {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = TZ;
    // var ctx: C = .{ .allocator = arena.allocator() };
    // _ = ctx;
}
