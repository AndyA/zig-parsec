const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

const CsvTag = enum { NONE, QUOTED, BARE, ROW, CSV };

const JsonContext = struct { allocator: Allocator };

const P = zpc.Zpc(JsonContext, CsvTag);

fn makeCsvParser() P.Parser {
    const skipSpace = P.takeWhile(.NONE, .zeroOrMore, zpc.predAnd(
        std.ascii.isWhitespace,
        zpc.predNot(zpc.predSet("\r\n")),
    ));

    const charParser = P.alt(&.{
        P.literal("\"\""),
        P.takeWhile(.NONE, .oneOrMore, zpc.predNot(zpc.predEqual('\"'))),
    });

    const stringParser = P.between(
        P.literal("\""),
        P.span(.QUOTED, P.many(.NONE, .zeroOrMore, charParser)),
        P.literal("\""),
    );

    const bareParser = P.span(
        .BARE,
        P.takeWhile(.NONE, .zeroOrMore, zpc.predNot(zpc.predSet(",\r\n"))),
    );

    const valueParser = P.right(skipSpace, P.alt(&.{ stringParser, bareParser }));

    const rowParser = P.seq(.ROW, &.{
        valueParser,
        P.flat(P.many(.NONE, .zeroOrMore, P.right(
            P.right(skipSpace, P.literal(",")),
            valueParser,
        ))),
    });

    const eolParser = P.takeWhile(.NONE, .oneOrMore, zpc.predSet("\r\n"));

    const csvParser = P.seq(.CSV, &.{
        rowParser,
        P.flat(P.many(.NONE, .zeroOrMore, P.right(
            P.right(skipSpace, eolParser),
            rowParser,
        ))),
    });

    return csvParser;
}

pub fn main(init: std.process.Init) !void {
    const jsonParser = makeCsvParser();
    const ctx: JsonContext = .{ .allocator = init.gpa };
    const res = try jsonParser(ctx,
        \\"""Hello", "World""", Now
        \\1,2,3,4
        \\
    );
    defer res.deinit(init.gpa);
    print("{f}", .{res});
}
