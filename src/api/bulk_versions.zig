// nanobrew — bulk version index
//
// Builds a name -> latest-version map from the TSV index sidecars that
// `nb search` maintains over the Homebrew bulk lists (1h TTL). `nb outdated`
// and `nb upgrade` consult it instead of making one API round trip per
// installed package: ~80 HTTPS fetches become at most two bulk refreshes
// (and zero network + ~10 ms of parsing when the cache is warm).

const std = @import("std");
const search = @import("search.zig");

pub const DependencyIndex = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged([]const []const u8),

    pub fn deinit(self: *DependencyIndex) void {
        self.arena.deinit();
    }

    /// Dependencies from the fresh Homebrew bulk snapshot. A non-null empty
    /// slice means the formula is present and has no dependencies; null means
    /// the formula is outside the bulk list.
    pub fn get(self: *const DependencyIndex, name: []const u8) ?[]const []const u8 {
        return self.map.get(name);
    }

    pub fn count(self: *const DependencyIndex) usize {
        return self.map.count();
    }
};

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

pub fn loadFormulaIndexForNames(alloc: std.mem.Allocator, names: []const []const u8) !VersionIndex {
    const tsv = try search.cachedFormulaIndexTsv(alloc);
    defer alloc.free(tsv);
    return buildFromTsvForNames(alloc, tsv, names);
}

pub fn loadCaskIndexForNames(alloc: std.mem.Allocator, names: []const []const u8) !VersionIndex {
    const tsv = try search.cachedCaskIndexTsv(alloc);
    defer alloc.free(tsv);
    return buildFromTsvForNames(alloc, tsv, names);
}

pub fn loadFormulaDependenciesForNames(alloc: std.mem.Allocator, names: []const []const u8) !DependencyIndex {
    const tsv = try search.cachedFormulaIndexTsv(alloc);
    defer alloc.free(tsv);
    return buildDependenciesFromTsvForNames(alloc, tsv, names);
}

/// Rows are `name\tversion\tdesc\tstart\tend\tdeps\n`. Only requested rows are retained: an
/// installation normally contains hundreds of packages while Homebrew's
/// indexes contain thousands, so materializing the whole name/version map is
/// wasted allocation. Malformed rows (e.g. a torn trailing line) are skipped.
fn buildFromTsvForNames(alloc: std.mem.Allocator, tsv: []const u8, names: []const []const u8) !VersionIndex {
    var idx: VersionIndex = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .map = .empty,
    };
    errdefer idx.arena.deinit();
    if (names.len == 0) return idx;

    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    defer wanted.deinit(alloc);
    try wanted.ensureTotalCapacity(alloc, @intCast(names.len));
    for (names) |name| try wanted.put(alloc, name, {});

    const aa = idx.arena.allocator();
    try idx.map.ensureTotalCapacity(aa, @intCast(wanted.count()));
    var line_iter = std.mem.splitScalar(u8, tsv, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const tab1 = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const name = line[0..tab1];
        if (!wanted.contains(name)) continue;
        const tab2 = std.mem.indexOfScalarPos(u8, line, tab1 + 1, '\t') orelse continue;
        const version = line[tab1 + 1 .. tab2];
        if (version.len == 0) continue;
        try idx.map.put(aa, try aa.dupe(u8, name), try aa.dupe(u8, version));
        if (idx.map.count() == wanted.count()) break;
    }

    return idx;
}

fn buildDependenciesFromTsvForNames(
    alloc: std.mem.Allocator,
    tsv: []const u8,
    names: []const []const u8,
) !DependencyIndex {
    var idx: DependencyIndex = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .map = .empty,
    };
    errdefer idx.arena.deinit();
    if (names.len == 0) return idx;

    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    defer wanted.deinit(alloc);
    try wanted.ensureTotalCapacity(alloc, @intCast(names.len));
    for (names) |name| try wanted.put(alloc, name, {});

    const aa = idx.arena.allocator();
    try idx.map.ensureTotalCapacity(aa, @intCast(wanted.count()));
    var line_iter = std.mem.splitScalar(u8, tsv, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const name = cols.next() orelse continue;
        if (!wanted.contains(name)) continue;
        _ = cols.next() orelse continue; // version
        _ = cols.next() orelse continue; // description
        _ = cols.next() orelse continue; // JSON start offset
        _ = cols.next() orelse continue; // JSON end offset
        const encoded_deps = cols.next() orelse continue;

        const dep_count: usize = if (encoded_deps.len == 0)
            0
        else
            std.mem.count(u8, encoded_deps, ",") + 1;
        const deps = try aa.alloc([]const u8, dep_count);
        if (dep_count > 0) {
            var dep_iter = std.mem.splitScalar(u8, encoded_deps, ',');
            var i: usize = 0;
            while (dep_iter.next()) |dep| : (i += 1) {
                if (i >= deps.len or dep.len == 0) return error.InvalidDependencyIndex;
                deps[i] = try aa.dupe(u8, dep);
            }
            if (i != deps.len) return error.InvalidDependencyIndex;
        }
        try idx.map.put(aa, try aa.dupe(u8, name), deps);
        if (idx.map.count() == wanted.count()) break;
    }

    return idx;
}

const testing = std.testing;

test "buildFromTsvForNames retains only requested versions" {
    const tsv = "ripgrep\t14.1.1\tSearch tool\nxz\t5.8.3\tCompression\nunused\t9.0\tIgnored\n";
    const names = [_][]const u8{ "ripgrep", "xz", "not-there" };
    var idx = try buildFromTsvForNames(testing.allocator, tsv, &names);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 2), idx.count());
    try testing.expectEqualStrings("14.1.1", idx.get("ripgrep").?);
    try testing.expectEqualStrings("5.8.3", idx.get("xz").?);
    try testing.expect(idx.get("unused") == null);
    try testing.expect(idx.get("not-there") == null);
}

test "buildFromTsvForNames skips malformed and version-less rows" {
    const tsv = "good\t1.0\tdesc\nno-version\t\tdesc\ntorn-line";
    const names = [_][]const u8{ "good", "no-version", "torn-line" };
    var idx = try buildFromTsvForNames(testing.allocator, tsv, &names);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 1), idx.count());
    try testing.expectEqualStrings("1.0", idx.get("good").?);
}

test "buildDependenciesFromTsvForNames retains requested dependency lists" {
    const tsv =
        "ffmpeg\t8.0\tmedia\t0\t10\tdav1d,openssl@3,x264\n" ++
        "tree\t2.3\tdirectories\t11\t20\t\n" ++
        "unused\t1.0\tignored\t21\t30\tfoo\n" ++
        "#nanobrew-index-v5\t3\n";
    const names = [_][]const u8{ "ffmpeg", "tree", "missing" };
    var idx = try buildDependenciesFromTsvForNames(testing.allocator, tsv, &names);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 2), idx.count());
    const ffmpeg = idx.get("ffmpeg").?;
    try testing.expectEqual(@as(usize, 3), ffmpeg.len);
    try testing.expectEqualStrings("dav1d", ffmpeg[0]);
    try testing.expectEqualStrings("openssl@3", ffmpeg[1]);
    try testing.expectEqualStrings("x264", ffmpeg[2]);
    try testing.expectEqual(@as(usize, 0), idx.get("tree").?.len);
    try testing.expect(idx.get("unused") == null);
    try testing.expect(idx.get("missing") == null);
}
