const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Zpc = struct {
    pub const Value = union(enum) {
        nothing: void,
        slice: []const u8,
        list: []const Value,
    };

    pub const Result = struct {
        ok: bool,
        out: Value,
        rest: []const u8,
        err: ?[]const u8 = null,

        pub fn initOk(out: Value, rest: []const u8) Result {
            return .{
                .ok = true,
                .out = out,
                .rest = rest,
            };
        }

        pub fn initErr(rest: []const u8, err: []const u8) Result {
            return .{
                .ok = false,
                .out = .{ .nothing = {} },
                .rest = rest,
                .err = err,
            };
        }
    };

    pub const Error = error{OutOfMemory};

    pub const Parser = fn (alloc: Allocator, input: []const u8) Error!Result;
    pub const Mapper = fn (alloc: Allocator, result: Result) Error!Result;
    pub const Pred = fn (char: u8) bool;

    pub fn predAnd(comptime a: Pred, comptime b: Pred) Pred {
        const shim = struct {
            fn op(char: u8) bool {
                return a(char) and b(char);
            }
        };
        return shim.op;
    }

    pub fn predOr(comptime a: Pred, comptime b: Pred) Pred {
        const shim = struct {
            fn op(char: u8) bool {
                return a(char) or b(char);
            }
        };
        return shim.op;
    }

    pub fn predNot(comptime a: Pred) Pred {
        const shim = struct {
            fn op(char: u8) bool {
                return !a(char);
            }
        };
        return shim.op;
    }

    pub fn stringWithLabel(comptime str: []const u8, comptime err: ?[]const u8) Parser {
        const shim = struct {
            fn match(_: Allocator, input: []const u8) Error!Result {
                if (input.len < str.len)
                    return .initErr(input, err orelse "end of input");
                if (!std.mem.eql(u8, input[0..str.len], str))
                    return .initErr(input, err orelse "non match");
                return .initOk(.{ .slice = str }, input[str.len..]);
            }
        };
        return shim.match;
    }

    pub fn string(comptime str: []const u8) Parser {
        return stringWithLabel(str, null);
    }

    test string {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const hello = Zpc.string("Hello");
        try expectEqualDeep(
            Result.initOk(.{ .slice = "Hello" }, ", World"),
            hello(alloc, "Hello, World"),
        );

        try expectEqualDeep(
            Result.initErr("H", "end of input"),
            hello(alloc, "H"),
        );

        try expectEqualDeep(
            Result.initErr("Hell or bust", "non match"),
            hello(alloc, "Hell or bust"),
        );
    }

    // Succeeds if there is at least one character of input. Returns the parsed character.
    pub fn anyWithLabel(comptime err: ?[]const u8) Parser {
        const shim = struct {
            fn match(_: Allocator, input: []const u8) Error!Result {
                if (input.len == 0)
                    return .initErr(input, err orelse "end of input");
                return .initOk(.{ .slice = input[0..1] }, input[1..]);
            }
        };
        return shim.match;
    }

    pub fn any() Parser {
        return anyWithLabel(null);
    }

    test any {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const anything = Zpc.any();
        try expectEqualDeep(
            Result.initOk(.{ .slice = "H" }, "ello, World"),
            anything(alloc, "Hello, World"),
        );

        try expectEqualDeep(
            Result.initErr("", "end of input"),
            anything(alloc, ""),
        );
    }

    // Succeeds if the character is in the supplied string. Returns the parsed character.
    pub fn oneOfWithLabel(comptime chars: []const u8, comptime err: ?[]const u8) Parser {
        const shim = struct {
            fn match(_: Allocator, input: []const u8) Error!Result {
                if (input.len == 0)
                    return .initErr(input, err orelse "end of input");
                if (!std.mem.containsAtLeastScalar(u8, chars, input[0], 1))
                    return .initErr(input, err orelse "non match");
                return .initOk(.{ .slice = input[0..1] }, input[1..]);
            }
        };
        return shim.match;
    }

    pub fn oneOf(comptime chars: []const u8) Parser {
        return oneOfWithLabel(chars, null);
    }

    test oneOf {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const endLine = Zpc.oneOf("\n\r");
        try expectEqualDeep(
            Result.initOk(.{ .slice = "\n" }, "\r"),
            endLine(alloc, "\n\r"),
        );

        try expectEqualDeep(
            Result.initOk(.{ .slice = "\r" }, "\n"),
            endLine(alloc, "\r\n"),
        );

        try expectEqualDeep(
            Result.initErr("Hello", "non match"),
            endLine(alloc, "Hello"),
        );
    }

    // `alt` for "alternative" is the equivalent of Parsec `<|>`
    pub fn altWithLabel(comptime parsers: []const *const Parser, comptime err: ?[]const u8) Parser {
        const shim = struct {
            fn match(alloc: Allocator, input: []const u8) Error!Result {
                inline for (parsers) |parser| {
                    const res = try parser(alloc, input);
                    if (res.ok) return res;
                }
                return .initErr(input, err orelse "non match");
            }
        };
        return shim.match;
    }

    pub fn alt(comptime parsers: []const *const Parser) Parser {
        return altWithLabel(parsers, null);
    }

    test alt {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const fooOrHello = Zpc.alt(&.{ Zpc.string("Foo"), Zpc.string("Hello") });
        try expectEqualDeep(
            Result.initOk(.{ .slice = "Hello" }, ", World"),
            fooOrHello(alloc, "Hello, World"),
        );
        try expectEqualDeep(
            Result.initOk(.{ .slice = "Foo" }, "Bar"),
            fooOrHello(alloc, "FooBar"),
        );
        try expectEqualDeep(
            Result.initErr("Bar", "non match"),
            fooOrHello(alloc, "Bar"),
        );
    }

    // `right` is the equivalent of Haskell's Applicative right sequencing `*>`
    pub fn right(comptime parsers: []const *const Parser) Parser {
        assert(parsers.len != 0);
        const shim = struct {
            fn match(alloc: Allocator, input: []const u8) Error!Result {
                var tail = input;
                inline for (parsers, 0..) |parser, i| {
                    const res = try parser(alloc, tail);
                    if (!res.ok or i == parsers.len - 1) return res;
                    tail = res.rest;
                }
                unreachable;
            }
        };
        return shim.match;
    }

    test right {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const seq = Zpc.right(&.{ Zpc.string("A"), Zpc.string("B"), Zpc.string("C") });

        try expectEqualDeep(
            Result.initOk(.{ .slice = "C" }, "D"),
            seq(alloc, "ABCD"),
        );

        // TODO is it desirable that input before the match failure is lost
        // in this case?
        try expectEqualDeep(
            Result.initErr("ED", "non match"),
            seq(alloc, "ABED"),
        );
    }

    // `left` is the equivalent of Haskell's Applicative left sequencing `<*`
    pub fn left(comptime parsers: []const *const Parser) Parser {
        assert(parsers.len != 0);
        const shim = struct {
            fn match(alloc: Allocator, input: []const u8) Error!Result {
                const res1 = try parsers[0](alloc, input);
                if (!res1.ok) return res1;
                var tail = res1.rest;
                inline for (parsers[1..]) |parser| {
                    const res = try parser(alloc, tail);
                    if (!res.ok) return res;
                    tail = res.rest;
                }
                return .initOk(res1.out, tail);
            }
        };
        return shim.match;
    }

    test left {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const seq = Zpc.left(&.{ Zpc.string("A"), Zpc.string("B"), Zpc.string("C") });

        try expectEqualDeep(
            Result.initOk(.{ .slice = "A" }, "D"),
            seq(alloc, "ABCD"),
        );

        // TODO is it desirable that input before the match failure is lost
        // in this case?
        try expectEqualDeep(
            Result.initErr("ED", "non match"),
            seq(alloc, "ABED"),
        );
    }

    // `apply` is the equivalent of Haskell's Applicative sequential application
    pub fn apply(comptime parsers: []const *const Parser) Parser {
        const shim = struct {
            fn match(alloc: Allocator, input: []const u8) Error!Result {
                var list = try alloc.alloc(Value, parsers.len);
                errdefer alloc.free(list);

                var tail = input;
                inline for (parsers, 0..) |parser, i| {
                    const res = try parser(alloc, tail);
                    if (!res.ok) {
                        alloc.free(list);
                        return res;
                    }
                    list[i] = res.out;
                    tail = res.rest;
                }
                return .initOk(.{ .list = list }, tail);
            }
        };
        return shim.match;
    }

    test apply {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const seq = Zpc.apply(&.{ Zpc.string("A"), Zpc.string("B"), Zpc.string("C") });

        try expectEqualDeep(
            Result.initOk(.{ .list = &.{
                .{ .slice = "A" },
                .{ .slice = "B" },
                .{ .slice = "C" },
            } }, "D"),
            seq(alloc, "ABCD"),
        );

        // TODO is it desirable that input before the match failure is lost
        // in this case?
        try expectEqualDeep(
            Result.initErr("ED", "non match"),
            seq(alloc, "ABED"),
        );
    }

    pub fn map(comptime parser: Parser, comptime mapper: Mapper) Parser {
        const shim = struct {
            fn match(alloc: Allocator, input: []const u8) Error!Result {
                return try mapper(alloc, try parser(alloc, input));
            }
        };
        return shim.match;
    }

    test map {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const M = struct {
            fn mapper(_: Allocator, res: Result) Error!Result {
                if (res.ok) return .initErr(res.rest, "no problem");
                return res;
            }
        };

        const mapped = Zpc.map(Zpc.string("Hello"), M.mapper);

        try expectEqualDeep(
            Result.initErr(", World", "no problem"),
            mapped(alloc, "Hello, World"),
        );
    }

    pub fn takeWhileMinWithLabel(comptime pred: Pred, comptime min: usize, comptime err: ?[]const u8) Parser {
        const shim = struct {
            fn match(_: Allocator, input: []const u8) Error!Result {
                var pos: usize = 0;
                while (pos < input.len and pred(input[pos]))
                    pos += 1;

                if (pos < min) return .initErr(input, err orelse "too few");
                return .initOk(.{ .slice = input[0..pos] }, input[pos..]);
            }
        };
        return shim.match;
    }

    pub fn takeWhileMin(comptime pred: Pred, comptime min: usize) Parser {
        return takeWhileMinWithLabel(pred, min, null);
    }

    test takeWhileMin {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const digits = Zpc.takeWhileMin(std.ascii.isDigit, 1);
        try expectEqualDeep(
            Result.initOk(.{ .slice = "10" }, ".3"),
            digits(alloc, "10.3"),
        );

        try expectEqualDeep(
            Result.initErr("Hello", "too few"),
            digits(alloc, "Hello"),
        );
    }

    pub fn manyWithLabel(comptime parser: Parser, comptime min: usize, comptime err: ?[]const u8) Parser {
        const shim = struct {
            fn match(alloc: Allocator, input: []const u8) Error!Result {
                var list: std.ArrayList(Value) = .empty;
                errdefer list.deinit(alloc);
                var tail = input;
                while (true) {
                    const res = try parser(alloc, tail);
                    if (!res.ok) break;
                    if (res.rest.ptr == tail.ptr)
                        return .initErr(input, "no progress");
                    try list.append(alloc, res.out);
                    tail = res.rest;
                }

                if (list.items.len < min) {
                    list.deinit(alloc);
                    return .initErr(input, err orelse "too few");
                }

                return .initOk(.{ .list = try list.toOwnedSlice(alloc) }, tail);
            }
        };
        return shim.match;
    }

    pub fn many(comptime parser: Parser, comptime min: usize) Parser {
        return manyWithLabel(parser, min, null);
    }

    test many {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const zeroOrMore = Zpc.many(Zpc.string("ABC"), 0);
        try expectEqualDeep(
            Result.initOk(.{ .list = &.{} }, ""),
            try zeroOrMore(alloc, ""),
        );

        try expectEqualDeep(
            Result.initOk(.{ .list = &.{
                .{ .slice = "ABC" },
                .{ .slice = "ABC" },
                .{ .slice = "ABC" },
            } }, ""),
            try zeroOrMore(alloc, "ABCABCABC"),
        );
    }

    pub fn manyTill(comptime parser: Parser, comptime end_parser: Parser) Parser {
        const shim = struct {
            fn match(alloc: Allocator, input: []const u8) Error!Result {
                var list: std.ArrayList(Value) = .empty;
                errdefer list.deinit(alloc);
                var tail = input;
                while (true) {
                    const end_res = try end_parser(alloc, tail);
                    if (end_res.ok)
                        return .initOk(.{ .list = try list.toOwnedSlice(alloc) }, end_res.rest);

                    const res = try parser(alloc, tail);
                    if (!res.ok) {
                        list.deinit(alloc);
                        return res;
                    }
                    if (res.rest.ptr == tail.ptr)
                        return .initErr(input, "no progress");
                    try list.append(alloc, res.out);
                    tail = res.rest;
                }
            }
        };
        return shim.match;
    }

    test manyTill {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const aNotAb = Zpc.manyTill(Zpc.string("A"), Zpc.string("AB"));

        try expectEqualDeep(
            Result.initOk(.{ .list = &.{
                .{ .slice = "A" },
                .{ .slice = "A" },
                .{ .slice = "A" },
            } }, "C"),
            try aNotAb(alloc, "AAAABC"),
        );
    }

    pub fn sepBy(
        comptime item_parser: Parser,
        comptime sep_parser: Parser,
        comptime allow_first_fail: bool,
    ) Parser {
        const shim = struct {
            fn match(alloc: Allocator, input: []const u8) Error!Result {
                const first = try item_parser(alloc, input);
                if (!first.ok)
                    return if (allow_first_fail)
                        .initOk(.{ .list = &.{} }, input)
                    else
                        .initErr(input, "too few");

                var list: std.ArrayList(Value) = .empty;
                errdefer list.deinit(alloc);

                var tail = input;
                while (true) {
                    const sep_res = try sep_parser(alloc, tail);
                    if (!sep_res.ok)
                        return .initOk(.{ .list = try list.toOwnedSlice(alloc) }, tail);

                    const item_res = try item_parser(alloc, sep_res.rest);
                    if (!item_res.ok)
                        return .initOk(.{ .list = try list.toOwnedSlice(alloc) }, tail);

                    try list.append(alloc, item_res.out);
                    tail = item_res.rest;
                }
            }
        };
        return shim.match;
    }

    test sepBy {}

    pub fn match(comptime parser: Parser) Parser {
        const shim = struct {
            fn match(alloc: Allocator, input: []const u8) Error!Result {
                var arena = std.heap.ArenaAllocator.init(alloc);
                defer arena.deinit();
                const res = try parser(arena.allocator(), input);
                if (!res.ok) return res;
                const consumed: usize = @intFromPtr(res.rest.ptr) - @intFromPtr(input.ptr);
                return .initOk(.{ .slice = input[0..consumed] }, res.rest);
            }
        };
        return shim.match;
    }

    test match {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const aNotAb = Zpc.manyTill(Zpc.string("A"), Zpc.string("AB"));
        const peek = Zpc.match(aNotAb);

        try expectEqualDeep(
            Result.initOk(.{ .slice = "AAAAB" }, "C"),
            try peek(alloc, "AAAABC"),
        );
    }
};

const number = Zpc.takeWhileMin(std.ascii.isDigit, 1);
// const whitespace = Zpc.takeWhileMin(std.ascii.isWhitespace, 0);
// const oper = Zpc.alt(&.{Zpc.string("+"), Zpc.string("-")});
const nested = Zpc.right(&.{ Zpc.string("("), Zpc.left(&.{ expr, Zpc.string(")") }) });
const expr = Zpc.alt(&.{ number, nested });

test Zpc {
    _ = number;
    // _ = expr;
    _ = @import("zpc.zig");
}

pub fn main() void {
    print("Hello, World\n", .{});
}
