const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

const Tag = enum(u8) {
    NONE,
    NUMBER,
    MULDIV,
    OP,
    MUL,
    DIV,
    MOD,
    ADDSUB,
    ADD,
    SUB,
};

const Context = struct {
    allocator: Allocator,
    expr: *const zpc.ZpcParser(@This(), Tag),
};

const P = zpc.Zpc(Context, Tag);

const skipSpace = P.takeWhile(.NONE, .zeroOrMore, std.ascii.isWhitespace);

fn makeOpParser(tag: Tag, upParser: P.Parser, opParser: P.Parser) P.Parser {
    return P.lower(P.seq(tag, &.{ upParser, P.flat(
        P.many(.NONE, .zeroOrMore, P.seq(.OP, &.{
            P.right(skipSpace, opParser), upParser,
        })),
    ) }));
}

pub const Expr = fn () usize;

fn compileToken(token: P.Token) !Expr {
    switch (token.tag) {
        .NUMBER => {
            const int = std.fmt.parseInt(usize, token.value.slice, 10);
            const shim = struct {
                fn expr() usize {
                    return int;
                }
            };
            return shim.expr;
        },
        else => unreachable,
    }
}

fn makeExpressionParser() P.Parser {
    const intParser = P.takeWhile(.NUMBER, .oneOrMore, std.ascii.isDigit);

    const atomParser = P.right(skipSpace, P.alt(&.{
        P.between(P.literal("("), P.recurse("expr"), P.right(skipSpace, P.literal(")"))),
        P.span(.NUMBER, P.right(P.literal("-"), intParser)),
        intParser,
    }));

    const mulDivParser = makeOpParser(.MULDIV, atomParser, P.alt(&.{
        P.keyword(.MUL, "*"),
        P.keyword(.DIV, "/"),
        P.keyword(.MOD, "%"),
    }));

    const addSubParser = makeOpParser(.ADDSUB, mulDivParser, P.alt(&.{
        P.keyword(.ADD, "+"),
        P.keyword(.SUB, "-"),
    }));

    return addSubParser;
}

fn compile(expr: []const u8) !Expr {
    const ca = @import("comptime_allocator.zig");
    var buf: [1024]u8 = undefined;
    var pool: ca.Pool = .init(&buf);
    const allocator = ca.init(&pool);

    const exprParser = makeExpressionParser();
    const ctx: Context = .{ .allocator = allocator, .expr = exprParser };
    const res = try exprParser(ctx, expr);
    assert(res.matched());
    return try compileToken(res.tok);
}

pub fn main(init: std.process.Init) !void {
    const exprParser = makeExpressionParser();
    const ctx: Context = .{ .allocator = init.gpa, .expr = exprParser };

    const expressions: []const []const u8 = &.{
        "123",
        "-123",
        "(0)",
        "1 + 2 * 3 / (8 + 7)",
    };

    for (expressions) |path| {
        print("expr: {s}\n\n", .{path});
        const res = try exprParser(ctx, path);
        defer res.deinit(init.gpa);
        print("{f}\n", .{res});
    }

    // const expr = try compile(@embedFile("expr.txt"));
    // const value = expr();
    // print("value: {d}\n", .{value});
}
