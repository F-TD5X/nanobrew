// nanobrew — Search API
//
// Fetches formula and cask lists from Homebrew API and performs
// case-insensitive substring matching on name and description.

const std = @import("std");
const fetch = @import("../net/fetch.zig");
const FORMULA_LIST_URL = "https://formulae.brew.sh/api/formula.json";
const CASK_LIST_URL = "https://formulae.brew.sh/api/cask.json";
const paths = @import("../platform/paths.zig");
const CACHE_DIR = paths.API_CACHE_DIR;
const FORMULA_CACHE = CACHE_DIR ++ "/_formula_list.json";
const CASK_CACHE = CACHE_DIR ++ "/_cask_list.json";
const FORMULA_IDX = FORMULA_CACHE ++ ".idx";
const CASK_IDX = CASK_CACHE ++ ".idx";
const CACHE_TTL_NS = 3600 * std.time.ns_per_s; // 1 hour

pub const SearchResult = struct {
    name: []const u8,
    version: []const u8,
    desc: []const u8,
    is_cask: bool,

    pub fn deinit(self: SearchResult, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.desc);
    }
};

pub fn search(alloc: std.mem.Allocator, query: []const u8) ![]SearchResult {
    var results: std.ArrayList(SearchResult) = .empty;
    defer results.deinit(alloc); // only the list, not items — caller owns items

    // Lowercase the query for case-insensitive matching
    const lower_query = try toLower(alloc, query);
    defer alloc.free(lower_query);

    // Search formulae (TSV sidecar: ~20x smaller than the bulk JSON)
    const formula_idx = try cachedFormulaIndexTsv(alloc);
    defer alloc.free(formula_idx);
    try searchIndexTsv(alloc, formula_idx, lower_query, false, &results);

    // Search casks
    const cask_idx = try cachedCaskIndexTsv(alloc);
    defer alloc.free(cask_idx);
    try searchIndexTsv(alloc, cask_idx, lower_query, true, &results);

    return results.toOwnedSlice(alloc);
}

/// Cached bulk formula list (1h TTL, shared with `nb outdated`/`upgrade`).
pub fn cachedFormulaListJson(alloc: std.mem.Allocator) ![]u8 {
    return fetchCachedList(alloc, FORMULA_LIST_URL, FORMULA_CACHE);
}

/// Cached bulk cask list (1h TTL, shared with `nb outdated`/`upgrade`).
pub fn cachedCaskListJson(alloc: std.mem.Allocator) ![]u8 {
    return fetchCachedList(alloc, CASK_LIST_URL, CASK_CACHE);
}

fn fetchCachedList(alloc: std.mem.Allocator, url: []const u8, cache_path: []const u8) ![]u8 {
    // Check cache with 1-hour TTL
    if (readCachedFile(alloc, cache_path)) |data| return data;

    // Fetch from network (native HTTP, no curl)
    const body = fetch.get(alloc, url) catch return error.FetchFailed;

    // Write to cache
    std.Io.Dir.createDirAbsolute(paths.safe_io, CACHE_DIR, .default_dir) catch {};
    if (std.Io.Dir.createFileAbsolute(paths.safe_io, cache_path, .{})) |file| {
        defer file.close(paths.safe_io);
        file.writeStreamingAll(paths.safe_io, body) catch {};
    } else |_| {}

    return body;
}

/// TSV index sidecar — one `name\tversion\tdesc\n` row per bulk-list entry.
/// ~20x smaller than the source JSON and trivially parseable, so `nb search`
/// and `nb outdated`/`upgrade` skip re-scanning ~46 MB of JSON per command.
/// Rebuilt whenever the JSON cache is refreshed (mtime ordering).
pub fn cachedFormulaIndexTsv(alloc: std.mem.Allocator) ![]u8 {
    return cachedIndexTsv(alloc, FORMULA_LIST_URL, FORMULA_CACHE, FORMULA_IDX, .formula);
}

pub fn cachedCaskIndexTsv(alloc: std.mem.Allocator) ![]u8 {
    return cachedIndexTsv(alloc, CASK_LIST_URL, CASK_CACHE, CASK_IDX, .cask);
}

const ListKind = enum { formula, cask };

fn cachedIndexTsv(alloc: std.mem.Allocator, url: []const u8, json_path: []const u8, idx_path: []const u8, kind: ListKind) ![]u8 {
    const lib_io = paths.safe_io;

    // Fast path: fresh JSON cache + sidecar at least as new -> read sidecar only.
    if (fileMtimeNs(json_path)) |json_mtime| {
        const now_ts = std.Io.Timestamp.now(lib_io, .real);
        if (now_ts.nanoseconds - json_mtime <= CACHE_TTL_NS) {
            if (fileMtimeNs(idx_path)) |idx_mtime| {
                if (idx_mtime >= json_mtime) {
                    if (readFileAlloc(alloc, idx_path)) |buf| return buf;
                }
            }
            // JSON is fresh but the sidecar is missing/stale: rebuild from disk.
            if (readFileAlloc(alloc, json_path)) |json| {
                defer alloc.free(json);
                return buildAndWriteIndexTsv(alloc, json, idx_path, kind);
            }
        }
    }

    // JSON cache is missing/stale: refetch (writes the JSON cache), then build.
    const json = try fetchCachedList(alloc, url, json_path);
    defer alloc.free(json);
    return buildAndWriteIndexTsv(alloc, json, idx_path, kind);
}

