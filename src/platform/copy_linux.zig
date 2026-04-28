// nanobrew — Linux native recursive tree copy
//
// Replaces the `cp --reflink=auto -R` subprocess in `cpFallback` with an
// in-process walker. For each regular file we attempt:
//
//   1. ioctl(FICLONE)              — instant COW on btrfs/xfs (matches
//                                    `cp --reflink=auto`).
//   2. std.Io.Dir.copyFile         — uses copy_file_range(2) under the hood
//                                    on Linux for in-kernel zero-copy on
//                                    same-FS copies and falls back to
//                                    sendfile/read+write otherwise.
//
// Directories are recreated with mkdir; symlinks are recreated via readlink
// + symlink. Hardlinks are materialized as separate files (matches `cp -R`
// default — without `-l` cp does not preserve hardlinks).
//
// Eliminates fork+exec of /usr/bin/cp per package, reduces syscall count,
// and lets later changes (e.g. io_uring batching) live in one place.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// FICLONE ioctl number on Linux: _IOW(0x94, 9, int).
/// Identical across architectures supported by the kernel.
const FICLONE: u32 = 0x40049409;

/// Recursively copy `src` into `dst`. `dst` may already exist; intermediate
/// directories are created as needed. Returns `error.CopyFailed` on any
/// unrecoverable failure so the caller can fall back.
pub fn copyTree(io: std.Io, src: []const u8, dst: []const u8) !void {
    if (comptime builtin.os.tag != .linux) return error.CopyFailed;

    // Ensure dst exists. If it doesn't, create it (and any parents).
    makePathAbsolute(io, dst) catch return error.CopyFailed;

    var src_dir = std.Io.Dir.openDirAbsolute(io, src, .{ .iterate = true }) catch
        return error.CopyFailed;
    defer src_dir.close(io);

    var dst_dir = std.Io.Dir.openDirAbsolute(io, dst, .{}) catch
        return error.CopyFailed;
    defer dst_dir.close(io);

    var walker = std.Io.Dir.walk(src_dir, std.heap.page_allocator) catch
        return error.CopyFailed;
    defer walker.deinit();

    while (walker.next(io) catch return error.CopyFailed) |entry| {
        switch (entry.kind) {
            .directory => {
                dst_dir.createDirPath(io, entry.path) catch return error.CopyFailed;
            },
            .file => {
                copyOneFile(io, src_dir, entry.path, dst_dir, entry.path) catch
                    return error.CopyFailed;
            },
            .sym_link => {
                copyOneSymlink(io, src_dir, entry.path, dst_dir, entry.path) catch
                    return error.CopyFailed;
            },
            else => {
                // Sockets, fifos, block/char devices: skip silently. `cp -R`
                // would copy these, but bottle contents only contain regular
                // files / dirs / symlinks in practice.
            },
        }
    }
}

/// Copy `src_dir/src_path` to `dst_dir/dst_path` as a regular file.
/// Tries FICLONE first, then falls back to copy_file_range-backed copyFile.
fn copyOneFile(
    io: std.Io,
    src_dir: std.Io.Dir,
    src_path: []const u8,
    dst_dir: std.Io.Dir,
    dst_path: []const u8,
) !void {
    const src_file = try src_dir.openFile(io, src_path, .{});
    defer src_file.close(io);

    const st = src_file.stat(io) catch null;
    const perms: std.Io.File.Permissions = if (st) |s| s.permissions else .default_file;

    // Fast path: FICLONE on btrfs/xfs/zfs reflink-capable filesystems.
    // Same effect as `cp --reflink=auto`: zero data movement.
    fast: {
        const dst_file = dst_dir.createFile(io, dst_path, .{
            .permissions = perms,
            .truncate = true,
        }) catch break :fast;
        const ok = ficloneFromFd(@intCast(dst_file.handle), @intCast(src_file.handle));
        dst_file.close(io);
        if (ok) return;
        // FICLONE failed (different FS / unsupported FS / permission). Remove
        // the empty file we just created so copyFile can re-create it
        // atomically.
        dst_dir.deleteFile(io, dst_path) catch {};
    }

    // Slow path: in-kernel copy_file_range (or sendfile/read+write) via
    // std.Io.Dir.copyFile, which uses an atomic temp-and-rename.
    try src_dir.copyFile(src_path, dst_dir, dst_path, io, .{
        .permissions = perms,
        .replace = true,
    });
}

/// Recreate a symlink from `src_dir/src_path` at `dst_dir/dst_path`.
fn copyOneSymlink(
    io: std.Io,
    src_dir: std.Io.Dir,
    src_path: []const u8,
    dst_dir: std.Io.Dir,
    dst_path: []const u8,
) !void {
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = src_dir.readLink(io, src_path, &target_buf) catch
        return error.CopyFailed;
    const target = target_buf[0..n];

    // Remove any pre-existing entry at the destination.
    dst_dir.deleteFile(io, dst_path) catch {};
    dst_dir.symLink(io, target, dst_path, .{}) catch return error.CopyFailed;
}

/// Wrap the FICLONE ioctl. Returns `true` on success.
fn ficloneFromFd(dst_fd: linux.fd_t, src_fd: linux.fd_t) bool {
    const rc = linux.ioctl(dst_fd, FICLONE, @as(usize, @bitCast(@as(isize, src_fd))));
    return linux.errno(rc) == .SUCCESS;
}

fn makePathAbsolute(io: std.Io, abs: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io, abs, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            if (std.fs.path.dirname(abs)) |parent| {
                try makePathAbsolute(io, parent);
                std.Io.Dir.createDirAbsolute(io, abs, .default_dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
            } else return err;
        },
        else => return err,
    };
}

// Smoke-tested end-to-end via tests/copy-tree-smoke.sh, which exercises
// copyTree against real bottle layouts. Inline tests are skipped because
// the repo's existing test harness on Linux requires libc linkage that
// is configured per-build, not per-test.
