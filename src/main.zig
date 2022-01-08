const std = @import("std");
const heap = std.heap;
const io = std.io;

const ArrayList = std.ArrayList;

const filter = @import("filter.zig");
const ui = @import("ui.zig");

const version = "0.1";

const help =
    \\Usage: zf [OPTION]...
    \\-q, --query   Filter using the given query
    \\-h, --help    Display this help and exit
;

const Config = struct {
    help: bool = false,
    skip_ui: bool = false,
    query: []u8 = undefined,
};

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const stderr = std.io.getStdErr().writer();
    const args = try std.process.argsAlloc(allocator);

    var config: Config = .{};

    const eql = std.mem.eql;
    var skip = false;
    for (args[1..]) |arg, i| {
        if (skip) continue;
        const index = i + 1;

        if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
            config.help = true;
        } else if (eql(u8, arg, "-q") or eql(u8, arg, "--query")) {
            config.skip_ui = true;

            // read query
            if (index + 1 > args.len - 1) {
                try stderr.print("zf: option '{s}' requires an argument\n", .{arg});
                try stderr.print("{s}\n", .{help});
                std.process.exit(1);
            }

            config.query = try allocator.alloc(u8, args[index + 1].len);
            std.mem.copy(u8, config.query, args[index + 1]);
            skip = true;
        } else {
            try stderr.print("zf: unrecognized option '{s}'\n", .{arg});
            try stderr.print("{s}\n", .{help});
            std.process.exit(1);
        }
    }

    return config;
}

pub fn main() anyerror!void {
    // create an arena allocator to reduce time spent allocating
    // and freeing memory during runtime.
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const stdout = std.io.getStdOut().writer();
    const allocator = arena.allocator();

    const config = try parseArgs(allocator);
    _ = config;

    // help ignores all other args and quits
    if (config.help) {
        try stdout.print("{s}\n", .{help});
        return;
    }

    // read all lines or exit on out of memory
    var stdin = io.getStdIn().reader();
    const buf = try readAll(allocator, &stdin);

    const delimiter = '\n';
    var candidates = try filter.collectCandidates(allocator, buf, delimiter);

    if (config.skip_ui) {
        for (try filter.rankCandidates(allocator, candidates, config.query)) |candidate| {
            try stdout.print("{s}\n", .{candidate.str});
        }
    } else {
        var terminal = try ui.Terminal.init();
        var selected = try ui.run(allocator, &terminal, candidates);
        try ui.cleanUp(&terminal);
        terminal.deinit();

        if (selected) |result| {
            defer result.deinit();
            try stdout.print("{s}\n", .{result.items});
        }
    }
}

/// read from a file into an ArrayList. similar to readAllAlloc from the
/// standard library, but will read until out of memory rather than limiting to
/// a maximum size.
pub fn readAll(allocator: std.mem.Allocator, reader: *std.fs.File.Reader) ![]u8 {
    var buf = ArrayList(u8).init(allocator);

    // ensure the array starts at a decent size
    try buf.ensureTotalCapacity(4096);

    var index: usize = 0;
    while (true) {
        buf.expandToCapacity();
        const slice = buf.items[index..];
        const read = try reader.readAll(slice);
        index += read;

        if (read != slice.len) {
            buf.shrinkAndFree(index);
            return buf.toOwnedSlice();
        }

        try buf.ensureTotalCapacity(index + 1);
    }
}

test {
    _ = @import("filter.zig");
}
