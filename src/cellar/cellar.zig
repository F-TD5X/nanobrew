// nanobrew — Cellar materialization via platform-specific COW copy
//
// Materializes package kegs from the store into:
//   /opt/nanobrew/prefix/Cellar/<name>/<version>/
//
// macOS: Uses clonefile(2) for zero-cost APFS copy-on-write.
// Linux: Uses cp --reflink=auto for btrfs/xfs COW, regular cp otherwise.

const std = @import("std");
const paths = @import("../platform/paths.zig");
const copy = @import("../platform/copy.zig");
const purge = @import("../platform/purge.zig");

/// Materialize a keg from the store into the Cellar.
pub fn materialize(io: std.Io, sha256: []const u8, name: []const u8, version: []const u8) !void {
    var name_dir_buf: [512]u8 = undefined;
    const name_dir = std.fmt.bufPrint(&name_dir_buf, "{s}/{s}/{s}", .{ paths.STORE_DIR, sha256, name }) catch return error.PathTooLong;

    var ver_buf: [256]u8 = undefined;
    const actual_version = detectStoreVersion(name_dir, version, &ver_buf) orelse version;

    var src_buf: [512]u8 = undefined;
    const src_dir = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ name_dir, actual_version }) catch return error.PathTooLong;

    var dest_buf: [512]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, actual_version }) catch return error.PathTooLong;

    // Ensure parent dir exists
    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ paths.CELLAR_DIR, name }) catch return error.PathTooLong;
    std.Io.Dir.createDirAbsolute(io, parent_dir, .default_dir) catch {};

    // Remove existing keg if present
    std.Io.Dir.cwd().deleteTree(io, dest_dir) catch {};

    // Try COW clone first (macOS clonefile / Linux: always false -> fallback)
    var src_z: [512:0]u8 = undefined;
    @memcpy(src_z[0..src_dir.len], src_dir);
    src_z[src_dir.len] = 0;

    var dst_z: [512:0]u8 = undefined;
    @memcpy(dst_z[0..dest_dir.len], dest_dir);
    dst_z[dest_dir.len] = 0;

    if (copy.cloneTree(&src_z, &dst_z)) return;

    // Fallback: cp (--reflink=auto on Linux, plain -R on macOS).
    // The caller's io must be used here; std.Io.Threaded.global_single_threaded
    // cannot be passed to std.process.run under Zig 0.16 (vtable mismatch
    // surfaces as error.CopyFailed). See issue #276.
    try copy.cpFallback(io, src_dir, dest_dir);
}

/// Find the actual installed version for a keg in the Cellar.
pub fn detectKegVersion(name: []const u8, version: []const u8, result_buf: *[256]u8) ?[]const u8 {
    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ paths.CELLAR_DIR, name }) catch return null;
    return detectStoreVersion(parent_dir, version, result_buf);
}

/// Remove a keg from the Cellar.
pub fn remove(name: []const u8, version: []const u8) !void {
    const lib_io = paths.safe_io;
    var buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, version }) catch return error.PathTooLong;
    if (std.Io.Dir.accessAbsolute(lib_io, keg_dir, .{})) |_| {
        purge.deferTreeRemoval(lib_io, keg_dir);
    } else |_| {}

    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ paths.CELLAR_DIR, name }) catch return;
    if (std.Io.Dir.openDirAbsolute(lib_io, parent_dir, .{ .iterate = true })) |d| {
        var dir = d;
        var iter = dir.iterate();
        const empty = (iter.next(lib_io) catch null) == null;
        dir.close(lib_io);
        if (empty) {
            std.Io.Dir.deleteDirAbsolute(lib_io, parent_dir) catch {};
        }
    } else |_| {}
}

fn detectStoreVersion(name_dir: []const u8, version: []const u8, result_buf: *[256]u8) ?[]const u8 {
    const lib_io = paths.safe_io;
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
