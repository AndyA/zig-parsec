const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("../src/zpc.zig");

const JsonTag = enum {
    NONE,
    NUMBER,
    STRING,
    FALSE,
    TRUE,
    NULL,
    ARRAY,
    OBJECT,
    KEYVALUE,
};

const JsonContext = struct {
    allocator: Allocator,
    jsonParser: *const zpc.ZpcParser(@This(), JsonTag),
};

const P = zpc.Zpc(JsonContext, JsonTag);

fn makeJsonParser() P.Parser {
    const skipSpace = P.takeWhile(.NONE, .zeroOrMore, std.ascii.isWhitespace);
    const intParser = P.takeWhile(.NONE, .oneOrMore, std.ascii.isDigit);

    const posParser =
        P.left(
            P.left(intParser, P.optional(P.left(P.literal("."), intParser))),
            P.left(
                P.alt(&.{ P.literal("e"), P.literal("E") }),
                P.left(P.optional(P.alt(&.{ P.literal("+"), P.literal("-") })), intParser),
            ),
        );

    const numParser = P.span(.NUMBER, P.alt(&.{
        P.left(P.literal("-"), posParser),
        posParser,
    }));

    const charParser = P.alt(&.{
        P.left(P.literal("\\"), P.takeWhile(.NONE, .one, zpc.predTrue())),
        P.takeWhile(.NONE, .oneOrMore, zpc.predNot(zpc.predSet("\"\\"))),
    });

    const stringParser = P.between(
        P.literal("\""),
        P.span(.STRING, P.many(.NONE, .zeroOrMore, charParser)),
        P.literal("\""),
    );

    const selfParser = P.recurse("jsonParser");

    const kvParser = P.seq(.KEYVALUE, &.{
        stringParser,
        P.right(P.right(skipSpace, P.literal(":")), selfParser),
    });

    const objectParser = P.seq(.OBJECT, &.{
        P.discard(P.literal("{")),
        P.alt(&.{
            P.discard(P.right(skipSpace, P.literal("}"))),
            P.flat(P.seq(.NONE, &.{
                kvParser,
                P.flat(P.many(
                    .NONE,
                    .zeroOrMore,
                    P.right(P.right(skipSpace, P.literal(",")), kvParser),
                )),
                P.discard(P.right(skipSpace, P.literal("}"))),
            })),
        }),
    });

    const arrayParser = P.seq(.ARRAY, &.{
        P.discard(P.literal("[")),
        P.alt(&.{
            P.discard(P.right(skipSpace, P.literal("]"))),
            P.flat(P.seq(.NONE, &.{
                selfParser,
                P.flat(P.many(
                    .NONE,
                    .zeroOrMore,
                    P.right(P.right(skipSpace, P.literal(",")), selfParser),
                )),
                P.discard(P.right(skipSpace, P.literal("]"))),
            })),
        }),
    });

    const jsonParser = P.right(skipSpace, P.alt(&.{
        P.keyword(.FALSE, "false"),
        P.keyword(.TRUE, "true"),
        P.keyword(.NULL, "null"),
        stringParser,
        objectParser,
        arrayParser,
        numParser,
    }));

    return jsonParser;
}

pub fn main(init: std.process.Init) !void {
    const jsonParser = makeJsonParser();
    const ctx: JsonContext = .{
        .allocator = init.gpa,
        .jsonParser = jsonParser,
    };
    const res = try jsonParser(ctx, "{\"things\": [ -12.3e+99, false, \"Hello\\n\", [] ]}");
    defer res.deinit(init.gpa);
    print("{f}\n", .{res});
}

test {
    _ = @import("zpc.zig");
}
