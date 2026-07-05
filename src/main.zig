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

    const jsonParser = P.right(skipSpace, P.recurse("jsonParser"));
    const arrayParser = P.seq(.ARRAY, &.{
        P.discard(P.literal("[")),
        P.alt(&.{
            P.discard(P.right(skipSpace, P.literal("]"))),
            P.flat(P.seq(.NONE, &.{
                jsonParser,
                P.flat(P.many(
                    .NONE,
                    .zeroOrMore,
                    P.right(P.right(skipSpace, P.literal(",")), jsonParser),
                )),
                P.discard(P.right(skipSpace, P.literal("]"))),
            })),
        }),
    });

    const atomParser = P.alt(&.{
        P.keyword(.FALSE, "false"),
        P.keyword(.TRUE, "true"),
        P.keyword(.NULL, "null"),
        arrayParser,
        numParser,
    });

    return atomParser;
}

pub fn main(init: std.process.Init) !void {
    const jsonParser = makeJsonParser();
    const ctx: JsonContext = .{
        .allocator = init.gpa,
        .jsonParser = jsonParser,
    };
    const res = try jsonParser(ctx, "[ -12.3e+99, false ]");
    defer res.deinit(init.gpa);
    print("{f}\n", .{res});
}

test {
    _ = @import("zpc.zig");
}
