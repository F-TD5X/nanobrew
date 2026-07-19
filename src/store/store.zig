// nanobrew — Content-addressable store
//
// Extracted bottle contents live at:
//   /opt/nanobrew/store/<sha256>/
//
// Each entry contains the full unpacked Homebrew keg.
// The store is deduplicated: same SHA256 = same content.

const std = @import("std");
const tar = @import("../extract/tar.zig");
const paths = @import("../platform/paths.zig");

const STORE_DIR = paths.STORE_DIR;
const STORE_RELOCATED_DIR = paths.STORE_RELOCATED_DIR;
const CELLAR_DIR = paths.CELLAR_DIR;

/// Validate that sha256 is exactly 64 lowercase hex characters.
/// This prevents path traversal attacks when sha256 is used as a path component.
pub fn isValidSha256(sha256: []const u8) bool {
    if (sha256.len != 64) return false;
    for (sha256) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// Ensure a store entry exists for the given SHA256.
/// If not, extract the blob tarball into the store.
/// `io` must be threadsafe when called from a parallel install worker.
pub fn ensureEntry(alloc: std.mem.Allocator, io: std.Io, blob_path: []const u8, sha256: []const u8) !void {
    if (!isValidSha256(sha256)) return error.InvalidSha256;

    var dir_buf: [512]u8 = undefined;
    const store_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return error.PathTooLong;

    // Already extracted?
    std.Io.Dir.accessAbsolute(io, store_path, .{}) catch {
        // Need to extract
        try tar.extractToStore(alloc, io, blob_path, sha256);
        return;
    };
}

/// Check if a store entry exists.
/// `io` must be threadsafe when called from a parallel install worker.
pub fn hasEntry(io: std.Io, sha256: []const u8) bool {
    if (!isValidSha256(sha256)) return false;

    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return false;
    std.Io.Dir.accessAbsolute(io, p, .{}) catch return false;
    return true;
}

/// Get the store path for an entry.
pub fn entryPath(sha256: []const u8, buf: []u8) []const u8 {
    if (!isValidSha256(sha256)) return "";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch "";
}

/// Find the version directory contained in a raw store entry.
/// `io` must be threadsafe when called from a parallel install worker.
pub fn detectEntryVersion(io: std.Io, sha256: []const u8, name: []const u8, version: []const u8, result_buf: *[256]u8) ?[]const u8 {
    if (!isValidSha256(sha256)) return null;

    var name_dir_buf: [512]u8 = undefined;
    const name_dir = std.fmt.bufPrint(&name_dir_buf, "{s}/{s}/{s}", .{ STORE_DIR, sha256, name }) catch return null;

    const lib_io = io;
    var exact_buf: [512]u8 = undefined;
    const exact = std.fmt.bufPrint(&exact_buf, "{s}/{s}", .{ name_dir, version }) catch return null;
    if (std.Io.Dir.openDirAbsolute(lib_io, exact, .{})) |d| {
        var dir = d;
        dir.close(lib_io);
        return version;
    } else |_| {}

    if (std.Io.Dir.openDirAbsolute(lib_io, name_dir, .{ .iterate = true })) |d| {
        var dir = d;
        var iter = dir.iterate();
        while (iter.next(lib_io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.startsWith(u8, entry.name, version)) {
                if (entry.name.len == version.len or
                    (entry.name.len > version.len and entry.name[version.len] == '_'))
                {
                    if (entry.name.len <= result_buf.len) {
                        @memcpy(result_buf[0..entry.name.len], entry.name);
                        dir.close(lib_io);
                        return result_buf[0..entry.name.len];
                    }
                }
            }
        }
        dir.close(lib_io);
    } else |_| {}

    return null;
}

/// Remove a store entry (when refcount drops to 0).
pub fn removeEntry(io: std.Io, sha256: []const u8) void {
    if (!isValidSha256(sha256)) return;

    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return;
    std.Io.Dir.cwd().deleteTree(io, p) catch {};
}

// ── Relocated store ───────────────────────────────────────────────────────────
// After the first install of a package, the Cellar keg has all @@HOMEBREW_*@@
// placeholders replaced and Mach-O load commands fixed. We clonefile that
// already-processed tree into store-relocated/<sha256>/ so subsequent reinstalls
// can skip both text-scan and install_name_tool entirely.

/// Check if a post-relocation snapshot exists for this blob.
pub fn hasRelocatedEntry(io: std.Io, sha256: []const u8) bool {
    if (!isValidSha256(sha256)) return false;

    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ STORE_RELOCATED_DIR, sha256 }) catch return false;
    std.Io.Dir.accessAbsolute(io, p, .{}) catch return false;
    return true;
}