fn fileMtimeNs(path: []const u8) ?i96 {
    const lib_io = paths.safe_io;
    const file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return null;
    defer file.close(lib_io);
    const st = file.stat(lib_io) catch return null;
    return st.mtime.nanoseconds;
}

/// Whole-file read with no TTL check (validity is established by the caller
/// via mtime ordering against the JSON cache).
fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const lib_io = paths.safe_io;
    const file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return null;
    defer file.close(lib_io);
    const st = file.stat(lib_io) catch return null;
    const sz = @min(st.size, 64 * 1024 * 1024);
    const buf = alloc.alloc(u8, sz) catch return null;
    const n = file.readPositionalAll(lib_io, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
    if (n < sz) {
        const trimmed = alloc.realloc(buf, n) catch return buf[0..n];
        return trimmed;
    }
    return buf;
}

fn buildAndWriteIndexTsv(alloc: std.mem.Allocator, json: []const u8, idx_path: []const u8, kind: ListKind) ![]u8 {
    const tsv = try buildIndexTsv(alloc, json, kind);
    std.Io.Dir.createDirAbsolute(paths.safe_io, CACHE_DIR, .default_dir) catch {};
    if (std.Io.Dir.createFileAbsolute(paths.safe_io, idx_path, .{})) |file| {
        defer file.close(paths.safe_io);
        file.writeStreamingAll(paths.safe_io, tsv) catch {};
    } else |_| {}
    return tsv;
}

/// One streaming pass over the bulk JSON producing `name\tversion\tdesc\n`
/// rows. Tabs/newlines inside desc are replaced with spaces so the row format
/// stays unambiguous.
fn buildIndexTsv(alloc: std.mem.Allocator, json: []const u8, kind: ListKind) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var scanner = std.json.Scanner.initCompleteInput(alloc, json);
    defer scanner.deinit();

    if ((try scanner.next()) != .array_begin) return error.UnexpectedJson;

    const name_key = switch (kind) {
        .formula => "name",
        .cask => "token",
    };

    while (true) {
        switch (try scanner.next()) {
            .array_end => break,
            .object_begin => {},
            else => return error.UnexpectedJson,
        }

        var name: []const u8 = "";
        var desc: []const u8 = "";
        var version: []const u8 = "";
        var name_owned: ?[]u8 = null;
        var desc_owned: ?[]u8 = null;
        var version_owned: ?[]u8 = null;
        defer {
            if (name_owned) |s| alloc.free(s);
            if (desc_owned) |s| alloc.free(s);
            if (version_owned) |s| alloc.free(s);
        }

        while (true) {
            const key_tok = try scanner.nextAlloc(alloc, .alloc_if_needed);
            var key: []const u8 = "";
            var key_alloc: ?[]u8 = null;
            switch (key_tok) {
                .object_end => break,
                .string => |s| key = s,
                .allocated_string => |s| {
                    key = s;
                    key_alloc = s;
                },
                else => return error.UnexpectedJson,
            }
            defer if (key_alloc) |s| alloc.free(s);

            if (std.mem.eql(u8, key, name_key)) {
                captureString(&scanner, alloc, &name, &name_owned) catch return error.UnexpectedJson;
            } else if (std.mem.eql(u8, key, "desc")) {
                captureString(&scanner, alloc, &desc, &desc_owned) catch return error.UnexpectedJson;
            } else if (kind == .formula and std.mem.eql(u8, key, "versions")) {
                if ((try scanner.next()) != .object_begin) continue;
                while (true) {
                    const vk = try scanner.nextAlloc(alloc, .alloc_if_needed);
                    var vkey: []const u8 = "";
                    var vkey_alloc: ?[]u8 = null;
                    switch (vk) {
                        .object_end => break,
                        .string => |s| vkey = s,
                        .allocated_string => |s| {
                            vkey = s;
                            vkey_alloc = s;
                        },
                        else => return error.UnexpectedJson,
                    }
                    defer if (vkey_alloc) |s| alloc.free(s);
                    if (std.mem.eql(u8, vkey, "stable")) {
                        captureString(&scanner, alloc, &version, &version_owned) catch return error.UnexpectedJson;
                    } else {
                        try scanner.skipValue();
                    }
                }
            } else if (kind == .cask and std.mem.eql(u8, key, "version")) {
                captureString(&scanner, alloc, &version, &version_owned) catch return error.UnexpectedJson;
            } else {
                try scanner.skipValue();
            }
        }

        if (name.len == 0) continue;
        try out.appendSlice(alloc, name);
        try out.append(alloc, '\t');
        try appendSanitized(&out, alloc, version);
        try out.append(alloc, '\t');
        try appendSanitized(&out, alloc, desc);
        try out.append(alloc, '\n');
    }

    return out.toOwnedSlice(alloc);
}

