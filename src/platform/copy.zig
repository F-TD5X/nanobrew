// nanobrew — COW copy abstraction
//
// macOS: clonefile(2) syscall for zero-cost APFS copy-on-write
// Linux: in-process recursive walker with FICLONE + copy_file_range,
//        falling back to `cp --reflink=auto -R` only if the native walker
//        fails outright.

const std = @import("std");
const builtin = @import("builtin");
const copy_linux = if (builtin.os.tag == .linux) @import("copy_linux.zig") else struct {};

/// Attempt to clone a directory tree using OS-native COW.
/// Returns true if the clone succeeded, false if caller should use cp fallback.
pub fn cloneTree(src: [*:0]const u8, dst: [*:0]const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    return clonefile(src, dst, CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) == 0;
}

/// Build the cp fallback args for the current platform.
/// macOS: cp -R src dst
/// Linux: cp --reflink=auto -R src dst (enables COW on btrfs/xfs)
pub fn cpFallbackArgs(src: []const u8, dst: []const u8) [4][]const u8 {
    if (comptime builtin.os.tag == .linux) {
        return .{ "cp", "--reflink=auto", "-R", src };
    } else {
        return .{ "cp", "-R", src, dst };
    }
}

/// Materialize `src` into `dst` (full directory tree).
///
/// On Linux, this prefers the in-process walker (`copy_linux.copyTree`),
/// which avoids fork+exec of /usr/bin/cp and matches `cp --reflink=auto`
/// semantics via FICLONE + copy_file_range. If the native walker fails for
/// any reason we fall back to the historical `cp` subprocess so we never
/// regress on weird filesystems.
///
/// On macOS, we keep the existing `cp -R` subprocess fallback (clonefile
/// is the fast path, taken in `cellar.materialize` before this function
/// is reached).
pub fn cpFallback(io: std.Io, src: []const u8, dst: []const u8) !void {
    if (comptime builtin.os.tag == .linux) {
        copy_linux.copyTree(io, src, dst) catch {
            // Last-ditch: shell out to cp. Keeps behaviour identical to the
            // pre-native-walker implementation if anything ever regresses on
            // an exotic filesystem.
            const result = std.process.run(std.heap.page_allocator, io, .{
                .argv = &.{ "cp", "--reflink=auto", "-R", src, dst },
            }) catch return error.CopyFailed;
            std.heap.page_allocator.free(result.stdout);
            std.heap.page_allocator.free(result.stderr);
            if (switch (result.term) { .exited => |c| c != 0, else => true }) return error.CopyFailed;
        };
    } else {
        const result = std.process.run(std.heap.page_allocator, io, .{
            .argv = &.{ "cp", "-R", src, dst },
        }) catch return error.CopyFailed;
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
        if (switch (result.term) { .exited => |c| c != 0, else => true }) return error.CopyFailed;
    }
}

// macOS clonefile(2) — only compiled on macOS
const CLONE_NOFOLLOW: c_uint = 0x0001;
const CLONE_NOOWNERCOPY: c_uint = 0x0002;

extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: c_uint) c_int;

const testing = std.testing;

test "cpFallback returns error on bad source path" {
    // Both the native walker and the cp fallback should fail.
    const err = cpFallback(testing.io, "/nonexistent/source/path", "/tmp/dst");
    try testing.expectError(error.CopyFailed, err);
}

test "cpFallbackArgs returns correct platform args" {
    const args = cpFallbackArgs("/src", "/dst");
    try testing.expectEqualStrings("cp", args[0]);
    if (comptime builtin.os.tag == .linux) {
        try testing.expectEqualStrings("--reflink=auto", args[1]);
    } else {
        try testing.expectEqualStrings("-R", args[1]);
    }
}
