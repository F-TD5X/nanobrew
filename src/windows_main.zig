// nanobrew — native Windows portable package manager
//
// This is not a winget/scoop/choco wrapper. It owns a small Windows Cellar in
// %LOCALAPPDATA%\nanobrew, downloads verified portable upstream assets,
// extracts/copies them into Cellar, and places runnable .exe files in bin.

const std = @import("std");

const VERSION = "0.1.200";

var g_io: std.Io = undefined;

const Package = struct {
    name: []const u8,
    version: []const u8,
    desc: []const u8,
    url: []const u8,
    sha256: []const u8,
    kind: enum { zip, exe },
    bins: []const []const u8,
};

const packages = [_]Package{
    .{ .name = "ripgrep", .version = "15.1.0", .desc = "Fast recursive search tool", .url = "https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep-15.1.0-x86_64-pc-windows-msvc.zip", .sha256 = "124510b94b6baa3380d051fdf4650eaa80a302c876d611e9dba0b2e18d87493a", .kind = .zip, .bins = &.{"rg.exe"} },
    .{ .name = "fd", .version = "10.4.2", .desc = "Simple, fast alternative to find", .url = "https://github.com/sharkdp/fd/releases/download/v10.4.2/fd-v10.4.2-x86_64-pc-windows-msvc.zip", .sha256 = "b2816e506390a89941c63c9187d58a3cc10e9a55f2ef0685f9ea0eccaf7c98c8", .kind = .zip, .bins = &.{"fd.exe"} },
    .{ .name = "bat", .version = "0.26.1", .desc = "cat clone with syntax highlighting", .url = "https://github.com/sharkdp/bat/releases/download/v0.26.1/bat-v0.26.1-x86_64-pc-windows-msvc.zip", .sha256 = "0f729b4b6f5f28d395c641eacc2e9ff68d0096b85aa0eec344aa62425144b69b", .kind = .zip, .bins = &.{"bat.exe"} },
    .{ .name = "jq", .version = "1.8.2", .desc = "Command-line JSON processor", .url = "https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-amd64.exe", .sha256 = "a6fc67fedaf9128a3309a1e2ebb8b986aeccf70122ee46d2cb4849e423f0c627", .kind = .exe, .bins = &.{"jq.exe"} },
    .{ .name = "uv", .version = "0.11.24", .desc = "Fast Python package installer and resolver", .url = "https://github.com/astral-sh/uv/releases/download/0.11.24/uv-x86_64-pc-windows-msvc.zip", .sha256 = "af9573a2e36f7020b18ec5fdde20117aae74bbad3f4acb3dc3fc03319f1aa083", .kind = .zip, .bins = &.{ "uv.exe", "uvx.exe" } },
    .{ .name = "yq", .version = "4.53.3", .desc = "Portable YAML, JSON, XML, CSV and TOML processor", .url = "https://github.com/mikefarah/yq/releases/download/v4.53.3/yq_windows_amd64.exe", .sha256 = "e279bc506a452eeafcdf364f91a025455e402a8001169083caf01f4b64a544e2", .kind = .exe, .bins = &.{"yq.exe"} },
    .{ .name = "just", .version = "1.54.0", .desc = "Command runner", .url = "https://github.com/casey/just/releases/download/1.54.0/just-1.54.0-x86_64-pc-windows-msvc.zip", .sha256 = "860e21474e956eaa9879d62f68cc24530254eefe14ac108eaf707c0daf56a6d0", .kind = .zip, .bins = &.{"just.exe"} },
    .{ .name = "hyperfine", .version = "1.20.0", .desc = "Command-line benchmarking tool", .url = "https://github.com/sharkdp/hyperfine/releases/download/v1.20.0/hyperfine-v1.20.0-x86_64-pc-windows-msvc.zip", .sha256 = "2508c549b049b1d4342d08edc1cb42bfac169082b6e3069431b5bab9822dbb32", .kind = .zip, .bins = &.{"hyperfine.exe"} },
    .{ .name = "fzf", .version = "0.73.1", .desc = "Command-line fuzzy finder", .url = "https://github.com/junegunn/fzf/releases/download/v0.73.1/fzf-0.73.1-windows_amd64.zip", .sha256 = "521a974dc32e93404265e55bffaf71a59e05e80abdf8ca4afb21a6030dc76f5f", .kind = .zip, .bins = &.{"fzf.exe"} },
    .{ .name = "starship", .version = "1.25.1", .desc = "Fast cross-shell prompt", .url = "https://github.com/starship/starship/releases/download/v1.25.1/starship-x86_64-pc-windows-msvc.zip", .sha256 = "a07cf3e428afab09324e510fb786041ebcc491a68b1ca6fba044c5a461f9b017", .kind = .zip, .bins = &.{"starship.exe"} },
    .{ .name = "eza", .version = "0.23.4", .desc = "Modern replacement for ls", .url = "https://github.com/eza-community/eza/releases/download/v0.23.4/eza.exe_x86_64-pc-windows-gnu.zip", .sha256 = "05677fd7c2d1b69ce71df53db74c29f6331ea0b2be5aa3a0fce6976200ee06fc", .kind = .zip, .bins = &.{"eza.exe"} },
    .{ .name = "delta", .version = "0.19.2", .desc = "Syntax-highlighting pager for git, diff, and grep output", .url = "https://github.com/dandavison/delta/releases/download/0.19.2/delta-0.19.2-x86_64-pc-windows-msvc.zip", .sha256 = "ac8ebb4a9f1cbee8b9ea897ba119808a244181adae6f3bed1f3b6b923c50b557", .kind = .zip, .bins = &.{"delta.exe"} },
    .{ .name = "dust", .version = "1.2.4", .desc = "More intuitive du", .url = "https://github.com/bootandy/dust/releases/download/v1.2.4/dust-v1.2.4-x86_64-pc-windows-msvc.zip", .sha256 = "eb08d642f016787bb9fc918a4dc5f34665463657fddf83a40f2441cbf020fb4c", .kind = .zip, .bins = &.{"dust.exe"} },
    .{ .name = "bottom", .version = "0.14.1", .desc = "Graphical process and system monitor", .url = "https://github.com/ClementTsang/bottom/releases/download/0.14.1/bottom_x86_64-pc-windows-msvc.zip", .sha256 = "a67328662f2c7cfbceff19734efefa9d07db4ce146af9e1a03dfdda6f54271d3", .kind = .zip, .bins = &.{"btm.exe"} },
    .{ .name = "zoxide", .version = "0.9.9", .desc = "Smarter cd command", .url = "https://github.com/ajeetdsouza/zoxide/releases/download/v0.9.9/zoxide-0.9.9-x86_64-pc-windows-msvc.zip", .sha256 = "5af00d0916f05631e3030537289eac56605e7c1733318c4d525c8e847f12496d", .kind = .zip, .bins = &.{"zoxide.exe"} },
    .{ .name = "sd", .version = "1.1.0", .desc = "Intuitive find and replace CLI", .url = "https://github.com/chmln/sd/releases/download/v1.1.0/sd-v1.1.0-x86_64-pc-windows-msvc.zip", .sha256 = "59837c2e7c911099aca1cc46b663bcdc5a949fd3e9fbbaf34fc73e5d5d71007c", .kind = .zip, .bins = &.{"sd.exe"} },
    .{ .name = "hexyl", .version = "0.17.0", .desc = "Command-line hex viewer", .url = "https://github.com/sharkdp/hexyl/releases/download/v0.17.0/hexyl-v0.17.0-x86_64-pc-windows-msvc.zip", .sha256 = "ab5c3442cff63f585553d4fce330eaa1ef1bd2584643f1a0e29ab7c13fc9566d", .kind = .zip, .bins = &.{"hexyl.exe"} },
    .{ .name = "dua", .version = "2.37.0", .desc = "Disk usage analyzer", .url = "https://github.com/Byron/dua-cli/releases/download/v2.37.0/dua-v2.37.0-x86_64-pc-windows-msvc.zip", .sha256 = "e66a99e6139b076f8da4ef269ce5452ef6636dfba66d4495f08ae18ad2c369c3", .kind = .zip, .bins = &.{"dua.exe"} },
    .{ .name = "procs", .version = "0.14.12", .desc = "Modern replacement for ps", .url = "https://github.com/dalance/procs/releases/download/v0.14.12/procs-v0.14.12-x86_64-windows.zip", .sha256 = "4928c399ae78ee82f99139a5629077b8d90a58599d834584dd4e613cb60c83d0", .kind = .zip, .bins = &.{"procs.exe"} },
};

