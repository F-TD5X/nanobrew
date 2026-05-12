// nanobrew — Cask install/remove pipeline
//
// Handles downloading, mounting/extracting, and installing macOS .app/.dmg/.pkg bundles.
// Apps are installed to /Applications/, binaries symlinked to prefix/bin/.

const std = @import("std");
const Cask = @import("../api/cask.zig").Cask;
const Artifact = @import("../api/cask.zig").Artifact;
const DownloadFormat = @import("../api/cask.zig").DownloadFormat;
const paths = @import("../platform/paths.zig");
const fetch = @import("../net/fetch.zig");
const telemetry = @import("../telemetry/client.zig");
const builtin = @import("builtin");

const PREFIX = paths.PREFIX;
const CASKROOM_DIR = paths.CASKROOM_DIR;
const CACHE_TMP = paths.TMP_DIR;
const APPLICATIONS_DIR = "/Applications";
const ZIP_LIST_STDOUT_LIMIT = 8 * 1024 * 1024;
const CASK_DOWNLOAD_ATTEMPTS = 3;
const CASK_DOWNLOAD_RETRY_BASE_MS = 250;
const CASK_DOWNLOAD_HEADERS = [_]std.http.Header{
    .{ .name = "User-Agent", .value = "Homebrew/4 (nanobrew)" },
};

pub const DestinationConflict = struct {
    kind: []const u8,
    path: []const u8,
};

pub fn firstAppInstallConflict(io: std.Io, cask: Cask) !?[]const u8 {
    return firstAppInstallConflictIn(io, APPLICATIONS_DIR, &cask);
}

pub fn firstInstallConflict(io: std.Io, cask: Cask, conflict_buf: []u8) !?DestinationConflict {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else null;
    return firstInstallConflictIn(io, APPLICATIONS_DIR, home, &cask, conflict_buf);
}

