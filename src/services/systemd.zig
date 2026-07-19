// nanobrew — systemd service management (Linux)
//
// Discovers and controls systemd services for installed packages.
// Scans Cellar for .service files.

const std = @import("std");
const paths = @import("../platform/paths.zig");

pub const Service = struct {
    name: []const u8,
    label: []const u8,
    plist_path: []const u8, // actually .service path — named for API compat
    keg_name: []const u8,
    keg_version: []const u8,
};

pub fn discoverServices(alloc: std.mem.Allocator, io: std.Io) ![]Service {
    const lib_io = io;
    var services: std.ArrayList(Service) = .empty;
    defer services.deinit(alloc);

    var cellar = std.Io.Dir.openDirAbsolute(lib_io, paths.CELLAR_DIR, .{ .iterate = true }) catch return try services.toOwnedSlice(alloc);
    defer cellar.close(lib_io);

    var keg_iter = cellar.iterate();
    while (keg_iter.next(lib_io) catch null) |keg_entry| {
        if (keg_entry.kind != .directory) continue;
        if (keg_entry.name.len == 0 or keg_entry.name[0] == '.') continue; // skip .purge/
        const keg_name = keg_entry.name;

        var keg_dir_buf: [512]u8 = undefined;
        const keg_dir_path = std.fmt.bufPrint(&keg_dir_buf, "{s}/{s}", .{ paths.CELLAR_DIR, keg_name }) catch continue;
        var keg_dir = std.Io.Dir.openDirAbsolute(lib_io, keg_dir_path, .{ .iterate = true }) catch continue;
        defer keg_dir.close(lib_io);

        var ver_iter = keg_dir.iterate();
        while (ver_iter.next(lib_io) catch null) |ver_entry| {
            if (ver_entry.kind != .directory) continue;
            const ver_name = ver_entry.name;

            // Search for .service files in lib/systemd/system/ and etc/systemd/system/
            const search_paths = [_][]const u8{
                "lib/systemd/system",
                "etc/systemd/system",
            };

            for (search_paths) |sub| {
                var search_buf: [1024]u8 = undefined;
                const search_path = std.fmt.bufPrint(&search_buf, "{s}/{s}/{s}", .{ keg_dir_path, ver_name, sub }) catch continue;

                var search_dir = std.Io.Dir.openDirAbsolute(lib_io, search_path, .{ .iterate = true }) catch continue;
                defer search_dir.close(lib_io);

                var file_iter = search_dir.iterate();
                while (file_iter.next(lib_io) catch null) |file_entry| {
                    if (file_entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, file_entry.name, ".service")) continue;

                    // Label is full unit name (e.g. "postgresql@14-main.service")
                    const label = file_entry.name;
                    // Service name strips .service suffix
                    const svc_name = file_entry.name[0 .. file_entry.name.len - ".service".len];

                    var svc_path_buf: [1024]u8 = undefined;
                    const svc_path = std.fmt.bufPrint(&svc_path_buf, "{s}/{s}", .{ search_path, file_entry.name }) catch continue;

                    // All-or-nothing: free any prior dupes if a later
                    // alloc or append fails so we never leak a partial.
                    const name_owned = alloc.dupe(u8, svc_name) catch continue;
                    const label_owned = alloc.dupe(u8, label) catch {
                        alloc.free(name_owned);
                        continue;
                    };
                    const svc_path_owned = alloc.dupe(u8, svc_path) catch {
                        alloc.free(name_owned);
                        alloc.free(label_owned);
                        continue;
                    };
                    const keg_name_owned = alloc.dupe(u8, keg_name) catch {
                        alloc.free(name_owned);
                        alloc.free(label_owned);
                        alloc.free(svc_path_owned);
                        continue;
                    };
                    const keg_version_owned = alloc.dupe(u8, ver_name) catch {
                        alloc.free(name_owned);
                        alloc.free(label_owned);
                        alloc.free(svc_path_owned);
                        alloc.free(keg_name_owned);
                        continue;
                    };
                    services.append(alloc, .{
                        .name = name_owned,
                        .label = label_owned,
                        .plist_path = svc_path_owned,
                        .keg_name = keg_name_owned,
                        .keg_version = keg_version_owned,
                    }) catch {
                        alloc.free(name_owned);
                        alloc.free(label_owned);
                        alloc.free(svc_path_owned);
                        alloc.free(keg_name_owned);
                        alloc.free(keg_version_owned);
                    };
                }
            }
        }
    }

    return try services.toOwnedSlice(alloc);
}

