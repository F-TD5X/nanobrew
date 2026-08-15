// nanobrew — Search API
//
// Fetches formula and cask lists from Homebrew API and performs
// case-insensitive substring matching on name and description.

const std = @import("std");
const builtin = @import("builtin");
const fetch = @import("../net/fetch.zig");
const FORMULA_LIST_URL = "https://formulae.brew.sh/api/formula.json";
const CASK_LIST_URL = "https://formulae.brew.sh/api/cask.json";
const paths = @import("../platform/paths.zig");
const CACHE_DIR = paths.API_CACHE_DIR;
const FORMULA_CACHE = CACHE_DIR ++ "/_formula_list.json";
const CASK_CACHE = CACHE_DIR ++ "/_cask_list.json";
// v5 adds platform-aware formula dependency lists plus a validated row-count
// footer and atomic writes, so a torn sidecar cannot make a miss authoritative.
const FORMULA_IDX = FORMULA_CACHE ++ ".idx.v5";
const CASK_IDX = CASK_CACHE ++ ".idx.v5";
const INDEX_FOOTER_PREFIX = "#nanobrew-index-v5\t";
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

fn acquireCacheLock(idx_path: []const u8, lock_buf: []u8) !std.Io.File {
    const lock_path = try std.fmt.bufPrint(lock_buf, "{s}.lock", .{idx_path});
    if (std.Io.Dir.createFileAbsolute(paths.safe_io, lock_path, .{
        .truncate = false,
        .lock = .exclusive,
    })) |file| {
        return file;
    } else |_| {
        // First run: the cache directory may not exist yet. Create it on this
        // slow path only instead of paying a mkdir walk on every lock.
        std.Io.Dir.createDirAbsolute(paths.safe_io, CACHE_DIR, .default_dir) catch {};
        return std.Io.Dir.createFileAbsolute(paths.safe_io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
        });
    }
}

/// Cached bulk formula list (1h TTL, shared with `nb outdated`/`upgrade`).
pub fn cachedFormulaListJson(alloc: std.mem.Allocator) ![]u8 {
    // Lock-free fast path: a fresh cache needs no coordination. Writes are
    // atomic renames, so readers never observe a partial file.
    if (readCachedFile(alloc, FORMULA_CACHE)) |data| return data;
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock = try acquireCacheLock(FORMULA_IDX, &lock_buf);
    defer lock.close(paths.safe_io);
    return fetchCachedList(alloc, FORMULA_LIST_URL, FORMULA_CACHE);
}

/// Cached bulk cask list (1h TTL, shared with `nb outdated`/`upgrade`).
pub fn cachedCaskListJson(alloc: std.mem.Allocator) ![]u8 {
    // Lock-free fast path: a fresh cache needs no coordination. Writes are
    // atomic renames, so readers never observe a partial file.
    if (readCachedFile(alloc, CASK_CACHE)) |data| return data;
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock = try acquireCacheLock(CASK_IDX, &lock_buf);
    defer lock.close(paths.safe_io);
    return fetchCachedList(alloc, CASK_LIST_URL, CASK_CACHE);
}

/// Alias resolution also refreshes the shared formula JSON. Publish it under
/// the same lock used by sidecar builders so readers never observe mixed writers.
pub fn writeFormulaListCacheAtomic(data: []const u8) void {
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock = acquireCacheLock(FORMULA_IDX, &lock_buf) catch return;
    defer lock.close(paths.safe_io);
    writeFileAtomic(FORMULA_CACHE, data);
}

fn fetchCachedList(alloc: std.mem.Allocator, url: []const u8, cache_path: []const u8) ![]u8 {
    // Check cache with 1-hour TTL
    if (readCachedFile(alloc, cache_path)) |data| return data;

    // Fetch from network (native HTTP, no curl)
    const body = fetch.get(alloc, url) catch return error.FetchFailed;

    // Publish atomically while the caller holds the matching cache lock.
    writeFileAtomic(cache_path, body);

    return body;
}