pub fn installCask(alloc: std.mem.Allocator, io: std.Io, cask: Cask) !void {
    const lib_io = io;

    if (comptime builtin.os.tag == .linux) {
        std.Io.File.stderr().writeStreamingAll(lib_io, "nb: casks are not supported on Linux yet\n") catch {};
        return error.CaskNotSupported;
    }

    const trace_enabled = caskTraceEnabled();
    const total_timer = TraceTimer.start(trace_enabled);

    var conflict_buf: [1024]u8 = undefined;
    if (try firstInstallConflict(lib_io, cask, &conflict_buf)) |conflict| {
        writeDestinationConflict(lib_io, conflict.kind, conflict.path);
        return error.DestinationAlreadyExists;
    }

    // For third-party taps, cask.token may contain slashes (e.g. "indaco/tap/sley").
    // Use only the basename for filesystem paths to avoid creating nested directories.
    const safe_token = if (std.mem.lastIndexOfScalar(u8, cask.token, '/')) |idx|
        cask.token[idx + 1 ..]
    else
        cask.token;

    // 1. Download artifact
    const format = cask.downloadFormat();
    const ext: []const u8 = switch (format) {
        .dmg => ".dmg",
        .zip => ".zip",
        .pkg => ".pkg",
        .tar_gz => ".tar.gz",
        .tar_xz => ".tar.xz",
        .shell_script => ".sh",
        .binary => "",
        .unknown => ".dmg", // try dmg as default
    };
    var dl_buf: [512]u8 = undefined;
    const dl_path = std.fmt.bufPrint(&dl_buf, "{s}/{s}{s}", .{ CACHE_TMP, safe_token, ext }) catch return error.PathTooLong;

    var phase_timer = TraceTimer.start(trace_enabled);
    var telemetry_event = telemetry.DownloadEvent.start(.cask, cask.token);
    const downloaded = downloadArtifact(alloc, io, cask.url, dl_path, cask) catch |err| {
        telemetry_event.fail();
        return err;
    };
    if (downloaded) telemetry_event.succeed(telemetry.fileSize(dl_path));
    traceCaskPhase(trace_enabled, cask.token, "download", phase_timer.read());

    // 2. Create Caskroom entry
    phase_timer = TraceTimer.start(trace_enabled);
    var caskroom_buf: [512]u8 = undefined;
    const caskroom_path = cask.caskroomPath(&caskroom_buf);
    std.Io.Dir.createDirAbsolute(lib_io, CASKROOM_DIR, .default_dir) catch {};
    var token_dir_buf: [512]u8 = undefined;
    const token_dir = std.fmt.bufPrint(&token_dir_buf, "{s}/{s}", .{ CASKROOM_DIR, safe_token }) catch return error.PathTooLong;
    std.Io.Dir.createDirAbsolute(lib_io, token_dir, .default_dir) catch {};
    std.Io.Dir.createDirAbsolute(lib_io, caskroom_path, .default_dir) catch {};
    traceCaskPhase(trace_enabled, cask.token, "caskroom", phase_timer.read());

    // 3. Mount/extract based on format
    var mount_point_buf: [512]u8 = undefined;
    var mount_point: ?[]const u8 = null;
    var temp_extract_dir: ?[]const u8 = null;
    var temp_extract_buf: [512]u8 = undefined;

    defer {
        const cleanup_timer = TraceTimer.start(trace_enabled);
        // Cleanup: unmount dmg
        if (mount_point) |mp| {
            unmountDmg(alloc, io, mp);
        }
        // Cleanup: remove temp extract dir
        if (temp_extract_dir) |td| {
            std.Io.Dir.cwd().deleteTree(lib_io, td) catch {};
        }
        // Cleanup: remove downloaded file
        std.Io.Dir.deleteFileAbsolute(lib_io, dl_path) catch {};
        traceCaskPhase(trace_enabled, cask.token, "cleanup", cleanup_timer.read());
        traceCaskPhase(trace_enabled, cask.token, "installer_total", total_timer.read());
    }

    phase_timer = TraceTimer.start(trace_enabled);
    if (try installFastCaskArtifact(alloc, lib_io, cask, format, dl_path, caskroom_path)) {
        traceCaskPhase(trace_enabled, cask.token, "fast_install", phase_timer.read());
        return;
    }
    traceCaskPhase(trace_enabled, cask.token, "fast_probe", phase_timer.read());

    switch (format) {
        .dmg => {
            phase_timer = TraceTimer.start(trace_enabled);
            // Remove Gatekeeper quarantine from .dmg before mounting
            if (comptime builtin.os.tag == .macos) {
                clearQuarantineIfPresent(alloc, lib_io, dl_path, false);
            }
            mount_point = try mountDmg(alloc, io, dl_path, &mount_point_buf);
            traceCaskPhase(trace_enabled, cask.token, "mount_dmg", phase_timer.read());
        },
        .unknown => {
            if (comptime builtin.os.tag == .macos) {
                clearQuarantineIfPresent(alloc, lib_io, dl_path, false);
            }
            phase_timer = TraceTimer.start(trace_enabled);
            mount_point = mountDmg(alloc, io, dl_path, &mount_point_buf) catch null;
            traceCaskPhase(trace_enabled, cask.token, if (mount_point != null) "mount_dmg" else "probe_dmg", phase_timer.read());
            if (mount_point == null) {
                const tmp_dir = std.fmt.bufPrint(&temp_extract_buf, "{s}/{s}-extract", .{ CACHE_TMP, safe_token }) catch return error.PathTooLong;
                std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir) catch {};
                phase_timer = TraceTimer.start(trace_enabled);
                extractZip(alloc, io, dl_path, tmp_dir) catch {
                    std.Io.Dir.cwd().deleteTree(lib_io, tmp_dir) catch {};
                    return error.UnsupportedArchive;
                };
                temp_extract_dir = tmp_dir;
                traceCaskPhase(trace_enabled, cask.token, "extract_zip", phase_timer.read());
            }
        },
        .zip => {
            const tmp_dir = std.fmt.bufPrint(&temp_extract_buf, "{s}/{s}-extract", .{ CACHE_TMP, safe_token }) catch return error.PathTooLong;
            std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir) catch {};
            phase_timer = TraceTimer.start(trace_enabled);
            try extractZip(alloc, io, dl_path, tmp_dir);
            temp_extract_dir = tmp_dir;
            traceCaskPhase(trace_enabled, cask.token, "extract_zip", phase_timer.read());
        },
        .tar_gz => {
            const tmp_dir = std.fmt.bufPrint(&temp_extract_buf, "{s}/{s}-extract", .{ CACHE_TMP, safe_token }) catch return error.PathTooLong;
            std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir) catch {};
            phase_timer = TraceTimer.start(trace_enabled);
            try extractTarGz(alloc, io, dl_path, tmp_dir);
            temp_extract_dir = tmp_dir;
            traceCaskPhase(trace_enabled, cask.token, "extract_tar_gz", phase_timer.read());
        },
        .tar_xz => {
            const tmp_dir = std.fmt.bufPrint(&temp_extract_buf, "{s}/{s}-extract", .{ CACHE_TMP, safe_token }) catch return error.PathTooLong;
            std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir) catch {};
            phase_timer = TraceTimer.start(trace_enabled);
            try extractTarXz(alloc, io, dl_path, tmp_dir);
            temp_extract_dir = tmp_dir;
            traceCaskPhase(trace_enabled, cask.token, "extract_tar_xz", phase_timer.read());
        },
        .pkg => {}, // standalone, handled directly in artifact processing
        .shell_script => {}, // standalone installer script
        .binary => {}, // direct executable download, handled as a binary artifact
    }

    // 4. Process artifacts in order
    const source_dir: []const u8 = mount_point orelse temp_extract_dir orelse CACHE_TMP;

    var any_artifact_failed = false;

    phase_timer = TraceTimer.start(trace_enabled);
    for (cask.artifacts) |art| {
        switch (art) {
            .app => |app_name| {
                // Validate app name: must end with .app, no path traversal (#45)
                if (std.mem.indexOf(u8, app_name, "..") != null or
                    !std.mem.endsWith(u8, app_name, ".app"))
                {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: skipping unsafe app artifact: {s}\n", .{app_name}) catch "nb: skipping unsafe app artifact\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                }
                var src_buf: [1024]u8 = undefined;
                const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ source_dir, app_name }) catch continue;
                var dst_buf: [512]u8 = undefined;
                const dst = appDestinationPath(APPLICATIONS_DIR, app_name, &dst_buf) catch continue;

                // Verify source app exists before attempting copy (#60)
                std.Io.Dir.accessAbsolute(lib_io, src, .{}) catch {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: error: {s} not found in {s} — DMG may not have mounted correctly\n", .{ app_name, source_dir }) catch "nb: error: app not found\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    any_artifact_failed = true;
                    continue;
                };

                if (appDestinationExists(lib_io, dst) catch |err| {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: could not inspect app destination {s}: {}\n", .{ dst, err }) catch "nb: could not inspect app destination\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    any_artifact_failed = true;
                    continue;
                }) {
                    var _b: [768]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: refusing to overwrite existing app at {s}\n", .{dst}) catch "nb: refusing to overwrite existing app\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    any_artifact_failed = true;
                    continue;
                }

                // cp -R source to /Applications/
                const cp_result = std.process.run(alloc, lib_io, .{
                    .argv = &.{ "cp", "-R", src, dst },
                }) catch {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: failed to copy {s} to /Applications/\n", .{app_name}) catch "nb: failed to copy app\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    any_artifact_failed = true;
                    continue;
                };
                alloc.free(cp_result.stdout);
                alloc.free(cp_result.stderr);
                const cp_exit_code: u8 = switch (cp_result.term) {
                    .exited => |code| code,
                    else => 1,
                };
                if (cp_exit_code != 0) {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: cp failed for {s} (exit code {d})\n", .{ app_name, cp_exit_code }) catch "nb: cp failed\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    any_artifact_failed = true;
                    continue;
                }

                // Remove Gatekeeper quarantine so the app can launch without warning
                if (comptime builtin.os.tag == .macos) {
                    clearQuarantineIfPresent(alloc, lib_io, dst, true);
                }
            },
            .binary => |bin| {
                // Validate bin.target: no path traversal, no slashes (#45)
                if (std.mem.indexOf(u8, bin.target, "..") != null or
                    std.mem.indexOf(u8, bin.target, "/") != null)
                {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: skipping unsafe binary target: {s}\n", .{bin.target}) catch "nb: skipping unsafe binary target\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                }
                var resolved_buf: [1024]u8 = undefined;
                var source: []const u8 = undefined;

                if (std.mem.startsWith(u8, bin.source, "$APPDIR")) {
                    // $APPDIR expansion for app-bundled binaries
                    source = std.fmt.bufPrint(&resolved_buf, "/Applications{s}", .{bin.source["$APPDIR".len..]}) catch continue;
                } else if (std.mem.startsWith(u8, bin.source, "$HOMEBREW_PREFIX/")) {
                    source = std.fmt.bufPrint(&resolved_buf, "{s}/{s}", .{ PREFIX, bin.source["$HOMEBREW_PREFIX/".len..] }) catch continue;
                } else if (std.mem.startsWith(u8, bin.source, "/")) {
                    // Absolute path
                    source = bin.source;
                } else {
                    // Relative path — binary is in the extract/mount dir.
                    // Copy to Caskroom, then symlink from there.
                    var src_buf2: [1024]u8 = undefined;
                    const extract_src = if (format == .binary)
                        dl_path
                    else
                        std.fmt.bufPrint(&src_buf2, "{s}/{s}", .{ source_dir, bin.source }) catch continue;
                    var caskroom_bin_buf: [1024]u8 = undefined;
                    const caskroom_bin = std.fmt.bufPrint(&caskroom_bin_buf, "{s}/{s}", .{ caskroom_path, bin.target }) catch continue;

                    // Copy binary to Caskroom without spawning cp/chmod.
                    std.Io.Dir.copyFileAbsolute(extract_src, caskroom_bin, lib_io, .{
                        .permissions = .executable_file,
                    }) catch {
                        var _b: [512]u8 = undefined;
                        const _m = std.fmt.bufPrint(&_b, "nb: failed to copy binary {s}\n", .{bin.source}) catch "nb: failed to copy binary\n";
                        std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                        continue;
                    };

                    source = std.fmt.bufPrint(&resolved_buf, "{s}", .{caskroom_bin}) catch continue;
                }

                // Security: validate resolved source path to prevent symlink escape
                // Reject paths containing ".." components
                if (std.mem.indexOf(u8, source, "..") != null) {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: refusing to symlink binary with path traversal: {s}\n", .{bin.source}) catch "nb: refusing to symlink binary\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                }
                // Source must start with /Applications, the Caskroom, or be within extract dir
                const is_app_path = std.mem.startsWith(u8, source, "/Applications");
                const is_caskroom_path = std.mem.startsWith(u8, source, paths.CASKROOM_DIR);
                const is_extract_path = std.mem.startsWith(u8, source, source_dir);
                const is_prefix_path = std.mem.startsWith(u8, source, PREFIX);
                if (!is_app_path and !is_caskroom_path and !is_extract_path and !is_prefix_path) {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: refusing to symlink binary outside allowed directories: {s}\n", .{bin.source}) catch "nb: refusing to symlink binary\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                }

                var link_buf: [512]u8 = undefined;
                const link_path = std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ PREFIX, bin.target }) catch continue;

                ensureDestinationAvailable(lib_io, link_path) catch |err| {
                    if (err == error.DestinationAlreadyExists) {
                        writeDestinationConflict(lib_io, "binary link", link_path);
                    } else {
                        var _b: [512]u8 = undefined;
                        const _m = std.fmt.bufPrint(&_b, "nb: could not inspect binary link {s}: {}\n", .{ link_path, err }) catch "nb: could not inspect binary link\n";
                        std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    }
                    any_artifact_failed = true;
                    continue;
                };
                std.Io.Dir.symLinkAbsolute(lib_io, source, link_path, .{}) catch |err| {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: symlink failed for {s}: {}\n", .{ bin.target, err }) catch "nb: symlink failed\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    any_artifact_failed = true;
                };
            },
            .pkg => |pkg_name| {
                // Validate pkg name: no path traversal, no absolute paths (#Task8)
                if (std.mem.indexOf(u8, pkg_name, "..") != null or
                    (pkg_name.len > 0 and pkg_name[0] == '/'))
                {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: skipping unsafe pkg artifact: {s}\n", .{pkg_name}) catch "nb: skipping unsafe pkg artifact\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                }
                var pkg_buf: [1024]u8 = undefined;
                const pkg_path = if (format == .pkg)
                    dl_path // standalone .pkg download
                else
                    std.fmt.bufPrint(&pkg_buf, "{s}/{s}", .{ source_dir, pkg_name }) catch continue;

                // Remove Gatekeeper quarantine from the .pkg before installing
                if (comptime builtin.os.tag == .macos) {
                    clearQuarantineIfPresent(alloc, lib_io, pkg_path, false);
                }

                const result = std.process.run(alloc, lib_io, .{
                    .argv = &.{ "sudo", "installer", "-pkg", pkg_path, "-target", "/" },
                }) catch {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: pkg install failed for {s}\n", .{pkg_name}) catch "nb: pkg install failed\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                };
                alloc.free(result.stdout);
                alloc.free(result.stderr);
                if (switch (result.term) {
                    .exited => |c| c != 0,
                    else => true,
                }) {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: installer failed for {s}\n", .{pkg_name}) catch "nb: installer failed\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    any_artifact_failed = true;
                }
            },
            .font => |font_path| {
                if (!safeRelativePath(font_path)) {
                    writeArtifactWarning(lib_io, "nb: skipping unsafe font artifact\n");
                    continue;
                }
                const home = std.c.getenv("HOME") orelse {
                    writeArtifactWarning(lib_io, "nb: HOME is not set; skipping font artifact\n");
                    continue;
                };
                const home_slice = std.mem.span(home);
                var src_buf: [1024]u8 = undefined;
                const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ source_dir, font_path }) catch continue;
                var font_dir_buf: [1024]u8 = undefined;
                const font_dir = std.fmt.bufPrint(&font_dir_buf, "{s}/Library/Fonts", .{home_slice}) catch continue;
                std.Io.Dir.createDirAbsolute(lib_io, font_dir, .default_dir) catch {};
                var dst_buf: [1024]u8 = undefined;
                const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ font_dir, std.fs.path.basename(font_path) }) catch continue;
                ensureDestinationAvailable(lib_io, dst) catch |err| {
                    if (err == error.DestinationAlreadyExists) {
                        writeDestinationConflict(lib_io, "font", dst);
                    } else {
                        var _b: [512]u8 = undefined;
                        const _m = std.fmt.bufPrint(&_b, "nb: could not inspect font destination {s}: {}\n", .{ dst, err }) catch "nb: could not inspect font destination\n";
                        std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    }
                    any_artifact_failed = true;
                    continue;
                };
                std.Io.Dir.copyFileAbsolute(src, dst, lib_io, .{}) catch {
                    writeArtifactWarning(lib_io, "nb: failed to install font artifact\n");
                    any_artifact_failed = true;
                };
            },
            .artifact => |artifact_rule| {
                copyGenericArtifact(alloc, lib_io, source_dir, artifact_rule.source, artifact_rule.target) catch {
                    writeArtifactWarning(lib_io, "nb: failed to install artifact\n");
                    any_artifact_failed = true;
                };
            },
            .suite => |suite| {
                copyGenericArtifact(alloc, lib_io, source_dir, suite.source, suite.target) catch {
                    writeArtifactWarning(lib_io, "nb: failed to install suite artifact\n");
                    any_artifact_failed = true;
                };
            },
            .installer_script => |script| {
                runInstallerScript(alloc, lib_io, format, dl_path, source_dir, script.executable, script.args) catch {
                    writeArtifactWarning(lib_io, "nb: installer script failed\n");
                    any_artifact_failed = true;
                };
            },
            .uninstall => {}, // only used during removal
        }
    }

    traceCaskPhase(trace_enabled, cask.token, "artifacts", phase_timer.read());
    if (any_artifact_failed) return error.ArtifactFailed;
}

