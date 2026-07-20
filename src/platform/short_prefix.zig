// nanobrew — shared /opt/nb short-prefix symlink + in-place byte rewriter
//
// /opt/nb → <PREFIX> is a Nix-style short prefix: every @@HOMEBREW_*@@
// placeholder replacement routed through this symlink is strictly shorter
// than the placeholder token. That is what makes in-place byte patching of
// Mach-O and ELF binaries universally valid — a replacement never grows a
// string, so no byte offset in the file ever shifts and the only post-step
// is re-signing (macOS) / nothing (Linux).
//
// Used by both the ELF relocator (Linux) and the Mach-O relocator (macOS).
// Homebrew bottles bake literal /opt/homebrew/... and @@HOMEBREW_*@@
// tokens into .rodata / __DATA (compile-time defaults like OpenSSL's
// OPENSSLDIR, git's --html-path, GIT_CONFIG_SYSTEM) which install_name_tool
// and patchelf never touch — only a whole-file in-place byte pass can, and
// only when every replacement is no longer than its source. See #347.

const std = @import("std");
const paths = @import("paths.zig");

/// Short prefix symlink target: /opt/nb → <PREFIX>. Strictly shorter than
/// every @@HOMEBREW_*@@ placeholder, which is what makes in-place binary
/// patching universally valid (replacement never grows a string).
pub const SHORT_PREFIX = "/opt/nb";
pub const SHORT_CELLAR = SHORT_PREFIX ++ "/Cellar";

const ShortLinkState = enum(u8) { unknown, ok, unavailable };
var short_link_mutex: std.Io.Mutex = .init;
var short_link_state: ShortLinkState = .unknown;

comptime {
    if (SHORT_PREFIX.len > paths.PLACEHOLDER_PREFIX.len or
        SHORT_CELLAR.len > paths.PLACEHOLDER_CELLAR.len or
        paths.REAL_REPOSITORY.len > paths.PLACEHOLDER_REPOSITORY.len)
    {
        @compileError("in-place relocation requires every short replacement to be no longer than its placeholder");
    }
}

/// Ensure /opt/nb → <PREFIX> exists. Memoized per process: one readlink/
/// symlink attempt shared across install workers. Returns false when it
/// can't be created (no permission on /opt and not already present) or
/// when /opt/nb exists but is not ours — callers must then skip the
/// short-prefix rewrites that can't shrink in place and fall back.
pub fn ensureShortPrefixLink(io: std.Io) bool {
    short_link_mutex.lockUncancelable(io);
    defer short_link_mutex.unlock(io);

    switch (short_link_state) {
        .ok => return true,
        .unavailable => return false,
        .unknown => {},
    }

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(io, SHORT_PREFIX, &target_buf)) |n| {
        short_link_state = if (std.mem.eql(u8, target_buf[0..n], paths.PREFIX)) .ok else .unavailable;
        return short_link_state == .ok;
    } else |_| {}

    // Exists but isn't a symlink (a real dir/file someone put there) — leave it alone.
    if (std.Io.Dir.accessAbsolute(io, SHORT_PREFIX, .{})) |_| {
        short_link_state = .unavailable;
        return false;
    } else |_| {}

    if (std.c.symlink(paths.PREFIX, SHORT_PREFIX) == 0) {
        short_link_state = .ok;
        return true;
    }

    // Lost a race with a concurrent nb process? Accept its link if correct.
    if (std.Io.Dir.readLinkAbsolute(io, SHORT_PREFIX, &target_buf)) |n| {
        if (std.mem.eql(u8, target_buf[0..n], paths.PREFIX)) {
            short_link_state = .ok;
            return true;
        }
    } else |_| {}

    short_link_state = .unavailable;
    return false;
}

/// Overwrite every occurrence of `needle` in `data` with `replacement`,
/// padding the freed tail bytes with '/' so the total byte length is
/// unchanged. `replacement.len` must be <= `needle.len`. The '/' padding is
/// benign for both NUL-terminated C strings (dylib IDs, rpaths, .rodata
/// compile-time defaults) and length-delimited consumers: the kernel and
/// dyld collapse consecutive slashes, and every byte offset in the binary
/// is left untouched — load-command cmdsize, section offsets, code-sign
/// code-directory hashes (re-computed by the subsequent codesign pass).
pub fn rewriteAllInPlace(data: []u8, needle: []const u8, replacement: []const u8) void {
    std.debug.assert(replacement.len <= needle.len);
    const pad = needle.len - replacement.len;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, needle)) |hit| {
        @memcpy(data[hit..][0..replacement.len], replacement);
        @memset(data[hit + replacement.len ..][0..pad], '/');
        i = hit + needle.len;
    }
}