/// TSV index sidecar — one `name\tversion\tdesc\tstart\tend\tdeps\n` row per entry.
/// Far smaller than the source JSON and trivially parseable, so `nb search`
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

    // Lock-free fast path: fresh JSON cache + sidecar at least as new. The
    // sidecar is published by atomic rename and re-validated on every read,
    // so readers never need the writer's lock.
    if (fileMtimeNs(json_path)) |json_mtime| {
        const now_ts = std.Io.Timestamp.now(lib_io, .real);
        if (now_ts.nanoseconds - json_mtime <= CACHE_TTL_NS) {
            if (fileMtimeNs(idx_path)) |idx_mtime| {
                if (idx_mtime >= json_mtime) {
                    if (readFileAlloc(alloc, idx_path)) |buf| {
                        if (validateIndexTsv(buf)) return buf;
                        alloc.free(buf);
                    }
                }
            }
            // JSON is fresh but the sidecar is missing/stale/invalid: rebuild
            // from disk, serialized with other writers.
            var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
            const lock = try acquireCacheLock(idx_path, &lock_buf);
            defer lock.close(lib_io);
            // Re-check under the lock: another process may have rebuilt it.
            if (fileMtimeNs(idx_path)) |idx_mtime| {
                if (idx_mtime >= json_mtime) {
                    if (readFileAlloc(alloc, idx_path)) |buf| {
                        if (validateIndexTsv(buf)) return buf;
                        alloc.free(buf);
                    }
                }
            }
            if (readFileAlloc(alloc, json_path)) |json| {
                defer alloc.free(json);
                return buildAndWriteIndexTsv(alloc, json, idx_path, kind);
            }
        }
    }

    // JSON cache is missing/stale: refetch (writes the JSON cache), then build.
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock = try acquireCacheLock(idx_path, &lock_buf);
    defer lock.close(lib_io);
    const json = try fetchCachedList(alloc, url, json_path);
    defer alloc.free(json);
    return buildAndWriteIndexTsv(alloc, json, idx_path, kind);
}

/// Byte range of one entry inside the bulk JSON, from the TSV sidecar.
pub const EntryRange = struct { start: usize, end: usize };

/// Find a formula's byte range in the cached bulk formula list. Returns null
/// unless the bulk JSON cache is fresh and the sidecar matches it — callers
/// fall back to a network fetch.
pub fn bulkFormulaEntryJson(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    return bulkEntryJson(alloc, FORMULA_CACHE, FORMULA_IDX, name);
}

/// Return the bulk formula entry only when its source JSON is newer than a
/// per-name cache. This prevents a still-fresh stale per-name entry from hiding
/// a formula revision published by a newer bulk refresh.
pub fn bulkFormulaEntryJsonNewerThan(alloc: std.mem.Allocator, name: []const u8, other_path: []const u8) ?[]u8 {
    const bulk_mtime = fileMtimeNs(FORMULA_CACHE) orelse return null;
    const other_mtime = fileMtimeNs(other_path) orelse return bulkFormulaEntryJson(alloc, name);
    if (bulk_mtime <= other_mtime) return null;
    return bulkFormulaEntryJson(alloc, name);
}

/// Cask analogue of bulkFormulaEntryJson, keyed by token.
pub fn bulkCaskEntryJson(alloc: std.mem.Allocator, token: []const u8) ?[]u8 {
    return bulkEntryJson(alloc, CASK_CACHE, CASK_IDX, token);
}

/// Process-wide memo of a TSV sidecar. bulkEntryJson runs once per formula
/// lookup (a `nb deps`/`leaves` run does dozens to hundreds), and re-reading
/// the same sidecar for every lookup dominated local resolve time. Published
/// slices are never freed, so racing readers are safe; a stale memo is only
/// replaced (leaking the old bytes) when the file's mtime changes, which a
/// short-lived CLI does at most a handful of times.
const IdxMemo = struct {
    path: []const u8,
    mtime: i96,
    bytes: []const u8,
    /// name -> byte range into the bulk JSON; keys point into `bytes`.
    map: std.StringHashMap(EntryRange),
};
var g_idx_memo_mutex: std.atomic.Mutex = .unlocked;
var g_idx_memos: [2]?*IdxMemo = .{ null, null };

/// One pass over the sidecar building a name -> range map so each per-name
/// lookup after the first is O(1) instead of a full TSV scan.
fn buildEntryMap(pa: std.mem.Allocator, tsv: []const u8) ?std.StringHashMap(EntryRange) {
    var map = std.StringHashMap(EntryRange).init(pa);
    var line_iter = std.mem.splitScalar(u8, tsv, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const name = cols.next() orelse continue;
        _ = cols.next(); // version
        _ = cols.next(); // desc
        const start_s = cols.next() orelse continue;
        const end_s = cols.next() orelse continue;
        const start = std.fmt.parseInt(usize, start_s, 10) catch continue;
        const end = std.fmt.parseInt(usize, end_s, 10) catch continue;
        const gop = map.getOrPut(name) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{ .start = start, .end = end };
    }
    if (map.count() == 0) {
        map.deinit();
        return null;
    }
    return map;
}

