const std = @import("std");
const builtin = @import("builtin");

const probe_args = [_][]const u8{ "--version", "version", "--help" };

/// Per-executable outcome of an active probe (#317).
pub const Outcome = enum {
    /// The binary ran and exited with an accepted status.
    answered,
    /// The binary ran but never produced an accepted exit within its slice.
    unresponsive,
    /// The package-wide budget was already spent before this binary got a
    /// slice — no evidence either way; callers must skip, not fail.
    budget_exhausted,
};

/// Restricted login shells (git-shell and friends) ignore argv probes and
/// wait for their command loop; probing them wastes a slice and produces no
/// install-health signal (#317 field note).
pub fn isInteractiveShellLike(basename: []const u8) bool {
    if (std.mem.eql(u8, basename, "git-shell")) return true;
    if (std.mem.endsWith(u8, basename, "-sh")) return true;
    return false;
}

/// Package-wide probe budget with a per-executable slice. The slice keeps one
/// interactive tool (perl's cpan, instmodsh) from starving every later binary
/// of the package, while the package cap still prevents an N-binary keg from
/// turning the policy into N × slice (#317).
pub const Session = struct {
    io: std.Io,
    started: std.Io.Clock.Timestamp,
    package_budget: std.Io.Clock.Duration,
    per_binary_budget: std.Io.Clock.Duration,
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd_len: usize = 0,

    pub fn init(
        io: std.Io,
        package_budget: std.Io.Clock.Duration,
        per_binary_budget: std.Io.Clock.Duration,
    ) !Session {
        var session: Session = .{
            .io = io,
            .started = std.Io.Clock.Timestamp.now(io, .awake),
            .package_budget = package_budget,
            .per_binary_budget = per_binary_budget,
        };

        // Version/help commands are third-party code and can have surprising
        // side effects. Never inherit the caller's working directory.
        const env_name = if (builtin.os.tag == .windows) "TEMP" else "TMPDIR";
        const temp_root: []const u8 = if (std.c.getenv(env_name)) |raw|
            std.mem.sliceTo(raw, 0)
        else if (builtin.os.tag == .windows)
            return error.MissingTempDirectory
        else
            "/tmp";
        if (!std.fs.path.isAbsolute(temp_root)) return error.InvalidTempDirectory;
        const probe_cwd = try std.fmt.bufPrint(&session.cwd_buf, "{s}{c}nanobrew-probe-{d}-{d}", .{
            temp_root, std.fs.path.sep, std.c.getpid(), std.Thread.getCurrentId(),
        });
        session.cwd_len = probe_cwd.len;
        std.Io.Dir.cwd().deleteTree(io, probe_cwd) catch {};
        try std.Io.Dir.createDirAbsolute(io, probe_cwd, .default_dir);
        return session;
    }

    pub fn deinit(self: *Session) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.cwd_buf[0..self.cwd_len]) catch {};
    }

    /// Milliseconds left in the package-wide budget (may be negative).
    fn remainingMs(self: *const Session) i64 {
        const now_ts = std.Io.Clock.Timestamp.now(self.io, .awake);
        const elapsed: i64 = @intCast(self.started.durationTo(now_ts).raw.toMilliseconds());
        const total: i64 = @intCast(self.package_budget.raw.toMilliseconds());
        return total - elapsed;
    }

    /// Absolute deadline for the next check: the per-binary slice, clamped to
    /// whatever remains of the package budget.
    pub fn timeout(self: *const Session) std.Io.Timeout {
        const remaining = @max(self.remainingMs(), 1);
        const per_binary: i64 = @intCast(self.per_binary_budget.raw.toMilliseconds());
        const slice_ms = @min(per_binary, remaining);
        const slice: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(slice_ms)),
            .clock = .awake,
        } };
        return slice.toDeadline(self.io);
    }

    pub fn cwd(self: *const Session) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    pub fn probe(self: *Session, alloc: std.mem.Allocator, path: []const u8) Outcome {
        if (self.remainingMs() <= 0) return .budget_exhausted;
        const deadline = self.timeout();
        const probe_cwd = self.cwd_buf[0..self.cwd_len];
        for (probe_args) |arg| {
            const result = std.process.run(alloc, self.io, .{
                .argv = &.{ path, arg },
                .cwd = .{ .path = probe_cwd },
                .stdout_limit = .limited(64 * 1024),
                .stderr_limit = .limited(64 * 1024),
                .timeout = deadline,
            }) catch continue;
            defer alloc.free(result.stdout);
            defer alloc.free(result.stderr);

            switch (result.term) {
                .exited => |code| if (code == 0 or code == 1 or code == 2) return .answered,
                else => {},
            }
        }
        return .unresponsive;
    }

    pub fn executableAnswers(self: *Session, alloc: std.mem.Allocator, path: []const u8) bool {
        return self.probe(alloc, path) == .answered;
    }
};

