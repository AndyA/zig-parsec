const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

const JsonPathTag = enum { NONE, NUMBER, STRING, IDENT, PATH, WILD };

const JsonContext = struct {
    allocator: Allocator,
};

const P = zpc.Zpc(JsonContext, JsonPathTag);

fn makeJsonPathParser() P.Parser {
    const intParser = P.takeWhile(.NUMBER, .oneOrMore, std.ascii.isDigit);

    const charParser = P.alt(&.{
        P.left(P.literal("\\"), P.takeWhile(.NONE, .one, zpc.predNot(std.ascii.isControl))),
        P.takeWhile(.NONE, .oneOrMore, zpc.predNot(zpc.predOr(
            std.ascii.isControl,
            zpc.predSet("\"\\"),
        ))),
    });

    const stringParser = P.between(
        P.literal("\""),
        P.span(.STRING, P.many(.NONE, .zeroOrMore, charParser)),
        P.literal("\""),
    );

    const subscriptParser = P.between(
        P.literal("["),
        P.alt(&.{ P.keyword(.WILD, "*"), stringParser, intParser }),
        P.literal("]"),
    );

    const identFirstPred = zpc.predOr(std.ascii.isAlphabetic, zpc.predSet("$_"));
    const identRestPred = zpc.predOr(identFirstPred, std.ascii.isDigit);

    const identParser = P.right(P.literal("."), P.span(.IDENT, P.left(
        P.takeWhile(.NONE, .one, identFirstPred),
        P.takeWhile(.NONE, .zeroOrMore, identRestPred),
    )));

    const jsonPathParser = P.right(
        P.literal("$"),
        P.many(.PATH, .zeroOrMore, P.alt(&.{ subscriptParser, identParser })),
    );

    return jsonPathParser;
}

pub fn main(init: std.process.Init) !void {
    const jsonPathParser = makeJsonPathParser();
    const ctx: JsonContext = .{
        .allocator = init.gpa,
    };
    const paths: []const []const u8 = &.{
        \\$[0].$foo["\n"][*]
        ,
        \\$
        ,
        \\$.$
        ,
        \\$foo // FAIL
    };
    for (paths) |path| {
        print("Path: {s}\n", .{path});
        const res = try jsonPathParser(ctx, path);
        defer res.deinit(init.gpa);
        print("{f}\n", .{res});
    }
}
