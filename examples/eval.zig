const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

fn IntRep(T: type) type {
    return struct {
        pub const Bits = @typeInfo(T).int.bits;
        pub const U = @Int(.unsigned, Bits);
        pub const Shift = @Int(.unsigned, std.math.log2_int(u16, Bits));
        pub const BitCount = @Int(.unsigned, std.math.log2_int(u16, Bits) + 1);

        fn toUnsigned(value: T) U {
            return @bitCast(value);
        }

        fn fromUnsigned(value: U) T {
            return @bitCast(value);
        }
    };
}

pub fn KnownRange(T: type) type {
    const Rep = IntRep(T);

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
            try writer.print("{d}..{d}", .{ self.min, self.max });
        }

        pub fn isExact(self: Self) bool {
            assert(self.min <= self.max);
            return self.min == self.max;
        }

        pub fn eql(self: Self, other: Self) bool {
            assert(self.min <= self.max);
            return self.min == other.min and self.max == other.max;
        }

        pub fn narrow(self: Self, other: Self) Self {
            assert(self.min <= self.max);
            assert(other.min <= other.max);
            return .init(@max(self.min, other.min), @min(self.max, other.max));
        }

        pub fn widen(self: Self, other: Self) Self {
            assert(self.min <= self.max);
            assert(other.min <= other.max);
            return .init(@min(self.min, other.min), @max(self.max, other.max));
        }

        fn countLeadingSignBits(value: T) Rep.BitCount {
            const uv = @as(Rep.U, @bitCast(value));
            return (if (value < 0) @clz(~uv) else @clz(uv)) - 1;
        }

        pub fn toBits(self: Self) KnownBits(T) {
            assert(self.min <= self.max);
            if (self.isExact())
                return .initExact(self.min);
            const sign = if (T == Rep.U) 0 else @min(
                countLeadingSignBits(self.min),
                countLeadingSignBits(self.max),
            );
            print("{f}: sign={d}\n", .{ self, sign });
            const sign_mask = @as(Rep.U, std.math.maxInt(Rep.U)) >>
                @as(Rep.Shift, @intCast(sign));
            const u_min: Rep.U = @bitCast(self.min);
            const u_max: Rep.U = @bitCast(self.max);
            const same_msb = @clz((u_min & sign_mask) ^ (u_max & sign_mask));
            assert(same_msb < Rep.Bits);
            const mask: Rep.U = sign_mask & ~(@as(Rep.U, std.math.maxInt(Rep.U)) >>
                @as(Rep.Shift, @intCast(same_msb)));
            const bits: KnownBits(T) = .initSigned(u_min & mask, ~u_min & mask, sign);
            print("bits: {f}\n", .{bits});
            return bits;
        }
    };
}

test KnownRange {
    const KR = KnownRange(u32);
    try expectEqualDeep(KR.init(4, 5), KR.init(3, 5).narrow(KR.init(4, 8)));
}

