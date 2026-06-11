// nanobrew — bulk version index
//
// Builds a name -> latest-version map from the TSV index sidecars that
// `nb search` maintains over the Homebrew bulk lists (1h TTL). `nb outdated`
// and `nb upgrade` consult it instead of making one API round trip per
// installed package: ~80 HTTPS fetches become at most two bulk refreshes
// (and zero network + ~10 ms of parsing when the cache is warm).

const std = @import("std");
const search = @import("search.zig");

pub const VersionIndex = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged([]const u8),

    pub fn deinit(self: *VersionIndex) void {
        self.arena.deinit();
    }

    /// Latest known version for a formula name / cask token, or null when the
    /// package isn't in the bulk list (tap formulas, upstream-only records).
    pub fn get(self: *const VersionIndex, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    pub fn count(self: *const VersionIndex) usize {
        return self.map.count();
    }
};

pub fn loadFormulaIndex(alloc: std.mem.Allocator) !VersionIndex {
    const tsv = try search.cachedFormulaIndexTsv(alloc);
    defer alloc.free(tsv);
    return buildFromTsv(alloc, tsv);
}

pub fn loadCaskIndex(alloc: std.mem.Allocator) !VersionIndex {
    const tsv = try search.cachedCaskIndexTsv(alloc);
    defer alloc.free(tsv);
    return buildFromTsv(alloc, tsv);
}

/// Rows are `name\tversion\tdesc\n`. Name/version are duped into the index
/// arena; malformed rows (e.g. a torn trailing line) are skipped.
fn buildFromTsv(alloc: std.mem.Allocator, tsv: []const u8) !VersionIndex {
    var idx: VersionIndex = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .map = .empty,
    };
    errdefer idx.arena.deinit();
    const aa = idx.arena.allocator();

    var line_iter = std.mem.splitScalar(u8, tsv, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const tab1 = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const tab2 = std.mem.indexOfScalarPos(u8, line, tab1 + 1, '\t') orelse continue;
        const name = line[0..tab1];
        const version = line[tab1 + 1 .. tab2];
        if (name.len == 0 or version.len == 0) continue;
        try idx.map.put(aa, try aa.dupe(u8, name), try aa.dupe(u8, version));
    }

    return idx;
}

const testing = std.testing;

test "buildFromTsv - maps names to versions" {
    const tsv = "ripgrep\t14.1.1\tSearch tool\nxz\t5.8.3\tCompression\n";
    var idx = try buildFromTsv(testing.allocator, tsv);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 2), idx.count());
    try testing.expectEqualStrings("14.1.1", idx.get("ripgrep").?);
    try testing.expectEqualStrings("5.8.3", idx.get("xz").?);
    try testing.expect(idx.get("not-there") == null);
}

test "buildFromTsv - skips malformed and version-less rows" {
    const tsv = "good\t1.0\tdesc\nno-version\t\tdesc\ntorn-line";
    var idx = try buildFromTsv(testing.allocator, tsv);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 1), idx.count());
    try testing.expectEqualStrings("1.0", idx.get("good").?);
}