const Dirs = struct { root: []u8, cellar: []u8, bin: []u8, cache: []u8, db: []u8, state: []u8 };

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    const alloc = init.gpa;
    const args_raw = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try init.arena.allocator().alloc([]const u8, args_raw.len);
    for (args, args_raw) |*dst, src| dst.* = src;

    if (args.len < 2 or eql(args[1], "help") or eql(args[1], "--help") or eql(args[1], "-h")) {
        printUsage();
        std.process.exit(if (args.len < 2) 1 else 0);
    }

    const cmd = args[1];
    if (eql(cmd, "version")) {
        out("nanobrew {s} (native windows)\n", .{VERSION});
    } else if (eql(cmd, "init")) {
        const dirs = try getDirs(alloc);
        try ensureDirs(dirs);
        out("nanobrew initialized at {s}\n", .{dirs.root});
        out("Add to PATH: {s}\n", .{dirs.bin});
        out("PowerShell: [Environment]::SetEnvironmentVariable('Path', $env:Path + ';{s}', 'User')\n", .{dirs.bin});
    } else if (eql(cmd, "search")) {
        if (args.len < 3) die("nb: search query required\n", .{});
        var matches: usize = 0;
        for (packages) |p| {
            if (containsCaseless(p.name, args[2]) or containsCaseless(p.desc, args[2])) {
                out("{s} {s} — {s}\n", .{ p.name, p.version, p.desc });
                matches += 1;
            }
        }
        if (matches == 0) out("No packages found for '{s}'.\n", .{args[2]});
    } else if (eql(cmd, "install") or eql(cmd, "i")) {
        if (args.len < 3) die("nb: package required\n", .{});
        const dirs = try getDirs(alloc);
        try ensureDirs(dirs);
        for (args[2..]) |name| try installPackage(alloc, dirs, findPackage(name) orelse {
            err("nb: package not found: {s}\n", .{name});
            std.process.exit(1);
        });
    } else if (eql(cmd, "remove") or eql(cmd, "rm") or eql(cmd, "uninstall")) {
        if (args.len < 3) die("nb: package required\n", .{});
        const dirs = try getDirs(alloc);
        for (args[2..]) |name| try removePackage(alloc, dirs, name);
    } else if (eql(cmd, "list") or eql(cmd, "ls")) {
        const dirs = try getDirs(alloc);
        try listInstalled(alloc, dirs);
    } else if (eql(cmd, "upgrade")) {
        const dirs = try getDirs(alloc);
        if (args.len > 2) {
            for (args[2..]) |name| try installPackage(alloc, dirs, findPackage(name) orelse {
                err("nb: package not found: {s}\n", .{name});
                std.process.exit(1);
            });
        } else {
            var installed = try readState(alloc, dirs);
            defer installed.deinit(alloc);
            for (installed.items) |rec| if (findPackage(rec.name)) |p| try installPackage(alloc, dirs, p);
        }
    } else if (eql(cmd, "doctor")) {
        const dirs = try getDirs(alloc);
        out("root: {s}\n", .{dirs.root});
        out("bin:  {s}\n", .{dirs.bin});
        if (pathExists(dirs.bin)) out("  ✓ bin exists\n", .{}) else out("  ✗ bin missing (run nb init)\n", .{});
        if (pathContains(alloc, dirs.bin)) {
            out("  ✓ bin is on PATH\n", .{});
        } else {
            out("  ! bin is not on PATH for this shell\n", .{});
            out("    add it with: [Environment]::SetEnvironmentVariable('Path', $env:Path + ';{s}', 'User')\n", .{dirs.bin});
        }
    } else {
        die("nb: unknown command '{s}'\n", .{cmd});
    }
}

