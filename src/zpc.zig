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

const TestTag = enum { HELLO, FOO, BAR, NEWLINE };

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
            const parseHello = lit(.HELLO, "Hello");

            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.HELLO, "Hello"), ", World"),
                try parseHello(&ctx, "Hello, World"),
            );

            try checkAndConsume(
                ctx,
                .initFail("H"),
                try parseHello(&ctx, "H"),
            );

            try checkAndConsume(
                ctx,
                .initFail("Hell or bust"),
                try parseHello(&ctx, "Hell or bust"),
            );
        }

        pub fn oneOf(tag: Tag, chars: []const u8) Parser {
            const shim = struct {
                fn oneOfParser(_: *Context, input: []const u8) ZpcError!Result {
                    if (input.len > 0 and std.mem.containsAtLeastScalar(u8, chars, input[0], 1))
                        return .initOk(.initSlice(tag, input[0..1]), input[1..]);
                    return .initFail(input);
                }
            };
            return shim.oneOfParser;
        }

        test oneOf {
            const parseNewline = oneOf(.NEWLINE, "\n\r");
            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.NEWLINE, "\n"), "\r"),
                try parseNewline(&ctx, "\n\r"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.NEWLINE, "\r"), "\n"),
                try parseNewline(&ctx, "\r\n"),
            );

            try checkAndConsume(
                ctx,
                .initFail("X"),
                try parseNewline(&ctx, "X"),
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
            const parseAlt = alt(&.{
                lit(.HELLO, "Hello"),
                lit(.FOO, "Foo"),
            });

            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.HELLO, "Hello"), ", World"),
                try parseAlt(&ctx, "Hello, World"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.FOO, "Foo"), "Bar"),
                try parseAlt(&ctx, "FooBar"),
            );

            try checkAndConsume(
                ctx,
                .initFail("Hell or bust"),
                try parseAlt(&ctx, "Hell or bust"),
            );
        }

        pub fn left(lp: Parser, rp: Parser) Parser {
            const shim = struct {
                fn leftParser(ctx: *Context, input: []const u8) ZpcError!Result {
                    const lres = try lp(ctx, input);
                    errdefer lres.deinit(ctx.allocator);
                    if (!lres.matched()) return .initFail(input);
                    const rres = try rp(ctx, lres.rest);
                    defer rres.deinit(ctx.allocator);
                    if (!rres.matched()) return .initFail(input);
                    return .initOk(lres.tok.ok, rres.rest);
                }
            };
            return shim.leftParser;
        }

        test left {
            const parseLeft = left(
                lit(.FOO, "Foo"),
                lit(.BAR, "Bar"),
            );

            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.FOO, "Foo"), "Baz"),
                try parseLeft(&ctx, "FooBarBaz"),
            );

            try checkAndConsume(
                ctx,
                .initFail("FooBaz"),
                try parseLeft(&ctx, "FooBaz"),
            );

            try checkAndConsume(
                ctx,
                .initFail("BarFoo"),
                try parseLeft(&ctx, "BarFoo"),
            );
        }

        pub fn right(lp: Parser, rp: Parser) Parser {
            const shim = struct {
                fn rightParser(ctx: *Context, input: []const u8) ZpcError!Result {
                    const lres = try lp(ctx, input);
                    defer lres.deinit(ctx.allocator);
                    if (!lres.matched()) return .initFail(input);
                    const rres = try rp(ctx, lres.rest);
                    if (!rres.matched()) return .initFail(input);
                    return rres;
                }
            };
            return shim.rightParser;
        }

        test right {
            const parseRight = right(
                lit(.FOO, "Foo"),
                lit(.BAR, "Bar"),
            );

            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.BAR, "Bar"), "Baz"),
                try parseRight(&ctx, "FooBarBaz"),
            );

            try checkAndConsume(
                ctx,
                .initFail("FooBaz"),
                try parseRight(&ctx, "FooBaz"),
            );

            try checkAndConsume(
                ctx,
                .initFail("BarFoo"),
                try parseRight(&ctx, "BarFoo"),
            );
        }
    };
}

test Zpc {
    _ = TZ;
}
