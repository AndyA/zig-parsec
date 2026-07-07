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
    OPCHAIN,
    OP,
    MUL,
    DIV,
    MOD,
    ADD,
    SUB,
};

const Context = struct {
    allocator: Allocator,
    expr: *const zpc.ZpcParser(@This(), Tag),
};

const P = zpc.Zpc(Context, Tag);

const skipSpace = P.takeWhile(.NONE, .zeroOrMore, std.ascii.isWhitespace);

fn makeOpParser(upParser: P.Parser, opParser: P.Parser) P.Parser {
    return P.lower(P.seq(.OPCHAIN, &.{ upParser, P.flat(
        P.many(.NONE, .zeroOrMore, P.seq(.OP, &.{
            P.right(skipSpace, opParser), upParser,
        })),
    ) }));
}

fn makeExpressionParser() P.Parser {
    const intParser = P.takeWhile(.NUMBER, .oneOrMore, std.ascii.isDigit);

    const atomParser = P.right(skipSpace, P.alt(&.{
        P.between(P.literal("("), P.recurse("expr"), P.right(skipSpace, P.literal(")"))),
        P.span(.NUMBER, P.right(P.literal("-"), intParser)),
        intParser,
    }));

    const mulDivParser = makeOpParser(atomParser, P.alt(&.{
        P.keyword(.MUL, "*"),
        P.keyword(.DIV, "/"),
        P.keyword(.MOD, "%"),
    }));

    const addSubParser = makeOpParser(mulDivParser, P.alt(&.{
        P.keyword(.ADD, "+"),
        P.keyword(.SUB, "-"),
    }));

    return addSubParser;
}

fn eval(token: P.Token) !i64 {
    return eval: switch (token.tag) {
        .NUMBER => try std.fmt.parseInt(i64, token.value.slice, 10),
        .OPCHAIN => {
            var res = try eval(token.head());
            for (token.tail()) |op| {
                assert(op.tag == .OP);
                const rhs = try eval(op.other());
                res = switch (op.head().tag) {
                    .ADD => res + rhs,
                    .SUB => res - rhs,
                    .MUL => res * rhs,
                    .DIV => @divTrunc(res, rhs),
                    .MOD => @mod(res, rhs),
                    else => unreachable,
                };
            }
            break :eval res;
        },
        else => unreachable,
    };
}

pub fn main(init: std.process.Init) !void {
    const exprParser = makeExpressionParser();
    const ctx: Context = .{ .allocator = init.gpa, .expr = exprParser };

    const expressions: []const []const u8 = &.{
        "(100 + 2 - 9) / 3 + 11",
    };

    for (expressions) |path| {
        print("expr: {s}\n\n", .{path});
        const res = try exprParser(ctx, path);
        defer res.deinit(init.gpa);
        print("{f}\n", .{res});
        if (res.matched())
            print("result: {d}\n", .{try eval(res.tok.ok)});
    }

    // const expr = try compile(@embedFile("expr.txt"));
    // const value = expr();
    // print("value: {d}\n", .{value});
}