fn installPackage(alloc: std.mem.Allocator, dirs: Dirs, p: Package) !void {
    out("==> Installing {s} {s}\n", .{ p.name, p.version });
    var archive_name_buf: [256]u8 = undefined;
    const ext = if (p.kind == .zip) ".zip" else ".exe";
    const archive_name = try std.fmt.bufPrint(&archive_name_buf, "{s}-{s}{s}", .{ p.name, p.version, ext });
    const archive = try join(alloc, &.{ dirs.cache, archive_name });
    defer alloc.free(archive);
    if (!pathExists(archive)) try powershell(alloc, &.{ "Invoke-WebRequest", "-Uri", p.url, "-OutFile", archive });
    try verifySha256(alloc, archive, p.sha256);

    const pkg_root = try join(alloc, &.{ dirs.cellar, p.name });
    defer alloc.free(pkg_root);
    const pkg_dir = try join(alloc, &.{ pkg_root, p.version });
    defer alloc.free(pkg_dir);
    std.Io.Dir.cwd().deleteTree(io(), pkg_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io(), pkg_dir);

    switch (p.kind) {
        .zip => {
            try powershell(alloc, &.{ "Expand-Archive", "-LiteralPath", archive, "-DestinationPath", pkg_dir, "-Force" });
            for (p.bins) |bin| {
                const src = try findFileRecursive(alloc, pkg_dir, bin) orelse return error.BinaryNotFound;
                defer alloc.free(src);
                const dst_cellar = try join(alloc, &.{ pkg_dir, bin });
                defer alloc.free(dst_cellar);
                if (!eql(src, dst_cellar)) try copyFile(src, dst_cellar);
            }
        },
        .exe => {
            const dst_cellar = try join(alloc, &.{ pkg_dir, p.bins[0] });
            defer alloc.free(dst_cellar);
            try copyFile(archive, dst_cellar);
        },
    }

    for (p.bins) |bin| {
        const src = try join(alloc, &.{ pkg_dir, bin });
        defer alloc.free(src);
        const dst = try join(alloc, &.{ dirs.bin, bin });
        defer alloc.free(dst);
        try copyFile(src, dst);
        out("  linked {s}\n", .{dst});
    }
    try recordInstall(alloc, dirs, p);
    out("==> Installed {s} {s}\n", .{ p.name, p.version });
}

