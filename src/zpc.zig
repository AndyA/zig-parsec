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
        pub const ArrayList = std.ArrayList(Self);
        pub const NOP: Tag = @enumFromInt(0);

        pub const nothing: Self = .{ .tag = NOP, .value = .{ .nothing = {} } };

        tag: Tag = NOP,
        value: union(enum) {
            nothing: void,
            slice: []const u8,
            list: []const Self,
        },

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            try writer.print("{s} {s}", .{ @tagName(self.tag), @tagName(self.value) });
            switch (self.value) {
                .nothing => {},
                .slice => |slice| try writer.print(" \"{s}\"", .{slice}),
                .list => |list| {
                    try writer.print("({d}|", .{list.len});
                    for (list) |item| try writer.print(" {f}", .{item});
                    try writer.print(" )", .{});
                },
            }
        }

        pub fn initSlice(tag: Tag, slice: []const u8) Self {
            return .{ .tag = tag, .value = .{ .slice = slice } };
        }

        pub fn initList(tag: Tag, list: []const Self) Self {
            return .{ .tag = tag, .value = .{ .list = list } };
        }

        pub fn initArrayList(alloc: Allocator, tag: Tag, array: *ArrayList) ZpcError!Self {
            const list = try array.toOwnedSlice(alloc);
            return initList(tag, list);
        }

        pub fn isNothing(self: Self) bool {
            return self.value == .nothing;
        }

        pub fn appendArrayList(self: Self, alloc: Allocator, array: *ArrayList) ZpcError!void {
            if (!self.isNothing()) try array.append(alloc, self);
        }

        pub fn appendArrayListAssumeCapacity(self: Self, array: *ArrayList) void {
            if (!self.isNothing()) array.appendAssumeCapacity(self);
        }

        pub fn deinit(self: Self, alloc: Allocator) void {
            switch (self.value) {
                .list => |list| deinitList(list, alloc),
                else => {},
            }
        }

        pub fn deinitList(list: []const Self, alloc: Allocator) void {
            for (list) |item| item.deinit(alloc);
            alloc.free(list);
        }

        pub fn deinitArrayList(list: *ArrayList, alloc: Allocator) void {
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

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            switch (self.tok) {
                .ok => |ok| try writer.print("{f}", .{ok}),
                .fail => try writer.print("FAIL", .{}),
            }
            if (self.rest.len > 10)
                try writer.print(" rest: \"{s}...\"", .{self.rest[0..10]})
            else
                try writer.print(" rest: \"{s}\"", .{self.rest});
        }

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

const TestTag = enum {
    NOP,
    HELLO,
    FOO,
    BAR,
    NEWLINE,
    DIGIT,
    ALPHA,
    MULTI,
    PLUS,
    MINUS,
    OPEN,
    CLOSE,
    SEQ,
    NEST,
    TERM,
    MANY,
};

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

pub const Predicate = fn (char: u8) bool;

pub fn predAnd(a: Predicate, b: Predicate) Predicate {
    const shim = struct {
        fn pred(char: u8) bool {
            return a(char) and b(char);
        }
    };
    return shim.pred;
}

pub fn predOr(a: Predicate, b: Predicate) Predicate {
    const shim = struct {
        fn pred(char: u8) bool {
            return a(char) or b(char);
        }
    };
    return shim.pred;
}

pub fn predNot(p: Predicate) Predicate {
    const shim = struct {
        fn pred(char: u8) bool {
            return !p(char);
        }
    };
    return shim.pred;
}

pub fn predEqual(want: u8) Predicate {
    const shim = struct {
        fn pred(char: u8) bool {
            return char == want;
        }
    };
    return shim.pred;
}

pub fn predSet(charset: []const u8) Predicate {
    const shim = struct {
        fn pred(char: u8) bool {
            return std.mem.containsAtLeastScalar(u8, charset, char, 1);
        }
    };
    return shim.pred;
}