pub fn removeCask(
    _: std.mem.Allocator,
    io: std.Io,
    token: []const u8,
    version: []const u8,
    apps: []const []const u8,
    binaries: []const []const u8,
) !void {
    const lib_io = io;

    // 1. Delete apps from /Applications/
    for (apps) |app| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/Applications/{s}", .{app}) catch continue;
        std.Io.Dir.cwd().deleteTree(lib_io, path) catch |err| {
            var _b: [512]u8 = undefined;
            const _m = std.fmt.bufPrint(&_b, "nb: could not remove {s}: {}\n", .{ app, err }) catch "nb: could not remove app\n";
            std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
        };
    }

    // 2. Delete binary symlinks from prefix/bin/
    for (binaries) |bin| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/bin/{s}", .{ PREFIX, bin }) catch continue;
        std.Io.Dir.deleteFileAbsolute(lib_io, path) catch {};
    }

    // 3. Delete Caskroom entry
    var caskroom_buf: [512]u8 = undefined;
    const ver_dir = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}/{s}", .{ PREFIX, token, version }) catch return;
    std.Io.Dir.cwd().deleteTree(lib_io, ver_dir) catch {};

    // Try to remove parent dir if empty
    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/Caskroom/{s}", .{ PREFIX, token }) catch return;
    std.Io.Dir.deleteDirAbsolute(lib_io, parent) catch {};
}

