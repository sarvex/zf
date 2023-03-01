const std = @import("std");
const testing = std.testing;

const ArrayList = std.ArrayList;

/// Candidates are the strings read from stdin
pub const Candidate = struct {
    str: []const u8,
    rank: f64 = 0,
};

/// read the candidates from the buffer
pub fn collectCandidates(allocator: std.mem.Allocator, buf: []const u8, delimiter: u8) ![][]const u8 {
    var candidates = ArrayList([]const u8).init(allocator);

    // find delimiters
    var start: usize = 0;
    for (buf) |char, index| {
        if (char == delimiter) {
            // add to arraylist only if slice is not all delimiters
            if (index - start != 0) {
                try candidates.append(buf[start..index]);
            }
            start = index + 1;
        }
    }

    // catch the end if stdio didn't end in a delimiter
    if (start < buf.len) {
        try candidates.append(buf[start..]);
    }

    return candidates.toOwnedSlice();
}

test "collectCandidates whitespace" {
    var candidates = try collectCandidates(testing.allocator, "first second third fourth", ' ');
    defer testing.allocator.free(candidates);

    try testing.expectEqual(@as(usize, 4), candidates.len);
    try testing.expectEqualStrings("first", candidates[0]);
    try testing.expectEqualStrings("second", candidates[1]);
    try testing.expectEqualStrings("third", candidates[2]);
    try testing.expectEqualStrings("fourth", candidates[3]);
}

test "collectCandidates newline" {
    var candidates = try collectCandidates(testing.allocator, "first\nsecond\nthird\nfourth", '\n');
    defer testing.allocator.free(candidates);

    try testing.expectEqual(@as(usize, 4), candidates.len);
    try testing.expectEqualStrings("first", candidates[0]);
    try testing.expectEqualStrings("second", candidates[1]);
    try testing.expectEqualStrings("third", candidates[2]);
    try testing.expectEqualStrings("fourth", candidates[3]);
}

test "collectCandidates excess whitespace" {
    var candidates = try collectCandidates(testing.allocator, "   first second   third fourth   ", ' ');
    defer testing.allocator.free(candidates);

    try testing.expectEqual(@as(usize, 4), candidates.len);
    try testing.expectEqualStrings("first", candidates[0]);
    try testing.expectEqualStrings("second", candidates[1]);
    try testing.expectEqualStrings("third", candidates[2]);
    try testing.expectEqualStrings("fourth", candidates[3]);
}

/// rank each candidate against the query
///
/// returns a sorted slice of Candidates that match the query ready for display
/// in a tui or output to stdout
pub fn rankCandidates(
    ranked: []Candidate,
    candidates: []const []const u8,
    tokens: []const []const u8,
    keep_order: bool,
    plain: bool,
    case_sensitive: bool,
) []Candidate {
    if (tokens.len == 0) {
        for (candidates) |candidate, index| {
            ranked[index] = .{ .str = candidate };
        }
        return ranked;
    }

    var index: usize = 0;
    for (candidates) |candidate| {
        if (rankCandidate(candidate, tokens, case_sensitive, plain)) |rank| {
            ranked[index] = .{ .str = candidate, .rank = rank };
            index += 1;
        }
    }

    if (!keep_order) {
        std.sort.sort(Candidate, ranked[0..index], {}, sort);
    }

    return ranked[0..index];
}

fn indexOf(
    comptime T: type,
    slice: []const T,
    start_index: usize,
    value: T,
    strict_path_match: bool,
    comptime case_sensitive: bool,
) ?usize {
    var i: usize = start_index;
    while (i < slice.len) : (i += 1) {
        if (strict_path_match and value != '/' and slice[i] == '/') return null;

        if (case_sensitive) {
            if (slice[i] == value) return i;
        } else {
            if (std.ascii.toLower(slice[i]) == value) return i;
        }
    }
    return null;
}

const IndexIterator = struct {
    str: []const u8,
    char: u8,
    index: usize = 0,
    case_sensitive: bool,

    pub fn init(str: []const u8, char: u8, case_sensitive: bool) @This() {
        return .{ .str = str, .char = char, .case_sensitive = case_sensitive };
    }

    pub fn next(self: *@This()) ?usize {
        const index = if (self.case_sensitive)
            indexOf(u8, self.str, self.index, self.char, false, true)
        else
            indexOf(u8, self.str, self.index, self.char, false, false);

        if (index) |i| self.index = i + 1;
        return index;
    }
};

