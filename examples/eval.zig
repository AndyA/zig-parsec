const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

pub fn KnownRange(T: type) type {
    return struct {
        const Self = @This();
        pub const empty = .{ std.math.minInt(T), std.math.maxInt(T) };

        min: T,
        max: T,

        pub fn init(min: T, max: T) Self {
            .{ .min = min, .max = max };
        }

        pub fn initExact(value: T) Self {
            return .init(value, value);
        }

        pub fn combine(self: Self, other: Self) Self {
            const min = @max(self.unsigned_range.@"0", other.unsigned_range.@"0");
            const max = @min(self.unsigned_range.@"0", other.unsigned_range.@"0");
            assert(min <= max);
            return .init(min, max);
        }
    };
}

pub fn KnownBits(T: type) type {
    const U = @Int(.unsigned, @typeInfo(T).int.bits);
    // const S = @Int(.signed, @typeInfo(T).int.bits);

    return struct {
        const Self = @This();
        pub const empty = .{ .set = 0, .clear = 0 };

        set: U,
        clear: U,

        pub fn init(set: U, clear: U) Self {
            .{ .set = set, .clear = clear };
        }

        pub fn initExact(value: U) Self {
            return .init(value, ~value);
        }

        pub fn combine(self: Self, other: Self) Self {
            const set = self.set | other.set;
            const clear = self.clear | other.clear;
            assert(set & clear == 0);
            return .init(set, clear);
        }

        pub fn unsignedRange(self: Self) KnownRange(U) {
            assert(self.set & self.clear == 0);
            const unknown = ~(self.set | self.clear);
            const hi_known = @clz(unknown);
            const hi_mask = std.math.maxInt(U) >> hi_known;
            const hi_bits = self.set & ~hi_mask;

            const hi_range: KnownRange(U) = .init(
                hi_bits,
                hi_bits | hi_mask,
            );

            const lo_known = @ctz(unknown);
            const lo_mask = (@as(U, 1) << lo_known) - 1;
            const lo_bits = self.set & lo_mask;

            const lo_range: KnownRange(U) = .init(
                lo_bits,
                std.math.maxInt(U) & ~lo_mask | lo_bits,
            );

            return lo_range.combine(hi_range);
        }
    };
}

pub fn KnownDomain(T: type) type {
    const U = @Int(.unsigned, @typeInfo(T).int.bits);
    const S = @Int(.signed, @typeInfo(T).int.bits);

    return struct {
        const Self = @This();
        pub const empty = .{};

        unsigned_range: KnownRange(U) = .empty,
        signed_range: KnownRange(S) = .empty,
        bits: KnownBits(U) = .empty,

        pub fn initUnsignedRange(range: KnownRange(U)) Self {
            return .{ .unsigned_range = range };
        }

        pub fn initSignedRange(range: KnownRange(S)) Self {
            return .{ .signed_range = range };
        }

        pub fn initBits(bits: KnownBits(U)) Self {
            return .{ .bits = bits };
        }

        pub fn initExact(value: T) Self {
            return .{
                .unsigned_range = if (T == U) .initUnsignedExact(value) else .empty,
                .signed_range = if (T == S) .initSignedExact(value) else .empty,
                .bits = .initExact(@as(U, @bitCast(value))),
            };
        }

        pub fn combine(self: Self, other: Self) Self {
            return .{
                .unsigned_range = self.unsigned_range.combine(other.unsigned_range),
                .signed_range = self.signed_range.combine(other.signed_range),
                .bits = self.bits.combine(other.bits),
            };
        }
    };
}

const Tag = enum(u8) {
    N, // means don't care - but `N` is shorter
    INT,
    UNOPS,
    UNOP,
    BINOPS,
    BINOP,
    NEG,
    FLIP,
    NOT,
    MUL,
    DIV,
    MOD,
    ADD,
    SUB,
    LT,
    LTE,
    GT,
    GTE,
    EQ,
    NE,
};

const Context = struct {
    allocator: Allocator,
    expr: *const zpc.ZpcParser(@This(), Tag),
};

const P = zpc.Zpc(Context, Tag);

const skipSpace = P.takeWhile(.N, .zeroOrMore, std.ascii.isWhitespace);

fn makeBinOpParser(valueParser: P.Parser, opParser: P.Parser) P.Parser {
    return P.lower(P.seq(.BINOPS, &.{ valueParser, P.flat(
        P.many(.N, .zeroOrMore, P.seq(.BINOP, &.{
            P.right(skipSpace, opParser), valueParser,
        })),
    ) }));
}

fn makeExpressionParser() P.Parser {
    const intParser = P.takeWhile(.INT, .oneOrMore, std.ascii.isDigit);

    const atomParser = P.right(skipSpace, P.alt(&.{
        P.between(P.literal("("), P.recurse("expr"), P.right(skipSpace, P.literal(")"))),
        intParser,
    }));

    const unaryParser = P.alt(&.{
        P.seq(.UNOP, &.{
            P.many(.UNOPS, .oneOrMore, P.right(skipSpace, P.alt(&.{
                P.keyword(.NEG, "-"),
                P.keyword(.FLIP, "~"),
                P.keyword(.NOT, "!"),
            }))),
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

    const cmpParser = makeBinOpParser(addSubParser, P.alt(&.{
        P.keyword(.NE, "!="),
        P.keyword(.NE, "<>"),
        P.keyword(.LTE, "<="),
        P.keyword(.GTE, ">="),
        P.keyword(.LT, "<"),
        P.keyword(.GT, ">"),
        P.keyword(.EQ, "=="),
        P.keyword(.EQ, "="),
    }));

    return cmpParser;
}

fn boolInt(b: bool) i64 {
    return if (b) 1 else 0;
}

fn eval(token: P.Token) !i64 {
    return eval: switch (token.tag) {
        .INT => try std.fmt.parseInt(i64, token.value.slice, 10),
        .UNOP => {
            var res = try eval(token.other());
            const head = token.head();
            assert(head.tag == .UNOPS);
            const kids = head.children();
            for (0..kids.len) |i|
                res = switch (kids[kids.len - 1 - i].tag) {
                    .NEG => -res,
                    .FLIP => ~res,
                    .NOT => if (res != 0) 0 else 1,
                    else => unreachable,
                };
            break :eval res;
        },
        .BINOPS => {
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
                    .LTE => boolInt(res <= rhs),
                    .LT => boolInt(res < rhs),
                    .GTE => boolInt(res > rhs),
                    .GT => boolInt(res > rhs),
                    .EQ => boolInt(res == rhs),
                    .NE => boolInt(res != rhs),
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
        "!(3 < 3 + 2)",
    };

    for (expressions) |path| {
        print("expr: {s}\n\n", .{path});
        const res = try fullParser(ctx, path);
        defer res.deinit(init.gpa);
        print("{f}\n", .{res});
        if (res.matched())
            print("result: {d}\n\n", .{try eval(res.tok.ok)});
    }
}