fn readIdxMemoized(idx_path: []const u8, idx_mtime: i96) ?*const IdxMemo {
    const pa = std.heap.page_allocator;
    while (!g_idx_memo_mutex.tryLock()) std.atomic.spinLoopHint();
    defer g_idx_memo_mutex.unlock();
    for (&g_idx_memos) |*slot| {
        if (slot.*) |m| {
            if (std.mem.eql(u8, m.path, idx_path)) {
                if (m.mtime == idx_mtime) return m;
                // Stale sidecar: replace the memo, intentionally leaking the
                // old one — another thread may still be reading it.
                slot.* = null;
                break;
            }
        }
    }
    const bytes = readFileAlloc(pa, idx_path) orelse return null;
    const map = buildEntryMap(pa, bytes) orelse {
        pa.free(bytes);
        return null;
    };
    const path_copy = pa.dupe(u8, idx_path) catch {
        pa.free(bytes);
        return null;
    };
    const memo = pa.create(IdxMemo) catch {
        pa.free(bytes);
        pa.free(path_copy);
        return null;
    };
    memo.* = .{ .path = path_copy, .mtime = idx_mtime, .bytes = bytes, .map = map };
    for (&g_idx_memos) |*slot| {
        if (slot.* == null) {
            slot.* = memo;
            return memo;
        }
    }
    // Both slots hold the other sidecar (formula vs cask); evict slot 0 by
    // leaking it — readers may still hold its pointer.
    g_idx_memos[0] = memo;
    return memo;
}

fn bulkEntryJson(alloc: std.mem.Allocator, json_path: []const u8, idx_path: []const u8, name: []const u8) ?[]u8 {
    const lib_io = paths.safe_io;
    const json_mtime = fileMtimeNs(json_path) orelse return null;
    const now_ts = std.Io.Timestamp.now(lib_io, .real);
    if (now_ts.nanoseconds - json_mtime > CACHE_TTL_NS) return null;
    const idx_mtime = fileMtimeNs(idx_path) orelse return null;
    if (idx_mtime < json_mtime) return null;

    const memo = readIdxMemoized(idx_path, idx_mtime) orelse return null;
    const range = memo.map.get(name) orelse return null;

    // pread exactly the entry's bytes out of the bulk JSON.
    const file = std.Io.Dir.openFileAbsolute(lib_io, json_path, .{}) catch return null;
    defer file.close(lib_io);
    const st = file.stat(lib_io) catch return null;
    if (range.end > st.size or range.start >= range.end) return null;
    const buf = alloc.alloc(u8, range.end - range.start) catch return null;
    const n = file.readPositionalAll(lib_io, buf, range.start) catch {
        alloc.free(buf);
        return null;
    };
    if (n != buf.len or buf.len == 0 or buf[0] != '{' or buf[buf.len - 1] != '}') {
        alloc.free(buf);
        return null;
    }
    return buf;
}