/// rank a candidate against the given query tokens
///
/// algorithm inspired by https://github.com/garybernhardt/selecta
pub fn rankCandidate(
    candidate: []const u8,
    query_tokens: []const []const u8,
    case_sensitive: bool,
    plain: bool,
) ?f64 {
    const filename = if (plain) null else std.fs.path.basename(candidate);

    // the candidate must contain all of the characters (in order) in each token.
    // each tokens rank is summed. if any token does not match the candidate is ignored
    var rank: f64 = 0;
    for (query_tokens) |token| {
        if (rankToken(candidate, filename, token, case_sensitive)) |r| {
            rank += r;
        } else return null;
    }

    // all tokens matched and the best ranks for each tokens are summed
    return rank;
}

pub fn rankToken(
    str: []const u8,
    filenameOrNull: ?[]const u8,
    token: []const u8,
    case_sensitive: bool,
) ?f64 {
    if (str.len == 0 or token.len == 0) return null;

    // iterates over the string performing a match starting at each possible index
    // the best (minimum) overall ranking is kept and returned
    var best_rank: ?f64 = null;

    // perform search on the filename only if requested
    if (filenameOrNull) |filename| {
        var it = IndexIterator.init(filename, token[0], case_sensitive);
        while (it.next()) |start_index| {
            if (scanToEnd(filename, token[1..], start_index, 0, null, case_sensitive, token[0] == '/')) |rank| {
                if (best_rank == null or rank < best_rank.?) best_rank = rank;
            } else if (token[0] != '/') break;
        }

        if (best_rank != null) {
            // was a filename match, give priority
            best_rank.? /= 2.0;

            // how much of the token matched the filename?
            if (token.len == filename.len) {
                best_rank.? /= 2.0;
            } else {
                const coverage = 1.0 - (@intToFloat(f64, token.len) / @intToFloat(f64, filename.len));
                best_rank.? *= coverage;
            }

            return best_rank;
        }
    }

    // perform search on the full string if requested or if no match was found on the filename
    var it = IndexIterator.init(str, token[0], case_sensitive);
    while (it.next()) |start_index| {
        if (scanToEnd(str, token[1..], start_index, 0, null, case_sensitive, token[0] == '/')) |rank| {
            if (best_rank == null or rank < best_rank.?) best_rank = rank;
        } else if (token[0] != '/') break;
    }

    return best_rank;
}

test "rankToken" {
    // TODO: cannot easily test smart case yet because the boolean here
    // depends on the token being lower case. If rankToken is to be a public function
    // then we should resolve this.

    // plain string matching
    try testing.expectEqual(@as(?f64, null), rankToken("", null, "", false));
    try testing.expectEqual(@as(?f64, null), rankToken("", null, "b", false));
    try testing.expectEqual(@as(?f64, null), rankToken("a", null, "", false));
    try testing.expectEqual(@as(?f64, null), rankToken("a", null, "b", false));
    try testing.expectEqual(@as(?f64, null), rankToken("aaa", null, "aab", false));
    try testing.expectEqual(@as(?f64, null), rankToken("abbba", null, "abab", false));

    try testing.expect(rankToken("a", null, "a", false) != null);
    try testing.expect(rankToken("abc", null, "abc", false) != null);
    try testing.expect(rankToken("aaabbbccc", null, "abc", false) != null);
    try testing.expect(rankToken("azbycx", null, "x", false) != null);
    try testing.expect(rankToken("azbycx", null, "ax", false) != null);
    try testing.expect(rankToken("a", null, "a", false) != null);

    // file name matching
    try testing.expectEqual(@as(?f64, null), rankToken("", "", "", false));
    try testing.expectEqual(@as(?f64, null), rankToken("/a", "a", "b", false));
    try testing.expectEqual(@as(?f64, null), rankToken("c/a", "a", "b", false));
    try testing.expectEqual(@as(?f64, null), rankToken("/file.ext", "file.ext", "z", false));
    try testing.expectEqual(@as(?f64, null), rankToken("/file.ext", "file.ext", "fext.", false));
    try testing.expectEqual(@as(?f64, null), rankToken("/a/b/c", "c", "d", false));

    try testing.expect(rankToken("/b", "b", "b", false) != null);
    try testing.expect(rankToken("/a/b/c", "c", "c", false) != null);
    try testing.expect(rankToken("/file.ext", "file.ext", "ext", false) != null);
    try testing.expect(rankToken("path/to/file.ext", "file.ext", "file", false) != null);
    try testing.expect(rankToken("path/to/file.ext", "file.ext", "to", false) != null);
    try testing.expect(rankToken("path/to/file.ext", "file.ext", "path", false) != null);
    try testing.expect(rankToken("path/to/file.ext", "file.ext", "pfile", false) != null);
    try testing.expect(rankToken("path/to/file.ext", "file.ext", "ptf", false) != null);
    try testing.expect(rankToken("path/to/file.ext", "file.ext", "p/t/f", false) != null);

    // strict path matching
    try testing.expectEqual(@as(?f64, null), rankToken("a/b/c", "c", "a/c", false));
    try testing.expectEqual(@as(?f64, null), rankToken("/some/path/here", "here", "/somepath", false));
    try testing.expectEqual(@as(?f64, null), rankToken("/app/monsters/dungeon/foo/bar/baz.rb", "baz.rb", "a/m/f/b/baz", false));

    try testing.expect(rankToken("src/config/__init__.py", "__init__.py", "con/i", false) != null);
    try testing.expect(rankToken("a/b/c/d", "d", "a/b/c", false) != null);
    try testing.expect(rankToken("./app/models/foo/bar/baz.rb", "baz.rb", "a/m/f/b/baz", false) != null);
}

