# Parser Builder

## TODO

- make sure we can parse at comptime
- ~~what to do when progress stops?~~ `advances()`
- how to parse e.g. YAML, Python?
- `lookup()` - bridge between toking and parsing; looks up a parsed span against a keyword table
- or `reparse(lower: Parser, upper: Parser)` - parse, span, reparse

## Comptime Parsing

The problem: although it's possible to implement a comptime allocator parts of the `std` including `ArrayBuffer` aren't usable with structures whose layout isn't comptime known - so they have to be `extern struct`; however we don't like `extern struct` because we can't embed a tagged union in them.

Possible solution: we make fairly specific use of `ArrayBuffer`. We could abstract it behind an interface that accepts a context (instead of an allocator) and swap in a comptime version.