/// Exact-name lookup in the TSV sidecar; offsets come from columns 4/5.
fn findEntryRange(tsv: []const u8, name: []const u8) ?EntryRange {
    var line_iter = std.mem.splitScalar(u8, tsv, '\n');
    while (line_iter.next()) |line| {
        if (line.len <= name.len or line[name.len] != '\t') continue;
        if (!std.mem.eql(u8, line[0..name.len], name)) continue;
        // name\tversion\tdesc\tstart\tend
        var cols = std.mem.splitScalar(u8, line, '\t');
        _ = cols.next(); // name
        _ = cols.next(); // version
        _ = cols.next(); // desc
        const start_s = cols.next() orelse return null;
        const end_s = cols.next() orelse return null;
        const start = std.fmt.parseInt(usize, start_s, 10) catch return null;
        const end = std.fmt.parseInt(usize, end_s, 10) catch return null;
        return .{ .start = start, .end = end };
    }
    return null;
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

fn validateIndexTsv(tsv: []const u8) bool {
    if (tsv.len == 0 or tsv[tsv.len - 1] != '\n') return false;
    const without_final_newline = tsv[0 .. tsv.len - 1];
    const footer_start = if (std.mem.lastIndexOfScalar(u8, without_final_newline, '\n')) |idx| idx + 1 else 0;
    const footer = without_final_newline[footer_start..];
    if (!std.mem.startsWith(u8, footer, INDEX_FOOTER_PREFIX)) return false;
    const expected = std.fmt.parseInt(usize, footer[INDEX_FOOTER_PREFIX.len..], 10) catch return false;
    if (expected == 0) return false;

    // SIMD counts over the body: rows are machine-generated as exactly six
    // tab-separated columns (tabs in desc are blanked at build time), so a
    // truncated, torn, or column-mangled sidecar cannot match both counts.
    // (Sidecar writes are atomic renames, so a partial file can only ever
    // come from a crash mid-publish.)
    const body = tsv[0..footer_start];
    const actual = std.mem.count(u8, body, "\n");
    if (actual != expected) return false;
    const tabs = std.mem.count(u8, body, "\t");
    return tabs == 5 * expected;
}

fn writeFileAtomic(idx_path: []const u8, tsv: []const u8) void {
    const io = paths.safe_io;
    std.Io.Dir.createDirAbsolute(io, CACHE_DIR, .default_dir) catch {};
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}.{d}", .{
        idx_path, std.c.getpid(), std.Thread.getCurrentId(),
    }) catch return;
    const file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch return;
    file.writeStreamingAll(io, tsv) catch {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        return;
    };
    file.sync(io) catch {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        return;
    };
    file.close(io);
    std.Io.Dir.renameAbsolute(tmp_path, idx_path, io) catch {
        std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    };
}

fn buildAndWriteIndexTsv(alloc: std.mem.Allocator, json: []const u8, idx_path: []const u8, kind: ListKind) ![]u8 {
    const tsv = try buildIndexTsv(alloc, json, kind);
    if (!validateIndexTsv(tsv)) {
        alloc.free(tsv);
        return error.InvalidIndex;
    }
    writeFileAtomic(idx_path, tsv);
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

    var row_count: usize = 0;
    while (true) {
        switch (try scanner.next()) {
            .array_end => break,
            .object_begin => {},
            else => return error.UnexpectedJson,
        }
        // Byte range of this entry within the source JSON — the cursor sits
        // just past the consumed structural token on both ends.
        const entry_start = scanner.cursor - 1;

        var name: []const u8 = "";
        var desc: []const u8 = "";
        var version: []const u8 = "";
        var revision: u32 = 0;
        var dependencies: std.ArrayList(u8) = .empty;
        defer dependencies.deinit(alloc);
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
            } else if (kind == .formula and
                (std.mem.eql(u8, key, "dependencies") or
                    (builtin.os.tag == .macos and std.mem.eql(u8, key, "uses_from_macos"))))
            {
                if ((try scanner.next()) != .array_begin) return error.UnexpectedJson;
                while (true) {
                    const dep_token = try scanner.nextAlloc(alloc, .alloc_if_needed);
                    switch (dep_token) {
                        .array_end => break,
                        .string => |dep| {
                            if (dependencies.items.len > 0) try dependencies.append(alloc, ',');
                            try appendSanitized(&dependencies, alloc, dep);
                        },
                        .allocated_string => |dep| {
                            defer alloc.free(dep);
                            if (dependencies.items.len > 0) try dependencies.append(alloc, ',');
                            try appendSanitized(&dependencies, alloc, dep);
                        },
                        // Homebrew also uses objects such as {"bison":"build"}
                        // in uses_from_macos. Formula parsing ignores those
                        // build-only entries, so mirror that behavior here.
                        .object_begin => while (true) {
                            const object_token = try scanner.nextAlloc(alloc, .alloc_if_needed);
                            switch (object_token) {
                                .object_end => break,
                                .string => try scanner.skipValue(),
                                .allocated_string => |object_key| {
                                    defer alloc.free(object_key);
                                    try scanner.skipValue();
                                },
                                else => return error.UnexpectedJson,
                            }
                        },
                        else => return error.UnexpectedJson,
                    }
                }
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
            } else if (kind == .formula and std.mem.eql(u8, key, "revision")) {
                const revision_token = try scanner.nextAlloc(alloc, .alloc_if_needed);
                switch (revision_token) {
                    .number => |n| revision = std.fmt.parseInt(u32, n, 10) catch 0,
                    .allocated_number => |n| {
                        defer alloc.free(n);
                        revision = std.fmt.parseInt(u32, n, 10) catch 0;
                    },
                    else => return error.UnexpectedJson,
                }
            } else if (kind == .cask and std.mem.eql(u8, key, "version")) {
                captureString(&scanner, alloc, &version, &version_owned) catch return error.UnexpectedJson;
            } else {
                try scanner.skipValue();
            }
        }

        const entry_end = scanner.cursor;

        if (name.len == 0) continue;
        try out.appendSlice(alloc, name);
        try out.append(alloc, '\t');
        try appendSanitized(&out, alloc, version);
        if (kind == .formula and revision > 0) try out.print(alloc, "_{d}", .{revision});
        try out.append(alloc, '\t');
        try appendSanitized(&out, alloc, desc);
        try out.print(alloc, "\t{d}\t{d}\t", .{ entry_start, entry_end });
        try out.appendSlice(alloc, dependencies.items);
        try out.append(alloc, '\n');
        row_count += 1;
    }

    try out.print(alloc, "{s}{d}\n", .{ INDEX_FOOTER_PREFIX, row_count });
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
        // Column 3 is desc; trailing columns (entry byte offsets) are for the
        // bulk-slice formula fetch, not for search.
        const desc_end = std.mem.indexOfScalarPos(u8, line, tab2 + 1, '\t') orelse line.len;
        const desc = line[tab2 + 1 .. desc_end];
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

