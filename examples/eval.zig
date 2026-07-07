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
    UNOPCHAIN,
    UNOP,
    BINOPCHAIN,
    BINOP,
    NEG,
    NOT,
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

fn makeBinOpParser(upParser: P.Parser, opParser: P.Parser) P.Parser {
    return P.lower(P.seq(.BINOPCHAIN, &.{ upParser, P.flat(
        P.many(.NONE, .zeroOrMore, P.seq(.BINOP, &.{
            P.right(skipSpace, opParser), upParser,
        })),
    ) }));
}

fn makeExpressionParser() P.Parser {
    const intParser = P.takeWhile(.NUMBER, .oneOrMore, std.ascii.isDigit);

    const atomParser = P.right(skipSpace, P.alt(&.{
        P.between(P.literal("("), P.recurse("expr"), P.right(skipSpace, P.literal(")"))),
        intParser,
    }));

    const unaryParser = P.alt(&.{
        P.seq(.UNOP, &.{
            P.lower(P.many(.UNOPCHAIN, .oneOrMore, P.right(skipSpace, P.alt(&.{
                P.keyword(.NEG, "-"),
                P.keyword(.NOT, "~"),
            })))),
            atomParser,
        }),
        atomParser,
    });

    const mulDivParser = makeBinOpParser(unaryParser, P.alt(&.{
        P.keyword(.MUL, "*"),
        P.keyword(.DIV, "/"),
        P.keyword(.MOD, "%"),
    }));

    const addSubParser = makeBinOpParser(mulDivParser, P.alt(&.{
        P.keyword(.ADD, "+"),
        P.keyword(.SUB, "-"),
    }));

    return addSubParser;
}

fn evalUnary(tag: Tag, rhs: i64) !i64 {
    return switch (tag) {
        .NEG => -rhs,
        .NOT => ~rhs,
        else => unreachable,
    };
}

fn eval(token: P.Token) !i64 {
    return eval: switch (token.tag) {
        .NUMBER => try std.fmt.parseInt(i64, token.value.slice, 10),
        .UNOP => {
            const rhs = try eval(token.other());
            const head = token.head();
            break :eval op: switch (head.tag) {
                .UNOPCHAIN => {
                    var res = rhs;
                    const kids = head.children();
                    for (0..kids.len) |i| {
                        const idx = kids.len - 1 - i;
                        res = try evalUnary(kids[idx].tag, res);
                    }
                    break :op res;
                },
                else => |tag| evalUnary(tag, rhs),
            };
        },
        .BINOPCHAIN => {
            var res = try eval(token.head());
            for (token.tail()) |op| {
                assert(op.tag == .BINOP);
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
    const fullParser = P.left(exprParser, P.left(skipSpace, P.eof()));
    const ctx: Context = .{ .allocator = init.gpa, .expr = exprParser };

    const expressions: []const []const u8 = &.{
        "-1 + 3",
        "--(100 + 2 - 9) / 3 - ~10",
    };

    for (expressions) |path| {
        print("expr: {s}\n\n", .{path});
        const res = try fullParser(ctx, path);
        defer res.deinit(init.gpa);
        print("{f}\n", .{res});
        if (res.matched())
            print("result: {d}\n", .{try eval(res.tok.ok)});
    }
}