pub fn isRunning(alloc: std.mem.Allocator, io: std.Io, label: []const u8) bool {
    const lib_io = io;
    var unit_buf: [256]u8 = undefined;
    const unit = if (std.mem.endsWith(u8, label, ".service")) label else std.fmt.bufPrint(&unit_buf, "{s}.service", .{label}) catch return false;
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "systemctl", "is-active", "--quiet", unit },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return switch (result.term) { .exited => |c| c == 0, else => false };
}

pub fn isServiceFileSafe(content: []const u8, keg_prefix: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        // Reject User=root
        if (std.mem.startsWith(u8, trimmed, "User=")) {
            const value = std.mem.trimStart(u8, trimmed["User=".len..], " \t");
            if (std.mem.eql(u8, value, "root")) return false;
        }
        // Validate ExecStart points within the keg
        if (std.mem.startsWith(u8, trimmed, "ExecStart=")) {
            const value = std.mem.trimStart(u8, trimmed["ExecStart=".len..], " \t");
            // Skip leading '-' (optional prefix that suppresses failure)
            const exec_path = if (value.len > 0 and value[0] == '-') value[1..] else value;
            const end = std.mem.indexOfAny(u8, exec_path, " \t") orelse exec_path.len;
            const bin_path = exec_path[0..end];
            if (!std.mem.startsWith(u8, bin_path, keg_prefix)) return false;
            if (std.mem.indexOf(u8, bin_path, "..") != null) return false;
        }
    }
    return true;
}

pub fn start(alloc: std.mem.Allocator, io: std.Io, plist_path: []const u8) !void {
    const lib_io = io;

    // Read and validate the service file before installing
    const svc_file = std.Io.Dir.openFileAbsolute(lib_io, plist_path, .{}) catch return error.SystemdFailed;
    const svc_stat = svc_file.stat(lib_io) catch { svc_file.close(lib_io); return error.SystemdFailed; };
    const svc_size = @min(svc_stat.size, 64 * 1024);
    const svc_buf = alloc.alloc(u8, svc_size) catch { svc_file.close(lib_io); return error.SystemdFailed; };
    defer alloc.free(svc_buf);
    const svc_n = svc_file.readPositionalAll(lib_io, svc_buf, 0) catch { svc_file.close(lib_io); return error.SystemdFailed; };
    svc_file.close(lib_io);
    const svc_content = svc_buf[0..svc_n];

    if (!isServiceFileSafe(svc_content, paths.CELLAR_DIR)) {
        var msg_buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "nb: refusing to install unsafe service file: {s}\n", .{plist_path}) catch "nb: refusing to install unsafe service file\n";
        std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
        return error.SystemdFailed;
    }

    // Install the service file and start it
    const basename = std.fs.path.basename(plist_path);
    var dest_buf: [512]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "/etc/systemd/system/{s}", .{basename}) catch return error.PathTooLong;

    // Copy service file to systemd directory
    const cp = std.process.run(alloc, lib_io, .{
        .argv = &.{ "cp", plist_path, dest },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return error.SystemdFailed;
    alloc.free(cp.stdout);
    alloc.free(cp.stderr);

    // Reload and start
    const reload = std.process.run(alloc, lib_io, .{
        .argv = &.{ "systemctl", "daemon-reload" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return error.SystemdFailed;
    alloc.free(reload.stdout);
    alloc.free(reload.stderr);

    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "systemctl", "start", basename },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return error.SystemdFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (switch (result.term) { .exited => |c| c != 0, else => true }) return error.SystemdFailed;
}

pub fn stop(alloc: std.mem.Allocator, io: std.Io, plist_path: []const u8) !void {
    const lib_io = io;
    const basename = std.fs.path.basename(plist_path);
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "systemctl", "stop", basename },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return error.SystemdFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (switch (result.term) { .exited => |c| c != 0, else => true }) return error.SystemdFailed;
}