fn downloadArtifact(alloc: std.mem.Allocator, io: std.Io, url: []const u8, dest: []const u8, cask: Cask) !bool {
    const lib_io = io;
    const use_cache = caskBlobCacheEnabled(cask.sha256);

    if (use_cache) {
        var cached_buf: [512]u8 = undefined;
        const cached_path = std.fmt.bufPrint(&cached_buf, "{s}/{s}", .{ paths.BLOBS_DIR, cask.sha256 }) catch return error.PathTooLong;
        const cache_available = blk: {
            std.Io.Dir.accessAbsolute(lib_io, cached_path, .{}) catch break :blk false;
            break :blk true;
        };
        if (cache_available) copy_cached: {
            std.Io.Dir.copyFileAbsolute(cached_path, dest, lib_io, .{}) catch {
                std.Io.Dir.deleteFileAbsolute(lib_io, cached_path) catch {};
                break :copy_cached;
            };
            return false;
        }
    }

    // Native HTTP download (no curl dependency)
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    // Verify SHA256 if available
    if (cask.sha256.len == 0 or std.mem.eql(u8, cask.sha256, "no_check")) {
        var attempt: usize = 0;
        while (attempt < CASK_DOWNLOAD_ATTEMPTS) : (attempt += 1) {
            fetch.downloadWithClientHeaders(&client, url, dest, &CASK_DOWNLOAD_HEADERS) catch |err| {
                std.Io.Dir.deleteFileAbsolute(lib_io, dest) catch {};
                if (shouldRetryDownload(err, attempt)) {
                    writeDownloadRetryWarning(lib_io, cask, attempt);
                    sleepBeforeDownloadRetry(lib_io, attempt);
                    continue;
                }
                writeDownloadError(lib_io, cask, err);
                return err;
            };
            break;
        }
        var _b: [512]u8 = undefined;
        const _m = std.fmt.bufPrint(&_b, "nb: warning: skipping SHA256 verification for {s} (no checksum available)\n", .{cask.token}) catch "nb: warning: skipping SHA256 verification\n";
        std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
        return true;
    }

    var attempt: usize = 0;
    while (attempt < CASK_DOWNLOAD_ATTEMPTS) : (attempt += 1) {
        fetch.downloadWithClientSha256Headers(&client, url, dest, cask.sha256, &CASK_DOWNLOAD_HEADERS) catch |err| {
            std.Io.Dir.deleteFileAbsolute(lib_io, dest) catch {};
            if (shouldRetryDownload(err, attempt)) {
                writeDownloadRetryWarning(lib_io, cask, attempt);
                sleepBeforeDownloadRetry(lib_io, attempt);
                continue;
            }
            writeDownloadError(lib_io, cask, err);
            return err;
        };
        break;
    }

    if (use_cache) {
        std.Io.Dir.createDirAbsolute(lib_io, paths.BLOBS_DIR, .default_dir) catch {};
        var cached_buf: [512]u8 = undefined;
        const cached_path = std.fmt.bufPrint(&cached_buf, "{s}/{s}", .{ paths.BLOBS_DIR, cask.sha256 }) catch return true;
        std.Io.Dir.copyFileAbsolute(dest, cached_path, lib_io, .{}) catch {};
    }
    return true;
}

fn shouldRetryDownload(err: anyerror, attempt: usize) bool {
    return err == error.FetchFailed and attempt + 1 < CASK_DOWNLOAD_ATTEMPTS;
}

fn sleepBeforeDownloadRetry(io: std.Io, attempt: usize) void {
    const delay_ms: i64 = @as(i64, @intCast(attempt + 1)) * CASK_DOWNLOAD_RETRY_BASE_MS;
    std.Io.sleep(io, .fromMilliseconds(delay_ms), .awake) catch {};
}

fn writeDownloadRetryWarning(io: std.Io, cask: Cask, attempt: usize) void {
    var _b: [512]u8 = undefined;
    const _m = std.fmt.bufPrint(
        &_b,
        "nb: warning: retrying download for {s} (attempt {d}/{d})\n",
        .{ cask.token, attempt + 2, CASK_DOWNLOAD_ATTEMPTS },
    ) catch "nb: warning: retrying download\n";
    std.Io.File.stderr().writeStreamingAll(io, _m) catch {};
}

fn writeDownloadError(io: std.Io, cask: Cask, err: anyerror) void {
    var _b: [512]u8 = undefined;
    const _m = if (err == error.ChecksumMismatch)
        std.fmt.bufPrint(&_b, "nb: error: SHA256 verification failed for {s}\n", .{cask.token}) catch "nb: error: SHA256 verification failed\n"
    else
        std.fmt.bufPrint(&_b, "nb: error: download failed for {s}\n", .{cask.token}) catch "nb: error: download failed\n";
    std.Io.File.stderr().writeStreamingAll(io, _m) catch {};
}

fn caskBlobCacheEnabled(sha256: []const u8) bool {
    if (std.c.getenv("NANOBREW_DISABLE_CASK_BLOB_CACHE") != null) return false;
    if (sha256.len != 64) return false;
    for (sha256) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn mountDmg(alloc: std.mem.Allocator, io: std.Io, dmg_path: []const u8, out_buf: []u8) ![]const u8 {
    const lib_io = io;
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "hdiutil", "attach", "-nobrowse", "-noautoopen", "-noverify", "-noautofsck", "-readonly", "-plist", dmg_path },
        .stdout_limit = .limited(64 * 1024),
    }) catch return error.MountFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (switch (result.term) {
        .exited => |c| c != 0,
        else => true,
    }) return error.MountFailed;

    // Parse mount point from hdiutil output — look for /Volumes/ path
    if (std.mem.indexOf(u8, result.stdout, "/Volumes/")) |start| {
        // Find end of path (newline, < for plist, or end of string)
        var end = start;
        while (end < result.stdout.len) : (end += 1) {
            if (result.stdout[end] == '\n' or result.stdout[end] == '<' or result.stdout[end] == '\t') break;
        }
        // Trim trailing whitespace
        while (end > start and (result.stdout[end - 1] == ' ' or result.stdout[end - 1] == '\r')) {
            end -= 1;
        }
        const mount = result.stdout[start..end];
        @memcpy(out_buf[0..mount.len], mount);
        return out_buf[0..mount.len];
    }

    return error.MountFailed;
}

fn unmountDmg(alloc: std.mem.Allocator, io: std.Io, mount_point: []const u8) void {
    const lib_io = io;
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "hdiutil", "detach", "-force", "-quiet", mount_point },
        .stdout_limit = .limited(1024),
    }) catch return;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}