fn appendSanitized(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        try out.append(alloc, if (c == '\t' or c == '\n' or c == '\r') ' ' else c);
    }
}

/// Scan a TSV index: substring-match query against name and desc columns.
fn searchIndexTsv(alloc: std.mem.Allocator, tsv: []const u8, lower_query: []const u8, is_cask: bool, results: *std.ArrayList(SearchResult)) !void {
    var line_iter = std.mem.splitScalar(u8, tsv, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const tab1 = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const tab2 = std.mem.indexOfScalarPos(u8, line, tab1 + 1, '\t') orelse continue;
        const name = line[0..tab1];
        const version = line[tab1 + 1 .. tab2];
        const desc = line[tab2 + 1 ..];
        if (!containsIgnoreCase(name, lower_query) and !containsIgnoreCase(desc, lower_query)) continue;
        try results.append(alloc, .{
            .name = try alloc.dupe(u8, name),
            .version = try alloc.dupe(u8, version),
            .desc = try alloc.dupe(u8, desc),
            .is_cask = is_cask,
        });
    }
}

fn readCachedFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const lib_io = paths.safe_io;
    const file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return null;
    defer file.close(lib_io);
    const st = file.stat(lib_io) catch return null;
    const now_ts = std.Io.Timestamp.now(lib_io, .real);
    const age_ns: i96 = now_ts.nanoseconds - st.mtime.nanoseconds;
    if (age_ns > CACHE_TTL_NS) return null;
    const sz = @min(st.size, 64 * 1024 * 1024);
    const buf = alloc.alloc(u8, sz) catch return null;
    const n = file.readPositionalAll(lib_io, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
    if (n < sz) {
        const trimmed = alloc.realloc(buf, n) catch return buf[0..n];
        return trimmed;
    }
    return buf;
}

fn captureString(scanner: *std.json.Scanner, alloc: std.mem.Allocator, out: *[]const u8, owned: *?[]u8) !void {
    const v = try scanner.nextAlloc(alloc, .alloc_if_needed);
    switch (v) {
        .string => |s| out.* = s,
        .allocated_string => |s| {
            out.* = s;
            owned.* = s;
        },
        else => {},
    }
}

fn containsIgnoreCase(haystack: []const u8, lower_needle: []const u8) bool {
    if (lower_needle.len == 0) return true;
    if (lower_needle.len > haystack.len) return false;
    const end = haystack.len - lower_needle.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        var j: usize = 0;
        while (j < lower_needle.len) : (j += 1) {
            const hc = haystack[i + j];
            const hcl: u8 = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            if (hcl != lower_needle[j]) break;
        }
        if (j == lower_needle.len) return true;
    }
    return false;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}

fn toLower(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const result = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return result;
}

const testing = std.testing;

test "buildIndexTsv - formula entries become name/version/desc rows" {
    const json =
        \\[{"name":"ripgrep","desc":"Search tool","versions":{"stable":"14.1.1","head":"HEAD"},"revision":0},
        \\ {"name":"weird","desc":"tab\there","versions":{"stable":"1.0"}}]
    ;
    const tsv = try buildIndexTsv(testing.allocator, json, .formula);
    defer testing.allocator.free(tsv);
    try testing.expectEqualStrings("ripgrep\t14.1.1\tSearch tool\nweird\t1.0\ttab here\n", tsv);
}

test "buildIndexTsv - cask entries use token and version" {
    const json =
        \\[{"token":"raycast","name":["Raycast"],"version":"1.101.1","desc":"Launcher"}]
    ;
    const tsv = try buildIndexTsv(testing.allocator, json, .cask);
    defer testing.allocator.free(tsv);
    try testing.expectEqualStrings("raycast\t1.101.1\tLauncher\n", tsv);
}

test "searchIndexTsv - matches name and desc case-insensitively" {
    const tsv = "ripgrep\t14.1.1\tFast search tool\nfd\t10.3.0\tFind alternative\n";
    var results: std.ArrayList(SearchResult) = .empty;
    defer {
        for (results.items) |r| r.deinit(testing.allocator);
        results.deinit(testing.allocator);
    }
    try searchIndexTsv(testing.allocator, tsv, "search", false, &results);
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("ripgrep", results.items[0].name);
    try testing.expectEqualStrings("14.1.1", results.items[0].version);

    try searchIndexTsv(testing.allocator, tsv, "fd", false, &results);
    try testing.expectEqual(@as(usize, 2), results.items.len);
}

test "searchIndexTsv - tolerates malformed trailing line" {
    const tsv = "good\t1.0\tdesc\ntorn-line-no-tabs";
    var results: std.ArrayList(SearchResult) = .empty;
    defer {
        for (results.items) |r| r.deinit(testing.allocator);
        results.deinit(testing.allocator);
    }
    try searchIndexTsv(testing.allocator, tsv, "good", false, &results);
    try testing.expectEqual(@as(usize, 1), results.items.len);
}
