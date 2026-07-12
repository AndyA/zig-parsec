const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

pub fn KnownRange(T: type) type {
    const Bits = @typeInfo(T).int.bits;
    const Shift = @Int(.unsigned, std.math.log2_int(u16, Bits));

    const U = @Int(.unsigned, Bits);
    const S = @Int(.signed, Bits);

    return struct {
        const Self = @This();
        pub const empty: Self = .{ .min = std.math.minInt(T), .max = std.math.maxInt(T) };

        min: T,
        max: T,

        pub fn init(min: T, max: T) Self {
            assert(min <= max);
            return .{ .min = min, .max = max };
        }

        pub fn initExact(value: T) Self {
            return .init(value, value);
        }

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            try writer.print("[{d}, {d})", .{ self.min, self.max });
        }

        pub fn isExact(self: Self) bool {
            assert(self.min <= self.max);
            return self.min == self.max;
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.min == other.min and self.max == other.max;
        }

        pub fn combine(self: Self, other: Self) Self {
            assert(self.min <= self.max);
            assert(other.min <= other.max);
            const min = @max(self.min, other.min);
            const max = @min(self.max, other.max);
            assert(min <= max);
            return .init(min, max);
        }

        pub fn toBits(self: Self) KnownBits(U) {
            const uself = self.toUnsignedRange();
            if (uself.isExact())
                return .initExact(uself.min);
            const common = @clz(uself.min ^ uself.max);
            assert(common < Bits);
            const mask: U = ~(@as(U, std.math.maxInt(U)) >> @as(Shift, @intCast(common)));
            return .init(uself.min & mask, ~uself.min & mask);
        }

        pub fn toUnsignedRange(self: Self) KnownRange(U) {
            assert(self.min <= self.max);
            return blk: switch (@typeInfo(T).int.signedness) {
                .unsigned => self,
                .signed => {
                    const a: U = @bitCast(self.min);
                    const b: U = @bitCast(self.max);
                    break :blk .init(@min(a, b), @max(a, b));
                },
            };
        }

        pub fn toSignedRange(self: Self) KnownRange(S) {
            assert(self.min <= self.max);
            return blk: switch (@typeInfo(T).int.signedness) {
                .unsigned => {
                    const a: S = @bitCast(self.min);
                    const b: S = @bitCast(self.max);
                    break :blk .init(@min(a, b), @max(a, b));
                },
                .signed => self,
            };
        }
    };
}

test KnownRange {
    const KR = KnownRange(u32);
    try expectEqualDeep(KR.init(4, 5), KR.init(3, 5).combine(KR.init(4, 8)));
}

pub fn KnownBits(T: type) type {
    const Bits = @typeInfo(T).int.bits;
    const Shift = @Int(.unsigned, std.math.log2_int(u16, Bits));
    const U = @Int(.unsigned, Bits);
    const S = @Int(.signed, Bits);

    return struct {
        const Self = @This();
        pub const empty: Self = .{ .set = 0, .clear = 0 };

        set: U,
        clear: U,

        pub fn init(set: U, clear: U) Self {
            return .{ .set = set, .clear = clear };
        }

        pub fn initExact(value: U) Self {
            return .init(value, ~value);
        }
        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            var buf: [Bits]u8 = undefined;
            for (0..Bits) |bit| {
                const mask: U = @as(U, 1) << @as(Shift, @intCast(Bits - bit - 1));
                const set = (self.set & mask) != 0;
                const clear = (self.clear & mask) != 0;
                buf[bit] = if (set) '1' else if (clear) '0' else 'x';
            }
            _ = try writer.write(&buf);
        }

        pub fn isExact(self: Self) bool {
            assert(self.set & self.clear == 0);
            return self.set == ~self.clear;
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.set == other.set and self.clear == other.clear;
        }

        pub fn combine(self: Self, other: Self) Self {
            assert(self.set & self.clear == 0);
            assert(other.set & other.clear == 0);
            const set = self.set | other.set;
            const clear = self.clear | other.clear;
            assert(set & clear == 0);
            return .init(set, clear);
        }

        pub fn toUnsignedRange(self: Self) KnownRange(U) {
            assert(self.set & self.clear == 0);
            const unknown: U = ~(self.set | self.clear);

            const hi_known = @clz(unknown);
            if (hi_known == Bits)
                return .initExact(self.set);

            const hi_mask: U = @as(U, std.math.maxInt(U)) >> @as(Shift, @intCast(hi_known));
            const hi_bits = self.set & ~hi_mask;

            const hi_range: KnownRange(U) = .init(
                hi_bits,
                hi_bits | hi_mask,
            );

            const lo_known = @ctz(unknown);
            assert(lo_known != Bits);
            if (lo_known == 0)
                return hi_range;
            const lo_mask = (@as(U, 1) << @as(Shift, @intCast(lo_known - 1)));
            const lo_bits = self.set & lo_mask;

            const lo_range: KnownRange(U) = .init(
                lo_bits,
                std.math.maxInt(U) & ~lo_mask | lo_bits,
            );

            return lo_range.combine(hi_range);
        }

        pub fn toSignedRange(self: Self) KnownRange(S) {
            return self.toUnsignedRange().toSignedRange();
        }
    };
}