fn installFastCaskArtifact(
    alloc: std.mem.Allocator,
    io: std.Io,
    cask: Cask,
    format: DownloadFormat,
    archive_path: []const u8,
    caskroom_path: []const u8,
) !bool {
    switch (format) {
        .zip => {
            return installFastZipArtifact(alloc, io, cask, archive_path, caskroom_path);
        },
        .unknown => {
            // Some vendor URLs hide a ZIP payload behind extensionless URLs.
            // Probe the ZIP fast paths before the slower dmg-then-zip fallback.
            return installFastZipArtifact(alloc, io, cask, archive_path, caskroom_path);
        },
        .tar_gz, .tar_xz => {
            if (singleBinaryArtifact(&cask)) |bin| {
                installArchivedBinaryDirect(alloc, io, format, archive_path, caskroom_path, bin.source, bin.target) catch |err| switch (err) {
                    error.UnsafePath => return err,
                    error.DestinationAlreadyExists => return err,
                    else => return false,
                };
                return true;
            }
        },
        else => {},
    }
    return false;
}

fn installFastZipArtifact(
    alloc: std.mem.Allocator,
    io: std.Io,
    cask: Cask,
    archive_path: []const u8,
    caskroom_path: []const u8,
) !bool {
    if (zipAppBundleArtifact(&cask)) |app_name| {
        installZipAppBundleDirect(alloc, io, &cask, archive_path, app_name) catch |err| switch (err) {
            error.UnsafePath => return err,
            error.AppAlreadyExists => return err,
            error.DestinationAlreadyExists => return err,
            else => return false,
        };
        return true;
    }
    if (fontArtifactsOnly(&cask)) {
        installZipFontsDirect(alloc, io, &cask, archive_path) catch |err| switch (err) {
            error.UnsafePath => return err,
            error.DestinationAlreadyExists => return err,
            else => return false,
        };
        return true;
    }
    if (singleBinaryArtifact(&cask)) |bin| {
        installArchivedBinaryDirect(alloc, io, .zip, archive_path, caskroom_path, bin.source, bin.target) catch |err| switch (err) {
            error.UnsafePath => return err,
            error.DestinationAlreadyExists => return err,
            else => return false,
        };
        return true;
    }
    return false;
}

fn zipAppBundleArtifact(cask: *const Cask) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (cask.artifacts) |artifact| {
        switch (artifact) {
            .app => |app| {
                if (found != null) return null;
                found = app;
            },
            .binary => {},
            .uninstall => {},
            else => return null,
        }
    }
    const app_name = found orelse return null;
    if (std.mem.indexOfScalar(u8, app_name, '/') != null) return null;
    for (cask.artifacts) |artifact| {
        switch (artifact) {
            .binary => |bin| {
                if (!appBundleBinarySource(app_name, bin.source)) return null;
            },
            else => {},
        }
    }
    return app_name;
}

const BinaryArtifact = struct {
    source: []const u8,
    target: []const u8,
};

const TraceTimer = struct {
    enabled: bool,
    start_ns: u64,

    fn start(enabled: bool) TraceTimer {
        return .{
            .enabled = enabled,
            .start_ns = if (enabled) traceMonoNs() else 0,
        };
    }

    fn read(self: TraceTimer) u64 {
        if (!self.enabled) return 0;
        return traceMonoNs() - self.start_ns;
    }
};

pub fn caskTraceEnabled() bool {
    const value = std.c.getenv("NANOBREW_CASK_TRACE") orelse return false;
    const span = std.mem.span(value);
    return span.len == 0 or !std.mem.eql(u8, span, "0");
}

pub fn traceCaskPhase(enabled: bool, token: []const u8, phase: []const u8, elapsed_ns: u64) void {
    if (!enabled) return;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    std.debug.print("[nb-cask-trace] token={s} phase={s} ms={d:.2}\n", .{ token, phase, elapsed_ms });
}

fn traceMonoNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn singleBinaryArtifact(cask: *const Cask) ?BinaryArtifact {
    var found: ?BinaryArtifact = null;
    for (cask.artifacts) |artifact| {
        switch (artifact) {
            .binary => |bin| {
                if (found != null) return null;
                found = .{ .source = bin.source, .target = bin.target };
            },
            .uninstall => {},
            else => return null,
        }
    }
    return found;
}

fn fontArtifactsOnly(cask: *const Cask) bool {
    var font_count: usize = 0;
    for (cask.artifacts) |artifact| {
        switch (artifact) {
            .font => font_count += 1,
            .uninstall => {},
            else => return false,
        }
    }
    return font_count > 0;
}

fn appBundleBinarySource(app_name: []const u8, source_path: []const u8) bool {
    const prefix = "$APPDIR/";
    if (!std.mem.startsWith(u8, source_path, prefix)) return false;
    const relative = source_path[prefix.len..];
    if (!safeRelativePath(relative)) return false;
    if (!std.mem.startsWith(u8, relative, app_name)) return false;
    return relative.len == app_name.len or relative[app_name.len] == '/';
}

fn installZipAppBundleDirect(
    alloc: std.mem.Allocator,
    io: std.Io,
    cask: *const Cask,
    zip_path: []const u8,
    app_name: []const u8,
) !void {
    for (cask.artifacts) |artifact| {
        switch (artifact) {
            .binary => |bin| try ensureAppBundleBinaryDestinationAvailable(io, app_name, bin.source, bin.target),
            else => {},
        }
    }

    try installZipAppDirect(alloc, io, zip_path, app_name);

    for (cask.artifacts) |artifact| {
        switch (artifact) {
            .binary => |bin| try linkAppBundleBinary(io, app_name, bin.source, bin.target),
            else => {},
        }
    }
}

fn ensureAppBundleBinaryDestinationAvailable(
    io: std.Io,
    app_name: []const u8,
    source_path: []const u8,
    target: []const u8,
) !void {
    if (!appBundleBinarySource(app_name, source_path) or
        std.mem.indexOf(u8, target, "..") != null or
        std.mem.indexOfScalar(u8, target, '/') != null)
    {
        return error.UnsafePath;
    }
    var link_buf: [512]u8 = undefined;
    const link_path = std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ PREFIX, target }) catch return error.PathTooLong;
    try ensureDestinationAvailable(io, link_path);
}

fn installZipAppDirect(
    alloc: std.mem.Allocator,
    io: std.Io,
    zip_path: []const u8,
    app_name: []const u8,
) !void {
    var dst_buf: [512]u8 = undefined;
    const dst = try appDestinationPath(APPLICATIONS_DIR, app_name, &dst_buf);
    if (try appDestinationExists(io, dst)) return error.AppAlreadyExists;

    const pattern = try std.fmt.allocPrint(alloc, "{s}/*", .{app_name});
    defer alloc.free(pattern);
    try ensureZipPatternSafe(alloc, io, zip_path, pattern);

    const result = std.process.run(alloc, io, .{
        .argv = &.{ "unzip", "-n", "-q", zip_path, pattern, "-d", APPLICATIONS_DIR },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    }) return error.ExtractFailed;

    if (comptime builtin.os.tag == .macos) {
        clearQuarantineIfPresent(alloc, io, dst, true);
    }
}

fn firstAppInstallConflictIn(io: std.Io, applications_dir: []const u8, cask: *const Cask) !?[]const u8 {
    for (cask.artifacts) |artifact| {
        switch (artifact) {
            .app => |app_name| {
                var dst_buf: [512]u8 = undefined;
                const dst = try appDestinationPath(applications_dir, app_name, &dst_buf);
                if (try appDestinationExists(io, dst)) return app_name;
            },
            else => {},
        }
    }
    return null;
}