fn removePackage(alloc: std.mem.Allocator, dirs: Dirs, name: []const u8) !void {
    const p = findPackage(name);
    if (p) |pkg| for (pkg.bins) |bin| {
        const dst = try join(alloc, &.{ dirs.bin, bin });
        defer alloc.free(dst);
        std.Io.Dir.cwd().deleteFile(io(), dst) catch {};
    };
    const root = try join(alloc, &.{ dirs.cellar, name });
    defer alloc.free(root);
    std.Io.Dir.cwd().deleteTree(io(), root) catch {};
    try removeState(alloc, dirs, name);
    out("==> Removed {s}\n", .{name});
}

const Record = struct { name: []u8, version: []u8 };
const State = struct {
    items: []Record,
    pub fn deinit(self: State, alloc: std.mem.Allocator) void {
        for (self.items) |r| {
            alloc.free(r.name);
            alloc.free(r.version);
        }
        alloc.free(self.items);
    }
};

fn readState(alloc: std.mem.Allocator, dirs: Dirs) !std.ArrayList(Record) {
    var list: std.ArrayList(Record) = .empty;
    const data = readFileAlloc(alloc, dirs.state, 1024 * 1024) catch return list;
    defer alloc.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '\t');
        const n = parts.next() orelse continue;
        const v = parts.next() orelse continue;
        try list.append(alloc, .{ .name = try alloc.dupe(u8, n), .version = try alloc.dupe(u8, v) });
    }
    return list;
}

fn recordInstall(alloc: std.mem.Allocator, dirs: Dirs, p: Package) !void {
    var records = try readState(alloc, dirs);
    defer {
        for (records.items) |r| {
            alloc.free(r.name);
            alloc.free(r.version);
        }
        records.deinit(alloc);
    }
    var found = false;
    for (records.items) |*r| if (eql(r.name, p.name)) {
        alloc.free(r.version);
        r.version = try alloc.dupe(u8, p.version);
        found = true;
    };
    if (!found) try records.append(alloc, .{ .name = try alloc.dupe(u8, p.name), .version = try alloc.dupe(u8, p.version) });
    try writeState(alloc, dirs, records.items);
}

