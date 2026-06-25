// nanobrew — Windows package-manager bridge
//
// Native Windows does not have Homebrew bottles/Cellar semantics. This entry
// point gives Windows users a nanobrew-shaped CLI over the package managers
// that actually work well on Windows: WinGet by default, with Scoop and
// Chocolatey selectable for brew-style/dev workflows.

const std = @import("std");

const VERSION = "0.1.199";

const Backend = enum { winget, scoop, choco };

const Stdout = struct {
    fn print(comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch return;
        defer std.heap.smp_allocator.free(msg);
        std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
    }
};

const Stderr = struct {
    fn print(comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch return;
        defer std.heap.smp_allocator.free(msg);
        std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const args_raw = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try init.arena.allocator().alloc([]const u8, args_raw.len);
    for (args, args_raw) |*dst, src| dst.* = src;

    if (args.len < 2 or std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        printUsage();
        std.process.exit(if (args.len < 2) 1 else 0);
    }

    var backend: Backend = .winget;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(alloc);
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--winget")) backend = .winget
        else if (std.mem.eql(u8, arg, "--scoop")) backend = .scoop
        else if (std.mem.eql(u8, arg, "--choco") or std.mem.eql(u8, arg, "--chocolatey")) backend = .choco
        else try rest.append(alloc, arg);
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version")) {
        Stdout.print("nanobrew {s} (windows bridge)\n", .{VERSION});
    } else if (std.mem.eql(u8, cmd, "search")) {
        try runBackend(alloc, backend, .search, rest.items);
    } else if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "i")) {
        try runBackend(alloc, backend, .install, rest.items);
    } else if (std.mem.eql(u8, cmd, "upgrade")) {
        try runBackend(alloc, backend, .upgrade, rest.items);
    } else if (std.mem.eql(u8, cmd, "remove") or std.mem.eql(u8, cmd, "uninstall") or std.mem.eql(u8, cmd, "rm")) {
        try runBackend(alloc, backend, .remove, rest.items);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        try runBackend(alloc, backend, .list, rest.items);
    } else if (std.mem.eql(u8, cmd, "doctor")) {
        try runDoctor(alloc);
    } else {
        Stderr.print("nb: unsupported Windows command '{s}'\n\n", .{cmd});
        printUsage();
        std.process.exit(1);
    }
}

const Op = enum { search, install, upgrade, remove, list };

fn runBackend(alloc: std.mem.Allocator, backend: Backend, op: Op, args: []const []const u8) !void {
    if (needsPackage(op) and args.len == 0) {
        Stderr.print("nb: package/query required\n", .{});
        std.process.exit(1);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    switch (backend) {
        .winget => try wingetArgv(alloc, &argv, op, args),
        .scoop => try scoopArgv(alloc, &argv, op, args),
        .choco => try chocoArgv(alloc, &argv, op, args),
    }
    try runPassthrough(alloc, argv.items);
}

fn needsPackage(op: Op) bool {
    return switch (op) { .search, .install, .remove => true, .upgrade, .list => false };
}

fn wingetArgv(alloc: std.mem.Allocator, argv: *std.ArrayList([]const u8), op: Op, args: []const []const u8) !void {
    try argv.append(alloc, "winget");
    switch (op) {
        .search => try argv.append(alloc, "search"),
        .install => { try argv.append(alloc, "install"); try argv.append(alloc, "--id"); },
        .upgrade => try argv.appendSlice(alloc, if (args.len == 0) &.{ "upgrade", "--all" } else &.{"upgrade"}),
        .remove => { try argv.append(alloc, "uninstall"); try argv.append(alloc, "--id"); },
        .list => try argv.append(alloc, "list"),
    }
    try argv.appendSlice(alloc, args);
}

fn scoopArgv(alloc: std.mem.Allocator, argv: *std.ArrayList([]const u8), op: Op, args: []const []const u8) !void {
    try argv.append(alloc, "scoop");
    switch (op) {
        .search => try argv.append(alloc, "search"),
        .install => try argv.append(alloc, "install"),
        .upgrade => try argv.appendSlice(alloc, if (args.len == 0) &.{ "update", "*" } else &.{"update"}),
        .remove => try argv.append(alloc, "uninstall"),
        .list => try argv.append(alloc, "list"),
    }
    try argv.appendSlice(alloc, args);
}

fn chocoArgv(alloc: std.mem.Allocator, argv: *std.ArrayList([]const u8), op: Op, args: []const []const u8) !void {
    try argv.append(alloc, "choco");
    switch (op) {
        .search => try argv.append(alloc, "search"),
        .install => try argv.append(alloc, "install"),
        .upgrade => try argv.appendSlice(alloc, if (args.len == 0) &.{ "upgrade", "all" } else &.{"upgrade"}),
        .remove => try argv.append(alloc, "uninstall"),
        .list => try argv.append(alloc, "list"),
    }
    try argv.appendSlice(alloc, args);
}

fn runPassthrough(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    Stdout.print("==> {s}\n", .{try joinArgs(alloc, argv)});
    const result = std.process.run(alloc, std.Io.Threaded.global_single_threaded.io(), .{
        .argv = argv,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch |err| {
        Stderr.print("nb: failed to run '{s}': {}\n", .{ argv[0], err });
        std.process.exit(1);
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), result.stdout) catch {};
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), result.stderr) catch {};
    switch (result.term) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}

fn joinArgs(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (argv, 0..) |arg, idx| {
        if (idx > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(arg);
    }
    return out.toOwnedSlice();
}

fn runDoctor(alloc: std.mem.Allocator) !void {
    const tools = [_][]const u8{ "winget", "scoop", "choco" };
    var found = false;
    for (tools) |tool| {
        const result = std.process.run(alloc, std.Io.Threaded.global_single_threaded.io(), .{
            .argv = &.{ "where", tool },
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
        }) catch continue;
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        const ok = switch (result.term) { .exited => |code| code == 0, else => false };
        if (ok) {
            found = true;
            Stdout.print("  ✓ {s} found\n", .{tool});
        } else {
            Stdout.print("  - {s} not found\n", .{tool});
        }
    }
    if (!found) {
        Stderr.print("nb: no supported Windows package manager found; install winget, Scoop, or Chocolatey\n", .{});
        std.process.exit(1);
    }
}

fn printUsage() void {
    Stdout.print(
        \\nanobrew {s} — Windows package-manager bridge
        \\
        \\USAGE:
        \\  nb <command> [--winget|--scoop|--choco] [arguments]
        \\
        \\COMMANDS:
        \\  search <query>          Search packages
        \\  install <package>       Install a package (WinGet IDs by default)
        \\  upgrade [package]       Upgrade a package, or all packages if omitted
        \\  remove <package>        Remove a package
        \\  list                    List installed packages
        \\  doctor                  Show available Windows package managers
        \\  version                 Show version
        \\
        \\BACKENDS:
        \\  --winget                Microsoft WinGet (default; apps + normal Windows software)
        \\  --scoop                 Scoop (brew-like developer tools, user-local)
        \\  --choco                 Chocolatey (mature automation ecosystem)
        \\
        \\EXAMPLES:
        \\  nb search git
        \\  nb install Git.Git
        \\  nb upgrade
        \\  nb install --scoop git
        \\  nb upgrade --choco
        \\
    , .{VERSION});
}