fn firstInstallConflictIn(
    io: std.Io,
    applications_dir: []const u8,
    home_dir: ?[]const u8,
    cask: *const Cask,
    conflict_buf: []u8,
) !?DestinationConflict {
    for (cask.artifacts) |artifact| {
        switch (artifact) {
            .app => |app_name| {
                var dst_buf: [512]u8 = undefined;
                const dst = try appDestinationPath(applications_dir, app_name, &dst_buf);
                if (try pathExistsNoFollow(io, dst)) {
                    return try destinationConflict("app", dst, conflict_buf);
                }
            },
            .binary => |bin| {
                if (std.mem.indexOf(u8, bin.target, "..") != null or
                    std.mem.indexOfScalar(u8, bin.target, '/') != null)
                {
                    return error.UnsafePath;
                }
                var dst_buf: [512]u8 = undefined;
                const dst = std.fmt.bufPrint(&dst_buf, "{s}/bin/{s}", .{ PREFIX, bin.target }) catch return error.PathTooLong;
                if (try pathExistsNoFollow(io, dst)) {
                    return try destinationConflict("binary link", dst, conflict_buf);
                }
            },
            .font => |font_path| {
                if (!safeRelativePath(font_path)) return error.UnsafePath;
                const home = home_dir orelse continue;
                var dst_buf: [1024]u8 = undefined;
                const dst = fontDestinationPath(home, font_path, &dst_buf) catch |err| switch (err) {
                    error.UnsafePath => return err,
                    else => return error.PathTooLong,
                };
                if (try pathExistsNoFollow(io, dst)) {
                    return try destinationConflict("font", dst, conflict_buf);
                }
            },
            .artifact => |artifact_rule| {
                var dst_buf: [1024]u8 = undefined;
                const dst = try genericArtifactDestinationPath(artifact_rule.target, &dst_buf);
                if (try pathExistsNoFollow(io, dst)) {
                    return try destinationConflict("artifact", dst, conflict_buf);
                }
            },
            .suite => |suite| {
                var dst_buf: [1024]u8 = undefined;
                const dst = try genericArtifactDestinationPath(suite.target, &dst_buf);
                if (try pathExistsNoFollow(io, dst)) {
                    return try destinationConflict("suite", dst, conflict_buf);
                }
            },
            .pkg, .installer_script, .uninstall => {},
        }
    }
    return null;
}

fn destinationConflict(kind: []const u8, path: []const u8, conflict_buf: []u8) !DestinationConflict {
    if (path.len > conflict_buf.len) return error.PathTooLong;
    @memcpy(conflict_buf[0..path.len], path);
    return .{ .kind = kind, .path = conflict_buf[0..path.len] };
}

fn appDestinationPath(applications_dir: []const u8, app_name: []const u8, buf: []u8) ![]const u8 {
    if (std.mem.indexOf(u8, app_name, "..") != null or
        !std.mem.endsWith(u8, app_name, ".app"))
    {
        return error.UnsafePath;
    }
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ applications_dir, std.fs.path.basename(app_name) }) catch error.PathTooLong;
}

fn appDestinationExists(io: std.Io, dst: []const u8) !bool {
    return pathExistsNoFollow(io, dst);
}

fn pathExistsNoFollow(io: std.Io, dst: []const u8) !bool {
    std.Io.Dir.access(.cwd(), io, dst, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn ensureDestinationAvailable(io: std.Io, dst: []const u8) !void {
    if (try pathExistsNoFollow(io, dst)) return error.DestinationAlreadyExists;
}

fn writeDestinationConflict(io: std.Io, kind: []const u8, path: []const u8) void {
    var _b: [1024]u8 = undefined;
    const _m = std.fmt.bufPrint(&_b, "nb: refusing to overwrite existing {s} at {s}\n", .{ kind, path }) catch "nb: refusing to overwrite existing destination\n";
    std.Io.File.stderr().writeStreamingAll(io, _m) catch {};
}

fn fontDestinationPath(home_dir: []const u8, font_path: []const u8, buf: []u8) ![]const u8 {
    if (!safeRelativePath(font_path)) return error.UnsafePath;
    return std.fmt.bufPrint(buf, "{s}/Library/Fonts/{s}", .{ home_dir, std.fs.path.basename(font_path) }) catch error.PathTooLong;
}

fn genericArtifactDestinationPath(target_path: []const u8, buf: []u8) ![]const u8 {
    if (std.mem.indexOf(u8, target_path, "..") != null) return error.UnsafePath;
    if (std.mem.startsWith(u8, target_path, "$HOMEBREW_PREFIX/")) {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ PREFIX, target_path["$HOMEBREW_PREFIX/".len..] }) catch error.PathTooLong;
    }
    if (!std.mem.startsWith(u8, target_path, PREFIX)) return error.UnsafePath;
    if (target_path.len > buf.len) return error.PathTooLong;
    @memcpy(buf[0..target_path.len], target_path);
    return buf[0..target_path.len];
}

fn installZipFontsDirect(
    alloc: std.mem.Allocator,
    io: std.Io,
    cask: *const Cask,
    zip_path: []const u8,
) !void {
    const home = std.c.getenv("HOME") orelse return error.HomeMissing;
    const home_slice = std.mem.span(home);
    var font_dir_buf: [1024]u8 = undefined;
    const font_dir = std.fmt.bufPrint(&font_dir_buf, "{s}/Library/Fonts", .{home_slice}) catch return error.PathTooLong;
    std.Io.Dir.createDirAbsolute(io, font_dir, .default_dir) catch {};

    for (cask.artifacts) |artifact| {
        switch (artifact) {
            .font => |font_path| {
                if (!safeArchiveMemberPath(font_path)) return error.UnsafePath;
                var dst_buf: [1024]u8 = undefined;
                const dst = try fontDestinationPath(home_slice, font_path, &dst_buf);
                if (try pathExistsNoFollow(io, dst)) {
                    writeDestinationConflict(io, "font", dst);
                    return error.DestinationAlreadyExists;
                }
            },
            else => {},
        }
    }

    var argv = try alloc.alloc([]const u8, cask.artifacts.len + 7);
    defer alloc.free(argv);
    var idx: usize = 0;
    argv[idx] = "unzip";
    idx += 1;
    argv[idx] = "-j";
    idx += 1;
    argv[idx] = "-n";
    idx += 1;
    argv[idx] = "-q";
    idx += 1;
    argv[idx] = zip_path;
    idx += 1;
    for (cask.artifacts) |artifact| {
        switch (artifact) {
            .font => |font_path| {
                argv[idx] = font_path;
                idx += 1;
            },
            else => {},
        }
    }
    argv[idx] = "-d";
    idx += 1;
    argv[idx] = font_dir;
    idx += 1;

    const result = std.process.run(alloc, io, .{
        .argv = argv[0..idx],
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    }) return error.ExtractFailed;
}