test KnownBits {
    try expectEqualDeep(
        KnownRange(u32).initExact(123),
        KnownBits(u32).initExact(123).toUnsignedRange(),
    );
}

pub fn KnownDomain(T: type) type {
    const U = @Int(.unsigned, @typeInfo(T).int.bits);
    const S = @Int(.signed, @typeInfo(T).int.bits);
    const KRU = KnownRange(U);
    const KRS = KnownRange(S);

    return struct {
        const Self = @This();
        pub const empty = .{};

        unsigned_range: KRU = .empty,
        signed_range: KRS = .empty,
        bits: KnownBits(U) = .empty,

        pub fn initUnsignedRange(range: KRU) Self {
            return .{ .unsigned_range = range };
        }

        pub fn initSignedRange(range: KRS) Self {
            return .{ .signed_range = range };
        }

        pub fn initBits(bits: KnownBits(U)) Self {
            return .{ .bits = bits };
        }

        pub fn initExact(value: T) Self {
            return switch (T) {
                U => .{
                    .unsigned_range = KRU.initExact(value),
                    .signed_range = KRU.initExact(value).toSignedRange(),
                    .bits = .initExact(@as(U, @bitCast(value))),
                },
                S => .{
                    .unsigned_range = KRS.initExact(value).toUnsignedRange(),
                    .signed_range = KRS.initExact(value),
                    .bits = .initExact(@as(U, @bitCast(value))),
                },
            };
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.unsigned_range.eql(other.unsigned_range) and
                self.signed_range.eql(other.signed_range) and
                self.bits.eql(other.bits);
        }

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            try writer.print(
                "ur: {f} sr: {f} bits: {f}",
                .{ self.unsigned_range, self.signed_range, self.bits },
            );
        }

        pub fn combine(self: Self, other: Self) Self {
            return .{
                .unsigned_range = self.unsigned_range.combine(other.unsigned_range),
                .signed_range = self.signed_range.combine(other.signed_range),
                .bits = self.bits.combine(other.bits),
            };
        }

        pub fn refine(self: Self) Self {
            var res = self;
            while (true) {
                const prev = res;
                res.bits = res.bits.combine(res.signed_range.toBits());
                res.bits = res.bits.combine(res.unsigned_range.toBits());
                res.signed_range = res.signed_range.combine(res.bits.toSignedRange());
                // res.signed_range = res.signed_range.combine(res.unsigned_range);
                res.unsigned_range = res.unsigned_range.combine(res.bits.toUnsignedRange());
                // res.unsigned_range = res.unsigned_range.combine(res.signed_range);
                if (prev.eql(res))
                    return res;
            }
        }
    };
}

test KnownDomain {
    const KD = KnownDomain(u32);
    const kd1: KD = .initUnsignedRange(.init(64, 127));
    print("kd1: {f}\n", .{kd1.refine()});
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
