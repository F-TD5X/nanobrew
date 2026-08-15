// nanobrew — deferred tree removal
//
// `nb remove` of a large keg (openssl@3 has ~7.6k files) used to pay a
// serial deleteTree on the critical path (~400ms+ on a loaded machine).
// Instead, the tree is atomically renamed into `Cellar/.purge/` and the
// real unlink work is handed to a detached `rm -rf`: the command returns
// immediately and the reaper is reparented to launchd when nb exits (the
// same model as the background DMG detach). The reaper empties the whole
// `.purge/` dir so trees orphaned by a killed reaper are collected next
// time. On any failure this falls back to a synchronous deleteTree.

const std = @import("std");
const paths = @import("paths.zig");

/// Directory inside the Cellar where trees pending deletion are parked.
pub const PURGE_DIR = paths.CELLAR_DIR ++ "/.purge";

fn isSafeCellarChild(abs_path: []const u8) bool {
    const prefix = paths.CELLAR_DIR ++ "/";
    if (!std.mem.startsWith(u8, abs_path, prefix)) return false;
    const rest = abs_path[prefix.len..];
    // Only <name>/<version> keg roots (one slash, no dot-tricks).
    var slashes: usize = 0;
    for (rest) |c| {
        if (c == '/') slashes += 1;
    }
    if (slashes != 1) return false;
    if (std.mem.indexOf(u8, rest, "..") != null) return false;
    if (rest.len == 0 or rest[0] == '.') return false;
    return true;
}

/// Delete `abs_path` off the critical path when it is a keg root inside the
/// Cellar; otherwise delete synchronously. Never fails the caller.
pub fn deferTreeRemoval(io: std.Io, abs_path: []const u8) void {
    if (!isSafeCellarChild(abs_path)) {
        std.Io.Dir.cwd().deleteTree(io, abs_path) catch {};
        return;
    }

    std.Io.Dir.createDirAbsolute(io, PURGE_DIR, .default_dir) catch {};

    var src_z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (abs_path.len > src_z.len) {
        std.Io.Dir.cwd().deleteTree(io, abs_path) catch {};
        return;
    }
    @memcpy(src_z[0..abs_path.len], abs_path);
    src_z[abs_path.len] = 0;

    var trash_buf: [std.fs.max_path_bytes + 64:0]u8 = undefined;
    const trash = std.fmt.bufPrint(&trash_buf, "{s}/{s}.{d}", .{
        PURGE_DIR,
        std.fs.path.basename(abs_path),
        std.c.getpid(),
    }) catch {
        std.Io.Dir.cwd().deleteTree(io, abs_path) catch {};
        return;
    };

    var trash_z: [std.fs.max_path_bytes + 64:0]u8 = undefined;
    @memcpy(trash_z[0..trash.len], trash);
    trash_z[trash.len] = 0;

    if (std.c.rename(&src_z, &trash_z) != 0) {
        // Park failed (e.g. cross-device — shouldn't happen inside the
        // Cellar): delete synchronously like before.
        std.Io.Dir.cwd().deleteTree(io, abs_path) catch {};
        return;
    }

    // Detached reaper: reaped by launchd after nb exits. Only this tree is
    // removed (no shell, no glob); any trees orphaned by a killed reaper are
    // collected by `nb cleanup`, which sweeps .purge synchronously.
    _ = std.process.spawn(io, .{
        .argv = &.{ "/bin/rm", "-rf", trash },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        std.Io.Dir.cwd().deleteTree(io, trash) catch {};
        return;
    };
}

/// Synchronously empty `.purge/` — the safety net for reapers that never ran
/// (killed, or /bin/rm missing). Cheap no-op when the dir is empty/absent.
pub fn sweep(io: std.Io) void {
    var dir = std.Io.Dir.openDirAbsolute(io, PURGE_DIR, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ PURGE_DIR, entry.name }) catch continue;
        std.Io.Dir.cwd().deleteTree(io, p) catch {};
    }
}