fn linkAppBundleBinary(
    io: std.Io,
    app_name: []const u8,
    source_path: []const u8,
    target: []const u8,
) !void {
    if (!appBundleBinarySource(app_name, source_path) or
        std.mem.indexOf(u8, target, "..") != null or
        std.mem.indexOfScalar(u8, target, '/') != null)
    {
        return error.UnsafePath;
    }

    const relative = source_path["$APPDIR/".len..];
    var source_buf: [1024]u8 = undefined;
    const source = std.fmt.bufPrint(&source_buf, "/Applications/{s}", .{relative}) catch return error.PathTooLong;
    var link_buf: [512]u8 = undefined;
    const link_path = std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ PREFIX, target }) catch return error.PathTooLong;
    try ensureDestinationAvailable(io, link_path);
    try std.Io.Dir.symLinkAbsolute(io, source, link_path, .{});
}

fn installArchivedBinaryDirect(
    alloc: std.mem.Allocator,
    io: std.Io,
    format: DownloadFormat,
    archive_path: []const u8,
    caskroom_path: []const u8,
    source_path: []const u8,
    target: []const u8,
) !void {
    if (!safeRelativePath(source_path) or
        !safeArchiveMemberPath(source_path) or
        std.mem.indexOf(u8, target, "..") != null or
        std.mem.indexOfScalar(u8, target, '/') != null)
    {
        return error.UnsafePath;
    }

    var caskroom_bin_buf: [1024]u8 = undefined;
    const caskroom_bin = std.fmt.bufPrint(&caskroom_bin_buf, "{s}/{s}", .{ caskroom_path, target }) catch return error.PathTooLong;
    var link_buf: [512]u8 = undefined;
    const link_path = std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ PREFIX, target }) catch return error.PathTooLong;
    try ensureDestinationAvailable(io, link_path);

    std.Io.Dir.deleteFileAbsolute(io, caskroom_bin) catch {};
    try extractArchiveMemberToFile(alloc, io, format, archive_path, source_path, caskroom_bin);

    try std.Io.Dir.symLinkAbsolute(io, caskroom_bin, link_path, .{});
}

fn extractArchiveMemberToFile(
    _: std.mem.Allocator,
    io: std.Io,
    format: DownloadFormat,
    archive_path: []const u8,
    member_path: []const u8,
    dst_path: []const u8,
) !void {
    var out = std.Io.Dir.createFileAbsolute(io, dst_path, .{ .permissions = .executable_file }) catch return error.ExtractFailed;
    defer out.close(io);

    const argv: []const []const u8 = switch (format) {
        .zip => &.{ "unzip", "-p", archive_path, member_path },
        .tar_gz => &.{ "tar", "-xOzf", archive_path, member_path },
        .tar_xz => &.{ "tar", "-xOJf", archive_path, member_path },
        else => return error.UnsupportedArchive,
    };

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .ignore,
    }) catch return error.ExtractFailed;
    defer child.kill(io);

    const term = child.wait(io) catch return error.ExtractFailed;
    if (switch (term) {
        .exited => |code| code != 0,
        else => true,
    }) {
        std.Io.Dir.deleteFileAbsolute(io, dst_path) catch {};
        return error.ExtractFailed;
    }
}

fn writeArtifactWarning(io: std.Io, message: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, message) catch {};
}

fn clearQuarantineIfPresent(alloc: std.mem.Allocator, io: std.Io, path: []const u8, recursive: bool) void {
    if (builtin.os.tag != .macos) return;
    if (!quarantineClearingEnabled()) return;

    const check = std.process.run(alloc, io, .{
        .argv = &.{ "xattr", "-p", "com.apple.quarantine", path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return;
    defer alloc.free(check.stdout);
    defer alloc.free(check.stderr);
    if (switch (check.term) {
        .exited => |code| code != 0,
        else => true,
    }) return;

    const argv: []const []const u8 = if (recursive)
        &.{ "xattr", "-dr", "com.apple.quarantine", path }
    else
        &.{ "xattr", "-d", "com.apple.quarantine", path };
    const clear = std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    }) catch return;
    alloc.free(clear.stdout);
    alloc.free(clear.stderr);
}

fn quarantineClearingEnabled() bool {
    const value = std.c.getenv("NANOBREW_CASK_CLEAR_QUARANTINE") orelse return false;
    const span = std.mem.span(value);
    return span.len == 0 or !std.mem.eql(u8, span, "0");
}

fn safeRelativePath(path: []const u8) bool {
    return path.len > 0 and
        !std.mem.startsWith(u8, path, "/") and
        std.mem.indexOf(u8, path, "..") == null;
}

fn safeArchiveMemberPath(path: []const u8) bool {
    return safeRelativePath(path) and
        std.mem.indexOfAny(u8, path, "*?[\\") == null;
}

test "firstAppInstallConflictIn detects existing app destination" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(std.testing.io, "Google Chrome.app", .default_dir);

    var applications_buf: [std.fs.max_path_bytes]u8 = undefined;
    const applications_dir = try std.fmt.bufPrint(&applications_buf, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path[0..]});
    const artifacts = [_]Artifact{.{ .app = "Google Chrome.app" }};
    const cask = Cask{
        .token = "google-chrome",
        .name = "Google Chrome",
        .version = "1.0.0",
        .url = "https://example.test/googlechrome.dmg",
        .sha256 = "no_check",
        .homepage = "https://example.test",
        .desc = "Web browser",
        .auto_updates = true,
        .artifacts = &artifacts,
        .min_macos = null,
    };

    const conflict = try firstAppInstallConflictIn(std.testing.io, applications_dir, &cask);
    try std.testing.expect(conflict != null);
    try std.testing.expectEqualStrings("Google Chrome.app", conflict.?);
}

test "firstAppInstallConflictIn ignores absent app destination" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var applications_buf: [std.fs.max_path_bytes]u8 = undefined;
    const applications_dir = try std.fmt.bufPrint(&applications_buf, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path[0..]});
    const artifacts = [_]Artifact{.{ .app = "Google Chrome.app" }};
    const cask = Cask{
        .token = "google-chrome",
        .name = "Google Chrome",
        .version = "1.0.0",
        .url = "https://example.test/googlechrome.dmg",
        .sha256 = "no_check",
        .homepage = "https://example.test",
        .desc = "Web browser",
        .auto_updates = true,
        .artifacts = &artifacts,
        .min_macos = null,
    };

    const conflict = try firstAppInstallConflictIn(std.testing.io, applications_dir, &cask);
    try std.testing.expect(conflict == null);
}

test "firstInstallConflictIn detects existing font destination" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "Library/Fonts");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "Library/Fonts/Example.ttf",
        .data = "existing font",
    });

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_dir = try std.fmt.bufPrint(&home_buf, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path[0..]});
    const artifacts = [_]Artifact{.{ .font = "fonts/Example.ttf" }};
    const cask = Cask{
        .token = "example-font",
        .name = "Example Font",
        .version = "1.0.0",
        .url = "https://example.test/example.zip",
        .sha256 = "no_check",
        .homepage = "https://example.test",
        .desc = "Font",
        .auto_updates = false,
        .artifacts = &artifacts,
        .min_macos = null,
    };

    var conflict_buf: [1024]u8 = undefined;
    const conflict = try firstInstallConflictIn(std.testing.io, "/Applications", home_dir, &cask, &conflict_buf);
    try std.testing.expect(conflict != null);
    try std.testing.expectEqualStrings("font", conflict.?.kind);
    try std.testing.expect(std.mem.endsWith(u8, conflict.?.path, "/Library/Fonts/Example.ttf"));
}