/// A simple, append-only array list backed by a fixed buffer
pub fn FixedArrayList(comptime T: type) type {
    return struct {
        buffer: []T,
        len: usize = 0,

        const This = @This();

        pub fn init(buffer: []T) This {
            return .{ .buffer = buffer };
        }

        pub fn append(list: *This, data: T) void {
            if (list.len >= list.buffer.len) return;
            list.buffer[list.len] = data;
            list.len += 1;
        }

        pub fn clear(list: *This) void {
            list.len = 0;
        }

        pub fn slice(list: This) []const T {
            return list.buffer[0..list.len];
        }
    };
}

test "FixedArrayList" {
    var buffer: [4]usize = undefined;
    var list = FixedArrayList(usize).init(&buffer);

    list.append(1);
    list.append(2);
    list.append(3);
    list.append(4);
    list.append(5);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 3, 4 }, list.slice());

    list.clear();
    try testing.expectEqualSlices(usize, &.{}, list.slice());
}

pub fn highlightToken(
    str: []const u8,
    filenameOrNull: ?[]const u8,
    token: []const u8,
    case_sensitive: bool,
    matches: []usize,
) []const usize {
    if (str.len == 0 or token.len == 0) return &.{};

    var best_rank: ?f64 = null;

    // Working memory for computing matches
    var buf: [512]usize = undefined;
    var matched = FixedArrayList(usize).init(&buf);
    var best_matched = FixedArrayList(usize).init(matches);

    // highlight on the filename if requested
    if (filenameOrNull) |filename| {
        // The basename doesn't include trailing slashes so if the string ends in a slash the offset will be off by one
        const offset = str.len - filename.len - @as(usize, if (str[str.len - 1] == '/') 1 else 0);

        var it = IndexIterator.init(filename, token[0], case_sensitive);
        while (it.next()) |start_index| {
            matched.append(start_index + offset);

            if (scanToEnd(filename, token[1..], start_index, offset, &matched, case_sensitive, token[0] == '/')) |rank| {
                if (best_rank == null or rank < best_rank.?) {
                    best_rank = rank;
                    best_matched.clear();
                    for (matched.slice()) |index| best_matched.append(index);
                }
            } else if (token[0] != '/') break;
            matched.clear();
        }
        if (best_rank != null) return best_matched.slice();
    }

    matched.clear();

    // highlight the full string if requested or if no match was found on the filename
    var it = IndexIterator.init(str, token[0], case_sensitive);
    while (it.next()) |start_index| {
        matched.append(start_index);

        if (scanToEnd(str, token[1..], start_index, 0, &matched, case_sensitive, token[0] == '/')) |rank| {
            if (best_rank == null or rank < best_rank.?) {
                best_rank = rank;
                best_matched.clear();
                for (matched.slice()) |index| best_matched.append(index);
            }
        } else if (token[0] != '/') break;
        matched.clear();
    }

    return best_matched.slice();
}

