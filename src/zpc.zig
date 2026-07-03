const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ZpcError = error{OutOfMemory};
pub const ZpcPred = fn (char: u8) bool;

pub fn ZpcToken(comptime Tag: type) type {
    return struct {
        const Self = @This();
        pub const List = std.ArrayList(Self);

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
                    for (list) |item| item.deinit(alloc);
                    alloc.free(list);
                },
                else => {},
            }
        }

        pub fn deinitList(list: List, alloc: Allocator) void {
            for (list.items) |item| item.deinit(alloc);
            list.deinit(alloc);
        }
    };
}

pub fn ZpcResult(comptime Tag: type) type {
    return struct {
        const Self = @This();
        tok: union(enum) {
            ok: ZpcToken(Tag),
            fail: void,
        },
        rest: []const u8,

        pub fn initFail(rest: []const u8) Self {
            return .{ .tok = .{ .fail = {} }, .rest = rest };
        }

        pub fn initOk(value: ZpcToken(Tag), rest: []const u8) Self {
            return .{ .tok = .{ .ok = value }, .rest = rest };
        }

        pub fn deinit(self: Self, alloc: Allocator) void {
            switch (self.tok) {
                .ok => |ok| ok.deinit(alloc),
                else => {},
            }
        }

        pub fn matched(self: Self) bool {
            return self.tok == .ok;
        }
    };
}

pub fn ZpcParser(comptime Context: type, comptime Tag: type) type {
    return fn (ctx: *Context, input: []const u8) ZpcError!ZpcResult(Tag);
}

const TestTag = enum { HELLO, FOO };

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
        pub const Token = ZpcToken(Tag);
        pub const Result = ZpcResult(Tag);
        pub const Parser = ZpcParser(Context, Tag);
        pub const Mapper = fn (ctx: *Context, result: Result) ZpcError!Result;

        // Call a parser that is pointed to by a field on the context.
        pub fn recurse(comptime field_name: []const u8) Parser {
            const shim = struct {
                fn match(ctx: *Context, input: []const u8) ZpcError!Result {
                    const parser = @field(Context, field_name);
                    return parser(ctx, input);
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

        pub fn alt(parsers: []const *const Parser) Parser {
            const shim = struct {
                fn altParser(ctx: *Context, input: []const u8) ZpcError!Result {
                    inline for (parsers) |parser| {
                        const res = try parser(ctx, input);
                        if (res.matched())
                            return res;
                    }

                    return .initFail(input);
                }
            };
            return shim.altParser;
        }

        test alt {
            const oneOf = TZ.alt(&.{
                TZ.lit(.HELLO, "Hello"),
                TZ.lit(.FOO, "Foo"),
            });

            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.HELLO, "Hello"), ", World"),
                try oneOf(&ctx, "Hello, World"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.FOO, "Foo"), "Bar"),
                try oneOf(&ctx, "FooBar"),
            );

            try checkAndConsume(
                ctx,
                .initFail("Hell or bust"),
                try oneOf(&ctx, "Hell or bust"),
            );
        }
    };
}

test Zpc {
    _ = TZ;
}