test "copyPath refuses to overwrite existing destination" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "source.txt",
        .data = "new",
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "dest.txt",
        .data = "old",
    });

    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, ".zig-cache/tmp/{s}/source.txt", .{tmp_dir.sub_path[0..]});
    var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, ".zig-cache/tmp/{s}/dest.txt", .{tmp_dir.sub_path[0..]});

    try std.testing.expectError(error.DestinationAlreadyExists, copyPath(std.testing.allocator, std.testing.io, src, dst));
}

fn expandInstallPath(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, value, "$HOMEBREW_PREFIX/")) {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ PREFIX, value["$HOMEBREW_PREFIX/".len..] });
    }
    return alloc.dupe(u8, value);
}

fn parentPath(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse "/";
}

fn copyPath(alloc: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) !void {
    try ensureDestinationAvailable(io, dst);

    const parent = parentPath(dst);
    const mkdir = try std.process.run(alloc, io, .{ .argv = &.{ "mkdir", "-p", parent } });
    defer alloc.free(mkdir.stdout);
    defer alloc.free(mkdir.stderr);
    if (switch (mkdir.term) {
        .exited => |c| c != 0,
        else => true,
    }) return error.CopyFailed;

    try ensureDestinationAvailable(io, dst);

    const cp = try std.process.run(alloc, io, .{ .argv = &.{ "cp", "-R", src, dst } });
    defer alloc.free(cp.stdout);
    defer alloc.free(cp.stderr);
    if (switch (cp.term) {
        .exited => |c| c != 0,
        else => true,
    }) return error.CopyFailed;
}

fn copyGenericArtifact(
    alloc: std.mem.Allocator,
    io: std.Io,
    source_dir: []const u8,
    source_path: []const u8,
    target_path: []const u8,
) !void {
    if (!safeRelativePath(source_path) or std.mem.indexOf(u8, target_path, "..") != null) {
        return error.UnsafePath;
    }
    const expanded_target = try expandInstallPath(alloc, target_path);
    defer alloc.free(expanded_target);
    if (!std.mem.startsWith(u8, expanded_target, PREFIX)) return error.UnsafePath;

    var src_buf: [1024]u8 = undefined;
    const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ source_dir, source_path }) catch return error.PathTooLong;
    try copyPath(alloc, io, src, expanded_target);
}

fn runInstallerScript(
    alloc: std.mem.Allocator,
    io: std.Io,
    format: DownloadFormat,
    dl_path: []const u8,
    source_dir: []const u8,
    executable: []const u8,
    args: []const []const u8,
) !void {
    if (!safeRelativePath(executable)) return error.UnsafePath;
    const exe_path = if (format == .shell_script) blk: {
        const chmod = try std.process.run(alloc, io, .{ .argv = &.{ "chmod", "+x", dl_path } });
        alloc.free(chmod.stdout);
        alloc.free(chmod.stderr);
        break :blk dl_path;
    } else blk: {
        var exe_buf: [1024]u8 = undefined;
        break :blk std.fmt.bufPrint(&exe_buf, "{s}/{s}", .{ source_dir, executable }) catch return error.PathTooLong;
    };

    var argv = try alloc.alloc([]const u8, args.len + 1);
    defer alloc.free(argv);
    argv[0] = exe_path;
    for (args, 0..) |arg, i| {
        argv[i + 1] = try expandInstallPath(alloc, arg);
    }
    defer {
        for (argv[1..]) |arg| alloc.free(arg);
    }

    const result = try std.process.run(alloc, io, .{ .argv = argv });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (switch (result.term) {
        .exited => |c| c != 0,
        else => true,
    }) return error.InstallerFailed;
}

fn extractZip(alloc: std.mem.Allocator, io: std.Io, zip_path: []const u8, dest: []const u8) !void {
    const lib_io = io;
    try ensureZipSafe(alloc, lib_io, zip_path);

    // Primary extractor: BSD `unzip`. Fast and ubiquitous.
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "unzip", "-o", "-q", zip_path, "-d", dest },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (switch (result.term) {
        .exited => |c| c != 0,
        else => true,
    }) {
        // Fallback to Apple's `ditto` on macOS — handles extended attributes,
        // code-signature resources, and zip variants that BSD unzip rejects
        // (seen on some notarized .app zips — issue #224, PureMac).
        if (comptime builtin.os.tag == .macos) {
            const ditto = std.process.run(alloc, lib_io, .{
                .argv = &.{ "ditto", "-x", "-k", zip_path, dest },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(16 * 1024),
            }) catch return error.ExtractFailed;
            defer alloc.free(ditto.stdout);
            defer alloc.free(ditto.stderr);
            if (switch (ditto.term) {
                .exited => |c| c != 0,
                else => true,
            }) return error.ExtractFailed;
            return;
        }
        return error.ExtractFailed;
    }
}

fn ensureZipSafe(alloc: std.mem.Allocator, io: std.Io, zip_path: []const u8) !void {
    try ensureZipEntriesSafe(alloc, io, &.{ "unzip", "-Z1", zip_path });
}

fn ensureZipPatternSafe(alloc: std.mem.Allocator, io: std.Io, zip_path: []const u8, pattern: []const u8) !void {
    try ensureZipEntriesSafe(alloc, io, &.{ "unzip", "-Z1", zip_path, pattern });
}

fn ensureZipEntriesSafe(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    // Pre-list selected ZIP contents and check for path traversal.
    const list_result = std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(ZIP_LIST_STDOUT_LIMIT),
        .stderr_limit = .limited(16 * 1024),
    }) catch return error.ExtractFailed;
    defer alloc.free(list_result.stdout);
    defer alloc.free(list_result.stderr);
    if (switch (list_result.term) {
        .exited => |code| code != 0,
        else => true,
    }) return error.ExtractFailed;

    var saw_entry = false;
    var lines = std.mem.splitScalar(u8, list_result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        saw_entry = true;
        if (std.mem.startsWith(u8, trimmed, "/") or
            std.mem.indexOf(u8, trimmed, "../") != null or
            std.mem.indexOf(u8, trimmed, "/..") != null)
        {
            return error.UnsafePath;
        }
    }
    if (!saw_entry) return error.ExtractFailed;
}

fn extractTarGz(alloc: std.mem.Allocator, io: std.Io, tar_path: []const u8, dest: []const u8) !void {
    const lib_io = io;
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "tar", "-xzf", tar_path, "--no-same-permissions", "-C", dest },
        .stdout_limit = .limited(4096),
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (switch (result.term) {
        .exited => |c| c != 0,
        else => true,
    }) return error.ExtractFailed;
}

fn extractTarXz(alloc: std.mem.Allocator, io: std.Io, tar_path: []const u8, dest: []const u8) !void {
    const lib_io = io;
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "tar", "-xJf", tar_path, "--no-same-permissions", "-C", dest },
        .stdout_limit = .limited(4096),
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (switch (result.term) {
        .exited => |c| c != 0,
        else => true,
    }) return error.ExtractFailed;
}