inline fn isStartOfWord(byte: u8) bool {
    return switch (byte) {
        std.fs.path.sep, '_', '-', '.', ' ' => true,
        else => false,
    };
}

/// this is the core of the ranking algorithm. special precedence is given to
/// filenames. if a match is found on a filename the candidate is ranked higher
fn scanToEnd(
    str: []const u8,
    token: []const u8,
    start_index: usize,
    offset: usize,
    matched_indices: ?*FixedArrayList(usize),
    case_sensitive: bool,
    start_strict_path_match: bool,
) ?f64 {
    var rank: f64 = 1;
    var last_index = start_index;
    var last_sequential = false;
    var strict_path_match = start_strict_path_match;

    // penalty for not starting on a word boundary
    if (start_index > 0 and !isStartOfWord(str[start_index - 1])) {
        rank += 2.0;
    }

    for (token) |c| {
        const index = if (case_sensitive)
            indexOf(u8, str, last_index + 1, c, strict_path_match, true)
        else
            indexOf(u8, str, last_index + 1, c, strict_path_match, false);

        if (index) |idx| {
            if (matched_indices != null) matched_indices.?.append(idx + offset);

            if (idx == last_index + 1) {
                // sequential matches only count the first character
                if (!last_sequential) {
                    last_sequential = true;
                    rank += 1.0;
                }
            } else {
                // penalty for not starting on a word boundary
                if (!isStartOfWord(str[idx - 1])) {
                    rank += 2.0;
                }

                // normal match
                last_sequential = false;
                rank += @intToFloat(f64, idx - last_index);
            }

            last_index = idx;
            if (c == '/') strict_path_match = true;
        } else return null;
    }

    return rank;
}

fn sort(_: void, a: Candidate, b: Candidate) bool {
    // first by rank
    if (a.rank < b.rank) return true;
    if (a.rank > b.rank) return false;

    // then by length
    if (a.str.len < b.str.len) return true;
    if (a.str.len > b.str.len) return false;

    // then alphabetically
    for (a.str) |c, i| {
        if (c < b.str[i]) return true;
        if (c > b.str[i]) return false;
    }
    return false;
}

// These tests are arguably the most important in zf. They ensure the ordering of filtered
// items is maintained when updating the filter algorithms. The test cases are based on
// experience with other fuzzy finders that led to the creation of zf. When I find new
// ways to improve the filtering algorithm these tests should all pass, and new tests
// should be added to ensure the filtering doesn't break. The tests don't check the actual
// rank value, only the order of the first n results.

fn testRankCandidates(
    tokens: []const []const u8,
    candidates: []const []const u8,
    expected: []const []const u8,
) !void {
    var ranked_buf = try testing.allocator.alloc(Candidate, candidates.len);
    defer testing.allocator.free(ranked_buf);
    const ranked = rankCandidates(ranked_buf, candidates, tokens, false, false, false);

    for (expected) |expected_str, i| {
        if (!std.mem.eql(u8, expected_str, ranked[i].str)) {
            std.debug.print("\n======= order incorrect: ========\n", .{});
            for (ranked[0..expected.len]) |candidate| std.debug.print("{s}\n", .{candidate.str});
            std.debug.print("\n========== expected: ===========\n", .{});
            for (expected) |str| std.debug.print("{s}\n", .{str});
            std.debug.print("\n================================", .{});
            std.debug.print("\nwith query:", .{});
            for (tokens) |token| std.debug.print(" {s}", .{token});
            std.debug.print("\n\n", .{});

            return error.TestOrderIncorrect;
        }
    }
}

test "zf ranking consistency" {
    // Filepaths from Blender. Both fzf and fzy rank DNA_genfile.h first
    try testRankCandidates(
        &.{"make"},
        &.{
            "source/blender/makesrna/intern/rna_cachefile.c",
            "source/blender/makesdna/intern/dna_genfile.c",
            "source/blender/makesdna/DNA_curveprofile_types.h",
            "source/blender/makesdna/DNA_genfile.h",
            "GNUmakefile",
        },
        &.{"GNUmakefile"},
    );

    // From issue #3, prioritize filename coverage
    try testRankCandidates(&.{"a"}, &.{ "/path/a.c", "abcd" }, &.{"/path/a.c"});
    try testRankCandidates(
        &.{"app.py"},
        &.{
            "./myownmod/custom/app.py",
            "./tests/test_app.py",
        },
        &.{"./tests/test_app.py"},
    );
}