pub fn KnownBits(T: type) type {
    const Rep = IntRep(T);

    return struct {
        const Self = @This();
        pub const empty: Self = .{ .set = 0, .clear = 0 };

        set: Rep.U,
        clear: Rep.U,
        sign: Rep.BitCount = 0,

        pub fn init(set: Rep.U, clear: Rep.U) Self {
            return .{ .set = set, .clear = clear };
        }

        pub fn initSigned(set: Rep.U, clear: Rep.U, sign: Rep.BitCount) Self {
            return .{ .set = set, .clear = clear, .sign = sign };
        }

        pub fn initExact(value: T) Self {
            const uv = Rep.toUnsigned(value);
            return .init(uv, ~uv);
        }

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            var buf: [Rep.Bits]u8 = undefined;
            const sign_mask = self.signMask();
            for (0..Rep.Bits) |bit| {
                const mask: Rep.U = @as(Rep.U, 1) << @as(Rep.Shift, @intCast(Rep.Bits - bit - 1));
                const sign = (sign_mask & mask) != 0;
                const set = (self.set & mask) != 0;
                const clear = (self.clear & mask) != 0;
                buf[bit] = if (sign) 's' else if (set) '1' else if (clear) '0' else 'x';
            }
            _ = try writer.write(&buf);
        }

        fn signMask(self: Self) Rep.U {
            assert(self.sign < Rep.Bits);
            return ~(@as(Rep.U, std.math.maxInt(Rep.U)) >>
                @as(Rep.Shift, @intCast(self.sign)));
        }

        fn assertValid(self: Self) void {
            assert(self.signMask() & self.set & self.clear == 0);
        }

        pub fn isExact(self: Self) bool {
            self.assertValid();
            return self.set == ~self.clear;
        }

        pub fn eql(self: Self, other: Self) bool {
            self.assertValid();
            other.assertValid();
            return self.set == other.set and self.clear == other.clear;
        }

        pub fn narrow(self: Self, other: Self) Self {
            self.assertValid();
            other.assertValid();
            const set = self.set | other.set;
            const clear = self.clear | other.clear;
            assert(set & clear == 0);
            return .init(set, clear);
        }

        pub fn widen(self: Self, other: Self) Self {
            self.assertValid();
            other.assertValid();
            const set = self.set & other.set;
            const clear = self.clear & other.clear;
            assert(set & clear == 0);
            return .init(set, clear);
        }

        fn toUnsignedRange(self: Self) KnownRange(Rep.U) {
            self.assertValid();

            if (self.isExact())
                return .initExact(self.set);

            const known = ~(self.set | self.clear);

            const known_msbs = @clz(known);
            assert(known_msbs < Rep.Bits);

            const left: KnownRange(Rep.U) = blk: {
                const mask = @as(Rep.U, std.math.maxInt(Rep.U)) >>
                    @as(Rep.Shift, @intCast(known_msbs));
                const min = self.set & ~mask;
                break :blk .init(min, min | mask);
            };

            const known_lsbs = @ctz(known);
            assert(known_lsbs + known_msbs < Rep.Bits);

            return blk: {
                const mask = @as(Rep.U, std.math.maxInt(Rep.U)) <<
                    @as(Rep.Shift, @intCast(known_lsbs));
                const fill = self.set & ~mask;
                break :blk .init(left.min & mask | fill, left.max & mask | fill);
            };
        }

        pub fn toRange(self: Self) KnownRange(T) {
            const u_range = self.toUnsignedRange();
            if (T == Rep.U)
                return u_range;
            const a: T = @bitCast(u_range.min);
            const b: T = @bitCast(u_range.max);
            return .init(@min(a, b), @max(a, b));
        }
    };
}

test KnownBits {
    try expectEqualDeep(
        KnownRange(u32).initExact(123),
        KnownBits(u32).initExact(123).toRange(),
    );
}

pub fn KnownDomain(T: type) type {
    return struct {
        const Self = @This();
        const Range = KnownRange(T);
        const Bits = KnownBits(T);
        pub const empty: Self = .{};

        range: Range = .empty,
        bits: Bits = .empty,

        pub fn initRange(range: Range) Self {
            return .{ .range = range };
        }

        pub fn initBits(bits: Bits) Self {
            return .{ .bits = bits };
        }

        pub fn initExact(value: T) Self {
            return .{ .range = .initExact(value), .bits = .initExact(value) };
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.range.eql(other.range) and
                self.bits.eql(other.bits);
        }

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            try writer.print(
                "range: {f} bits: {f}",
                .{ self.range, self.bits },
            );
        }

        pub fn narrowRange(self: Self, range: Range) Self {
            return .{
                .range = self.range.narrow(range),
                .bits = self.bits,
            };
        }

        pub fn narrowBits(self: Self, bits: Bits) Self {
            return .{
                .range = self.range,
                .bits = self.bits.narrow(bits),
            };
        }

        pub fn narrow(self: Self, other: Self) Self {
            return .{
                .range = self.range.narrow(other.range),
                .bits = self.bits.narrow(other.bits),
            };
        }

        pub fn widen(self: Self, other: Self) Self {
            return .{
                .range = self.range.widen(other.range),
                .bits = self.bits.widen(other.bits),
            };
        }

        pub fn refine(self: Self) Self {
            var res = self;
            while (true) {
                const prev = res;
                res.bits = res.bits.narrow(res.range.toBits());
                res.range = res.range.narrow(res.bits.toRange());
                if (prev.eql(res))
                    return res;
            }
        }
    };
}

test KnownDomain {
    const KDU = KnownDomain(u16);
    const kdu1: KDU = .initRange(.init(64, 127));
    print("kdu1: {f}\n", .{kdu1.refine()});
    const KDS = KnownDomain(i16);
    const kds1: KDS = .initRange(.init(-300, -1));
    print("kds1: {f}\n", .{kds1.refine()});
    const kds2: KDS = .initRange(.init(-1, 0));
    print("kds2: {f}\n", .{kds2.refine()});
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