fn removeState(alloc: std.mem.Allocator, dirs: Dirs, name: []const u8) !void {
    var records = try readState(alloc, dirs);
    defer {
        for (records.items) |r| {
            alloc.free(r.name);
            alloc.free(r.version);
        }
        records.deinit(alloc);
    }
    var kept: std.ArrayList(Record) = .empty;
    defer kept.deinit(alloc);
    for (records.items) |r| if (!eql(r.name, name)) try kept.append(alloc, r);
    try writeState(alloc, dirs, kept.items);
}

fn writeState(alloc: std.mem.Allocator, dirs: Dirs, records: []const Record) !void {
    var outw: std.Io.Writer.Allocating = .init(alloc);
    defer outw.deinit();
    for (records) |r| try outw.writer.print("{s}\t{s}\n", .{ r.name, r.version });
    const data = try outw.toOwnedSlice();
    defer alloc.free(data);
    try writeFile(dirs.state, data);
}

fn listInstalled(alloc: std.mem.Allocator, dirs: Dirs) !void {
    var records = try readState(alloc, dirs);
    defer {
        for (records.items) |r| {
            alloc.free(r.name);
            alloc.free(r.version);
        }
        records.deinit(alloc);
    }
    for (records.items) |r| out("{s} {s}\n", .{ r.name, r.version });
}

fn verifySha256(alloc: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    const data = try readFileAlloc(alloc, path, 128 * 1024 * 1024);
    defer alloc.free(data);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    var hex: [64]u8 = undefined;
    const charset = "0123456789abcdef";
    for (digest, 0..) |byte, idx| {
        hex[idx * 2] = charset[byte >> 4];
        hex[idx * 2 + 1] = charset[byte & 0x0f];
    }
    if (!std.mem.eql(u8, &hex, expected)) return error.ChecksumMismatch;
}

fn powershell(alloc: std.mem.Allocator, words: []const []const u8) !void {
    var script: std.Io.Writer.Allocating = .init(alloc);
    defer script.deinit();
    for (words, 0..) |w, i| {
        if (i > 0) try script.writer.writeByte(' ');
        if (i == 0 or std.mem.startsWith(u8, w, "-")) {
            try script.writer.writeAll(w);
        } else {
            try script.writer.writeByte('\'');
            for (w) |c| {
                if (c == '\'') try script.writer.writeAll("''") else try script.writer.writeByte(c);
            }
            try script.writer.writeByte('\'');
        }
    }
    const s = try script.toOwnedSlice();
    defer alloc.free(s);
    const result = std.process.run(std.heap.smp_allocator, io(), .{ .argv = &.{ "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", s }, .stdout_limit = .unlimited, .stderr_limit = .unlimited }) catch |err_| {
        err("powershell launch failed: {}\n", .{err_});
        return error.PowerShellFailed;
    };
    defer std.heap.smp_allocator.free(result.stdout);
    defer std.heap.smp_allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.Io.File.stdout().writeStreamingAll(io(), result.stdout) catch {};
        std.Io.File.stdout().writeStreamingAll(io(), result.stderr) catch {};
        return error.PowerShellFailed;
    }
}

fn findFileRecursive(alloc: std.mem.Allocator, root: []const u8, basename: []const u8) !?[]u8 {
    var dir = std.Io.Dir.openDirAbsolute(io(), root, .{ .iterate = true }) catch return null;
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |e| {
        const p = try join(alloc, &.{ root, e.name });
        if (e.kind == .file and eql(e.name, basename)) return p;
        if (e.kind == .directory) {
            if (try findFileRecursive(alloc, p, basename)) |found| {
                alloc.free(p);
                return found;
            }
        }
        alloc.free(p);
    }
    return null;
}