pub fn executableAnswers(alloc: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    return executableAnswersWithin(alloc, io, path, .{
        .raw = std.Io.Duration.fromSeconds(2),
        .clock = .awake,
    });
}

fn executableAnswersWithin(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    budget: std.Io.Clock.Duration,
) bool {
    var session = Session.init(io, budget, budget) catch return false;
    defer session.deinit();
    return session.executableAnswers(alloc, path);
}

test "executableAnswers accepts a responsive executable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(executableAnswers(std.testing.allocator, std.testing.io, "/usr/bin/false"));
}

test "probe side effects stay out of the caller working directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const marker = ".nanobrew-probe-isolation-test";
    std.Io.Dir.cwd().deleteFile(std.testing.io, marker) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, marker) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        \\#!/bin/sh
        \\: > .nanobrew-probe-isolation-test
        \\exit 0
        \\
    ;
    var file = try tmp.dir.createFile(std.testing.io, "side-effect", .{});
    try file.writeStreamingAll(std.testing.io, script);
    try file.setPermissions(std.testing.io, .executable_file);
    file.close(std.testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "side-effect", &path_buf);
    try std.testing.expect(executableAnswers(std.testing.allocator, std.testing.io, path_buf[0..path_len]));
    const escaped = if (std.Io.Dir.cwd().access(std.testing.io, marker, .{})) |_| true else |_| false;
    try std.testing.expect(!escaped);
}

test "probe attempts share one absolute timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\#!/bin/sh
        \\i=0
        \\while [ "$i" -lt 40 ]; do
        \\  printf x
        \\  sleep 0.05
        \\  i=$((i + 1))
        \\done
        \\exit 3
        \\
    ;
    var file = try tmp.dir.createFile(std.testing.io, "slow-output", .{});
    try file.writeStreamingAll(std.testing.io, script);
    try file.setPermissions(std.testing.io, .executable_file);
    file.close(std.testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "slow-output", &path_buf);
    const path = path_buf[0..path_len];
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const passed = executableAnswersWithin(std.testing.allocator, std.testing.io, path, .{
        .raw = std.Io.Duration.fromMilliseconds(500),
        .clock = .awake,
    });
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake));

    try std.testing.expect(!passed);
    // A relative timeout restarts for each output read and takes ~2s per
    // attempt. One deadline returns near 500ms, with generous CI headroom.
    try std.testing.expect(elapsed.raw.toMilliseconds() < 1500);
}

test "isInteractiveShellLike flags restricted shells only (#317)" {
    try std.testing.expect(isInteractiveShellLike("git-shell"));
    try std.testing.expect(isInteractiveShellLike("rksh-sh"));
    try std.testing.expect(!isInteractiveShellLike("git"));
    try std.testing.expect(!isInteractiveShellLike("perl"));
    try std.testing.expect(!isInteractiveShellLike("bash"));
}

test "per-binary slice keeps one hung binary from starving the package (#317)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\#!/bin/sh
        \\i=0
        \\while [ "$i" -lt 40 ]; do
        \\  sleep 0.05
        \\  i=$((i + 1))
        \\done
        \\exit 3
        \\
    ;
    var file = try tmp.dir.createFile(std.testing.io, "hang", .{});
    try file.writeStreamingAll(std.testing.io, script);
    try file.setPermissions(std.testing.io, .executable_file);
    file.close(std.testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "hang", &path_buf);
    const path = path_buf[0..path_len];

    var session = try Session.init(std.testing.io, .{
        .raw = std.Io.Duration.fromMilliseconds(400),
        .clock = .awake,
    }, .{
        .raw = std.Io.Duration.fromMilliseconds(100),
        .clock = .awake,
    });
    defer session.deinit();

    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var unresponsive: usize = 0;
    var exhausted: usize = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        switch (session.probe(std.testing.allocator, path)) {
            .answered => return error.TestUnexpectedResult,
            .unresponsive => unresponsive += 1,
            .budget_exhausted => exhausted += 1,
        }
    }
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake));

    // Each hung binary loses only its own slice; once the package budget is
    // spent, later binaries are skipped without failing. Eight probes of a
    // hung binary under the old one-shared-deadline design would either take
    // one slice total (starvation) or 8 × the slice; with slices + cap we see
    // both unresponsive and exhausted outcomes, quickly.
    try std.testing.expect(unresponsive >= 1);
    try std.testing.expect(exhausted >= 1);
    try std.testing.expect(unresponsive + exhausted == 8);
    try std.testing.expect(elapsed.raw.toMilliseconds() < 3000);
}