test "buildIndexTsv - formula entries become rows with valid entry offsets" {
    const json =
        \\[{"name":"ripgrep","desc":"Search tool","versions":{"stable":"14.1.1","head":"HEAD"},"revision":0,"dependencies":["pcre2"],"uses_from_macos":["libedit",{"bison":"build"}]},
        \\ {"name":"weird","desc":"tab\there","versions":{"stable":"1.0"},"revision":2,"bottle":{"stable":{"rebuild":1}}}]
    ;
    const tsv = try buildIndexTsv(testing.allocator, json, .formula);
    defer testing.allocator.free(tsv);

    // Rows are name\tversion\tdesc\tstart\tend\tdeps; desc sanitized.
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    const row1 = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, row1, "ripgrep\t14.1.1\tSearch tool\t"));
    var row1_cols = std.mem.splitScalar(u8, row1, '\t');
    for (0..5) |_| _ = row1_cols.next();
    try testing.expectEqualStrings(if (builtin.os.tag == .macos) "pcre2,libedit" else "pcre2", row1_cols.next().?);
    const row2 = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, row2, "weird\t1.0_2\ttab here\t"));

    // The offsets must slice back to exactly the entry's JSON object.
    const r1 = findEntryRange(tsv, "ripgrep").?;
    const slice1 = json[r1.start..r1.end];
    try testing.expect(slice1[0] == '{' and slice1[slice1.len - 1] == '}');
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, slice1, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("ripgrep", parsed.value.object.get("name").?.string);

    const r2 = findEntryRange(tsv, "weird").?;
    const slice2 = json[r2.start..r2.end];
    const parsed2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, slice2, .{});
    defer parsed2.deinit();
    try testing.expectEqualStrings("weird", parsed2.value.object.get("name").?.string);

    // Prefix names must not match other entries' rows.
    try testing.expect(findEntryRange(tsv, "rip") == null);
    try testing.expect(findEntryRange(tsv, "nope") == null);
}

test "buildIndexTsv - cask entries use token and version" {
    const json =
        \\[{"token":"raycast","name":["Raycast"],"version":"1.101.1","desc":"Launcher"}]
    ;
    const tsv = try buildIndexTsv(testing.allocator, json, .cask);
    defer testing.allocator.free(tsv);
    try testing.expect(std.mem.startsWith(u8, tsv, "raycast\t1.101.1\tLauncher\t"));
    const r = findEntryRange(tsv, "raycast").?;
    try testing.expect(json[r.start] == '{' and json[r.end - 1] == '}');
    try testing.expect(validateIndexTsv(tsv));
}

test "validateIndexTsv rejects torn and count-mismatched sidecars" {
    const valid = "one\t1.0\tdesc\t0\t1\tdep\ntwo\t2.0\tdesc\t2\t3\t\n#nanobrew-index-v5\t2\n";
    try testing.expect(validateIndexTsv(valid));
    try testing.expect(!validateIndexTsv(valid[0 .. valid.len - 1]));
    try testing.expect(!validateIndexTsv("one\t1.0\tdesc\t0\t1\t\n#nanobrew-index-v5\t2\n"));
    try testing.expect(!validateIndexTsv("one\t1.0\n#nanobrew-index-v5\t1\n"));
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