fn getDirs(alloc: std.mem.Allocator) !Dirs {
    const local_raw = getEnvValue(alloc, "LOCALAPPDATA") catch try getEnvValue(alloc, "USERPROFILE");
    defer alloc.free(local_raw);
    const local = std.mem.trim(u8, local_raw, " \r\n\t");
    const root = try join(alloc, &.{ local, "nanobrew" });
    const cellar = try join(alloc, &.{ root, "Cellar" });
    const bin = try join(alloc, &.{ root, "bin" });
    const cache = try join(alloc, &.{ root, "cache" });
    const db = try join(alloc, &.{ root, "db" });
    const state = try join(alloc, &.{ db, "state.tsv" });
    return .{ .root = root, .cellar = cellar, .bin = bin, .cache = cache, .db = db, .state = state };
}

fn io() std.Io {
    return g_io;
}

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io(), path, .{});
    defer file.close(io());
    const st = try file.stat(io());
    if (st.size > max) return error.FileTooBig;
    const buf = try alloc.alloc(u8, @intCast(st.size));
    const n = try file.readPositionalAll(io(), buf, 0);
    return buf[0..n];
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io(), path, .{});
    defer file.close(io());
    try file.writeStreamingAll(io(), data);
}

fn getEnvValue(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var name_buf: [64:0]u8 = undefined;
    if (name.len >= name_buf.len) return error.EnvMissing;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const raw = std.c.getenv(@ptrCast(&name_buf)) orelse return error.EnvMissing;
    return alloc.dupe(u8, std.mem.span(raw));
}

fn ensureDirs(dirs: Dirs) !void {
    try std.Io.Dir.cwd().createDirPath(io(), dirs.cellar);
    try std.Io.Dir.cwd().createDirPath(io(), dirs.bin);
    try std.Io.Dir.cwd().createDirPath(io(), dirs.cache);
    try std.Io.Dir.cwd().createDirPath(io(), dirs.db);
}
fn copyFile(src: []const u8, dst: []const u8) !void {
    try powershell(std.heap.smp_allocator, &.{ "Copy-Item", "-LiteralPath", src, "-Destination", dst, "-Force" });
}
fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}
fn join(alloc: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(alloc, parts);
}
fn findPackage(name: []const u8) ?Package {
    for (packages) |p| if (eql(p.name, name)) return p;
    return null;
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn containsCaseless(haystack: []const u8, needle: []const u8) bool {
    var hb: [256]u8 = undefined;
    var nb: [128]u8 = undefined;
    const h = lower(&hb, haystack);
    const n = lower(&nb, needle);
    return std.mem.indexOf(u8, h, n) != null;
}
fn pathContains(alloc: std.mem.Allocator, bin: []const u8) bool {
    const path = getEnvValue(alloc, "PATH") catch getEnvValue(alloc, "Path") catch return false;
    defer alloc.free(path);
    var it = std.mem.splitScalar(u8, path, ';');
    while (it.next()) |entry| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, entry, " \""), bin)) return true;
    return false;
}

fn lower(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}
fn out(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch return;
    defer std.heap.smp_allocator.free(msg);
    std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
}
fn err(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch return;
    defer std.heap.smp_allocator.free(msg);
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
}
fn die(comptime fmt: []const u8, args: anytype) noreturn {
    err(fmt, args);
    std.process.exit(1);
}

fn printUsage() void {
    out(
        \\nanobrew {s} — native Windows portable package manager
        \\
        \\USAGE:
        \\  nb <command> [arguments]
        \\
        \\COMMANDS:
        \\  init                    Create %LOCALAPPDATA%\\nanobrew
        \\  search <query>          Search nanobrew's Windows registry
        \\  install <package>       Download, verify, extract, and link a package
        \\  upgrade [package]       Reinstall one package or all installed packages
        \\  remove <package>        Remove package files and linked executables
        \\  list                    List installed packages
        \\  doctor                  Show nanobrew Windows paths
        \\  version                 Show version
        \\
        \\AVAILABLE NOW:
        \\  ripgrep, fd, bat, jq, uv, yq, just, hyperfine, fzf, starship
        \\  eza, delta, dust, bottom, zoxide, sd, hexyl, dua, procs
        \\
    , .{VERSION});
}