/// Snapshot the already-relocated keg from Cellar into store-relocated/<sha256>/.
/// Called once after a successful relocate+placeholder pass.
/// Uses APFS clonefile so this is near-instantaneous and zero marginal disk cost.
/// Layout: store-relocated/<sha256>/ contains the full keg tree directly.
pub fn saveRelocatedEntry(io: std.Io, sha256: []const u8, name: []const u8, version: []const u8) !void {
    if (!isValidSha256(sha256)) return error.InvalidSha256;

    // src = Cellar/<name>/<version>/  (already fully relocated)
    var src_buf: [512:0]u8 = undefined;
    const src_dir = std.fmt.bufPrint(&src_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;
    src_buf[src_dir.len] = 0;

    // dest = store-relocated/<sha256>/
    var dest_buf: [512:0]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ STORE_RELOCATED_DIR, sha256 }) catch return error.PathTooLong;
    dest_buf[dest_dir.len] = 0;

    // Already saved (concurrent installs, or we're upgrading)
    if (std.Io.Dir.accessAbsolute(io, dest_dir, .{})) {
        return; // already exists, nothing to do
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    std.Io.Dir.createDirAbsolute(io, STORE_RELOCATED_DIR, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // cloneTree from Cellar → store-relocated (APFS copy-on-write, ~0ms on APFS)
    const copy = @import("../platform/copy.zig");
    if (!copy.cloneTree(&src_buf, &dest_buf)) {
        // Fallback path uses std.process.run; passing the caller's io is
        // required under Zig 0.16 (see issue #276).
        try copy.cpFallback(io, src_dir, dest_dir);
    }
}

/// Materialize a package from store-relocated/<sha256>/ into Cellar/<name>/<version>/.
/// This is the fast reinstall path: no relocation needed.
pub fn materializeFromRelocated(io: std.Io, sha256: []const u8, name: []const u8, version: []const u8) !void {
    if (!isValidSha256(sha256)) return error.InvalidSha256;

    // src = store-relocated/<sha256>/
    var src_buf: [512:0]u8 = undefined;
    const src_dir = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ STORE_RELOCATED_DIR, sha256 }) catch return error.PathTooLong;
    src_buf[src_dir.len] = 0;

    // dest = Cellar/<name>/<version>/
    var dest_buf: [512:0]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;
    dest_buf[dest_dir.len] = 0;

    // Ensure parent dir exists
    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ CELLAR_DIR, name }) catch return error.PathTooLong;
    std.Io.Dir.createDirAbsolute(io, parent, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Remove existing keg if present (fresh reinstall; deferred removal)
    const purge = @import("../platform/purge.zig");
    if (std.Io.Dir.accessAbsolute(io, dest_dir, .{})) |_| {
        purge.deferTreeRemoval(io, dest_dir);
    } else |_| {}

    const copy = @import("../platform/copy.zig");
    if (!copy.cloneTree(&src_buf, &dest_buf)) {
        try copy.cpFallback(io, src_dir, dest_dir);
    }
}

/// Return store-relocated path for an entry.
pub fn relocatedEntryPath(sha256: []const u8, buf: []u8) []const u8 {
    if (!isValidSha256(sha256)) return "";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ STORE_RELOCATED_DIR, sha256 }) catch "";
}

/// Remove the post-relocation snapshot for a sha256.
pub fn removeRelocatedEntry(io: std.Io, sha256: []const u8) void {
    if (!isValidSha256(sha256)) return;

    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ STORE_RELOCATED_DIR, sha256 }) catch return;
    std.Io.Dir.cwd().deleteTree(io, p) catch {};
}

const testing = std.testing;

test "entryPath - formats store path correctly" {
    var buf: [512]u8 = undefined;
    const valid_sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const p = entryPath(valid_sha, &buf);
    try testing.expectEqualStrings("/opt/nanobrew/store/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", p);
}

test "entryPath - invalid sha returns empty string" {
    var buf: [512]u8 = undefined;
    const p = entryPath("", &buf);
    try testing.expectEqualStrings("", p);
}

test "entryPath - path traversal sha returns empty string" {
    var buf: [512]u8 = undefined;
    const p = entryPath("../../etc/passwd", &buf);
    try testing.expectEqualStrings("", p);
}