pub fn Zpc(comptime Context: type, comptime Tag: type) type {
    assert(@hasField(Context, "allocator"));
    return struct {
        pub const Token = ZpcToken(Tag);
        pub const Result = ZpcResult(Tag);
        pub const Parser = ZpcParser(Context, Tag);
        pub const Mapper = fn (ctx: *Context, result: Result) ZpcError!Result;

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

        pub fn always() Parser {
            const shim = struct {
                fn alwaysParser(_: *Context, input: []const u8) ZpcError!Result {
                    return .initOk(.nothing, input);
                }
            };
            return shim.alwaysParser;
        }

        test always {
            const parseAlways = always();
            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.nothing, "Hello, World"),
                try parseAlways(&ctx, "Hello, World"),
            );
        }

        pub fn oneIs(tag: Tag, pred: Predicate) Parser {
            const shim = struct {
                fn oneIsParser(_: *Context, input: []const u8) ZpcError!Result {
                    if (input.len > 0 and pred(input[0]))
                        return .initOk(.initSlice(tag, input[0..1]), input[1..]);
                    return .initFail(input);
                }
            };
            return shim.oneIsParser;
        }

        test oneIs {
            const parseDigit = oneIs(.DIGIT, std.ascii.isDigit);
            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.DIGIT, "6"), "7"),
                try parseDigit(&ctx, "67"),
            );

            try checkAndConsume(
                ctx,
                .initFail(""),
                try parseDigit(&ctx, ""),
            );

            try checkAndConsume(
                ctx,
                .initFail("X"),
                try parseDigit(&ctx, "X"),
            );
        }

        pub fn someAre(tag: Tag, pred: Predicate, min: usize) Parser {
            const shim = struct {
                fn someAreParser(_: *Context, input: []const u8) ZpcError!Result {
                    var pos: usize = 0;
                    while (pos < input.len and pred(input[pos]))
                        pos += 1;
                    if (pos < min)
                        return .initFail(input);
                    return .initOk(.initSlice(tag, input[0..pos]), input[pos..]);
                }
            };
            return shim.someAreParser;
        }

        test someAre {
            const parseDigits = someAre(.DIGIT, std.ascii.isDigit, 1);
            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.DIGIT, "67"), "b"),
                try parseDigits(&ctx, "67b"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.DIGIT, "67"), ""),
                try parseDigits(&ctx, "67"),
            );

            try checkAndConsume(
                ctx,
                .initFail("X"),
                try parseDigits(&ctx, "X"),
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

        pub fn seq(tag: Tag, parsers: []const *const Parser) Parser {
            const shim = struct {
                fn seqParser(ctx: *Context, input: []const u8) ZpcError!Result {
                    var list: Token.ArrayList = try .initCapacity(ctx.allocator, parsers.len);
                    errdefer Token.deinitArrayList(&list, ctx.allocator);
                    var tail = input;
                    inline for (parsers) |parser| {
                        const res = try parser(ctx, tail);
                        if (!res.matched()) {
                            Token.deinitArrayList(&list, ctx.allocator);
                            return .initFail(input);
                        }
                        res.tok.ok.appendArrayListAssumeCapacity(&list);
                        tail = res.rest;
                    }

                    return .initOk(try .initArrayList(ctx.allocator, tag, &list), tail);
                }
            };
            return shim.seqParser;
        }

        test seq {
            const parseAlphaNum = seq(.MULTI, &.{
                someAre(.DIGIT, std.ascii.isDigit, 1),
                someAre(.ALPHA, std.ascii.isAlphabetic, 1),
            });
            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initList(.MULTI, &.{
                    .initSlice(.DIGIT, "123"),
                    .initSlice(.ALPHA, "ABC"),
                }), "."),

                try parseAlphaNum(&ctx, "123ABC."),
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

        pub const ManyOptions = struct {
            min: usize = 0,
            max: usize = std.math.maxInt(usize),
        };

        pub fn many(tag: Tag, parser: Parser, options: ManyOptions) Parser {
            assert(options.min <= options.max);
            const shim = struct {
                fn manyParser(ctx: *Context, input: []const u8) ZpcError!Result {
                    var list: Token.ArrayList = .empty;
                    errdefer Token.deinitArrayList(&list, ctx.allocator);
                    var tail = input;
                    while (true) {
                        if (list.items.len >= options.max) break;
                        const res = try parser(ctx, tail);
                        if (!res.matched()) break;
                        try res.tok.ok.appendArrayList(ctx.allocator, &list);
                        tail = res.rest;
                    }

                    if (list.items.len < options.min) {
                        Token.deinitArrayList(&list, ctx.allocator);
                        return .initFail(input);
                    }

                    return .initOk(try .initArrayList(ctx.allocator, tag, &list), tail);
                }
            };
            return shim.manyParser;
        }

        test many {
            const parseFooBar = many(
                .MULTI,
                alt(&.{ lit(.FOO, "Foo"), lit(.BAR, "Bar") }),
                .{ .min = 2, .max = 3 },
            );
            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initList(.MULTI, &.{
                    .initSlice(.FOO, "Foo"),
                    .initSlice(.FOO, "Foo"),
                    .initSlice(.BAR, "Bar"),
                }), "Baz"),
                try parseFooBar(&ctx, "FooFooBarBaz"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initList(.MULTI, &.{
                    .initSlice(.FOO, "Foo"),
                    .initSlice(.FOO, "Foo"),
                    .initSlice(.BAR, "Bar"),
                }), "BarBaz"),
                try parseFooBar(&ctx, "FooFooBarBarBaz"),
            );

            // We need two or more so a single Foo shouldn't be consumed.
            try checkAndConsume(
                ctx,
                .initFail("Foo"),
                try parseFooBar(&ctx, "Foo"),
            );
        }

        pub fn optional(parser: Parser) Parser {
            const shim = struct {
                fn optionalParser(ctx: *Context, input: []const u8) ZpcError!Result {
                    const res = try parser(ctx, input);
                    if (res.matched()) return res;
                    return .initOk(.nothing, input);
                }
            };
            return shim.optionalParser;
        }

        test optional {
            const parseMaybeNumber = optional(someAre(.DIGIT, std.ascii.isDigit, 1));
            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.DIGIT, "123"), "Foo"),
                try parseMaybeNumber(&ctx, "123Foo"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.nothing, "Foo"),
                try parseMaybeNumber(&ctx, "Foo"),
            );
        }

        pub fn discard(parser: Parser) Parser {
            const shim = struct {
                fn discardParser(ctx: *Context, input: []const u8) ZpcError!Result {
                    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
                    defer arena.deinit();
                    var tmp_ctx: Context = ctx.*;
                    tmp_ctx.allocator = arena.allocator();
                    const res = try parser(&tmp_ctx, input);
                    return if (res.matched())
                        .initOk(.nothing, res.rest)
                    else
                        .initFail(input);
                }
            };
            return shim.discardParser;
        }

        test discard {
            const parseHello = discard(lit(.HELLO, "Hello"));

            var ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.nothing, ", World"),
                try parseHello(&ctx, "Hello, World"),
            );

            try checkAndConsume(
                ctx,
                .initFail("H"),
                try parseHello(&ctx, "H"),
            );
        }

        pub fn match(tag: Tag, parser: Parser) Parser {
            const shim = struct {
                fn matchParser(ctx: *Context, input: []const u8) ZpcError!Result {
                    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
                    defer arena.deinit();
                    var tmp_ctx: Context = ctx.*;
                    tmp_ctx.allocator = arena.allocator();
                    const res = try parser(&tmp_ctx, input);
                    if (!res.matched()) return .initFail(input);
                    if (res.matched()) {
                        const consumed: usize = @intFromPtr(res.rest.ptr) - @intFromPtr(input.ptr);
                        return .initOk(.initSlice(tag, input[0..consumed]), res.rest);
                    }
                    return .initFail(input);
                }
            };
            return shim.matchParser;
        }

        // Call a parser that is pointed to by a field on the context.
        pub fn recurse(field_name: []const u8) Parser {
            const shim = struct {
                fn match(ctx: *Context, input: []const u8) ZpcError!Result {
                    const parser = @field(ctx, field_name);
                    return parser(ctx, input);
                }
            };
            return shim.match;
        }

        test recurse {
            const parseDigits = someAre(.DIGIT, std.ascii.isDigit, 1);

            const parseAtom = alt(&.{
                seq(.NEST, &.{ discard(lit(.OPEN, "(")), recurse("expr"), discard(lit(.CLOSE, ")")) }),
                parseDigits,
            });

            const parseTerm =
                seq(.TERM, &.{
                    parseAtom,
                    many(.MANY, seq(.SEQ, &.{
                        alt(&.{ lit(.PLUS, "+"), lit(.MINUS, "-") }),
                        parseAtom,
                    }), .{}),
                });

            const parseExpr = parseTerm;

            var ctx: TestContext = .{
                .allocator = std.testing.allocator,
                .expr = parseExpr,
            };

            try checkAndConsume(
                ctx,
                .initOk(.initList(.TERM, &.{
                    .initSlice(.DIGIT, "123"),
                    .initList(.MANY, &.{}),
                }), ";"),
                try parseExpr(&ctx, "123;"),
            );

            const want: Result = .initOk(.initList(.TERM, &.{
                .initList(.NEST, &.{
                    .initList(.TERM, &.{
                        .initSlice(.DIGIT, "123"),
                        .initList(.MANY, &.{
                            .initList(.SEQ, &.{
                                .initSlice(.PLUS, "+"),
                                .initSlice(.DIGIT, "7"),
                            }),
                        }),
                    }),
                }),
                .initList(.MANY, &.{
                    .initList(.SEQ, &.{
                        .initSlice(.MINUS, "-"),
                        .initSlice(.DIGIT, "2"),
                    }),
                    .initList(.SEQ, &.{
                        .initSlice(.PLUS, "+"),
                        .initSlice(.DIGIT, "700"),
                    }),
                }),
            }), ";");

            const expr = "(123+7)-2+700;";

            if (false) {
                const res = try parseExpr(&ctx, expr);
                defer res.deinit(std.testing.allocator);
                print("want: {f}\n", .{want});
                print("res:  {f}\n", .{res});
            }

            try checkAndConsume(ctx, want, try parseExpr(&ctx, expr));
        }
    };
}

test Zpc {
    _ = TZ;
}
