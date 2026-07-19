// nanobrew — Cask metadata struct
//
// Represents a Homebrew cask (macOS .app/.dmg/.pkg bundle).
// Parsed from https://formulae.brew.sh/api/cask/<token>.json

const std = @import("std");

pub const DownloadFormat = enum {
    dmg,
    zip,
    pkg,
    tar_gz,
    tar_xz,
    shell_script,
    binary,
    unknown,
};

pub const MetadataSource = enum {
    homebrew,
    verified_upstream,
};

pub const Artifact = union(enum) {
    app: []const u8, // e.g. "Firefox.app"
    binary: struct { source: []const u8, target: []const u8 },
    pkg: []const u8, // pkg filename
    font: []const u8,
    artifact: struct { source: []const u8, target: []const u8 },
    suite: struct { source: []const u8, target: []const u8 },
    installer_script: struct { executable: []const u8, args: []const []const u8 },
    uninstall: struct { quit: []const u8, pkgutil: []const u8 },
};

pub const SecurityWarning = struct {
    ghsa_id: []const u8,
    cve_id: []const u8,
    severity: []const u8,
    summary: []const u8,
    url: []const u8,
    affected_versions: []const u8,
    patched_versions: []const u8,

    pub fn deinit(self: SecurityWarning, alloc: std.mem.Allocator) void {
        alloc.free(self.ghsa_id);
        alloc.free(self.cve_id);
        alloc.free(self.severity);
        alloc.free(self.summary);
        alloc.free(self.url);
        alloc.free(self.affected_versions);
        alloc.free(self.patched_versions);
    }
};

/// A single key/value pair from a cask's `url ... data: { ... }` block.
pub const PostField = struct {
    key: []const u8,
    value: []const u8,
};

pub const Cask = struct {
    token: []const u8, // "firefox"
    name: []const u8, // "Mozilla Firefox"
    version: []const u8, // "147.0.3"
    url: []const u8, // direct download URL
    sha256: []const u8, // or "no_check" for auto-updating apps
    homepage: []const u8, // e.g. "https://www.mozilla.org/firefox/"
    desc: []const u8,
    auto_updates: bool,
    artifacts: []const Artifact,
    min_macos: ?[]const u8,
    metadata_source: MetadataSource = .homebrew,
    security_warnings: []const SecurityWarning = &.{},
    /// True when this metadata came from a revoked registry pin's fallback
    /// (previous known-good version). The registry is authoritative here:
    /// live-API freshness checks must not override a security revocation.
    revoked_fallback: bool = false,
    /// Download method from the cask's `url_specs.using` (e.g. "post"). null = GET.
    download_using: ?[]const u8 = null,
    /// Form fields from `url_specs.data`, sent as the POST body (#305).
    post_data: []const PostField = &.{},
    /// `url_specs.referer` — sent as the Referer header when present.
    referer: ?[]const u8 = null,
    /// `url_specs.user_agent` — resolved UA string (Homebrew's `:fake` symbol is
    /// mapped to a browser UA; `:default`/`:curl` leave this null to use the
    /// built-in UA). When set, overrides the default download User-Agent.
    user_agent: ?[]const u8 = null,
    /// `url_specs.cookies` — sent joined into a single Cookie header.
    cookies: []const PostField = &.{},
    /// `url_specs.header` — extra request headers, each "Name: Value".
    headers: []const []const u8 = &.{},

    /// True when this cask must be downloaded with an HTTP POST carrying
    /// `post_data` (e.g. segger-jlink's license acceptance form).
    pub fn isPostDownload(self: *const Cask) bool {
        return self.download_using != null and std.ascii.eqlIgnoreCase(self.download_using.?, "post");
    }

    pub fn downloadFormat(self: *const Cask) DownloadFormat {
        if (std.mem.endsWith(u8, self.url, ".dmg")) return .dmg;
        if (std.mem.endsWith(u8, self.url, ".zip")) return .zip;
        if (std.mem.endsWith(u8, self.url, ".pkg")) return .pkg;
        if (std.mem.endsWith(u8, self.url, ".tar.gz")) return .tar_gz;
        if (std.mem.endsWith(u8, self.url, ".tgz")) return .tar_gz;
        if (std.mem.endsWith(u8, self.url, ".tar.xz")) return .tar_xz;
        if (std.mem.endsWith(u8, self.url, ".sh")) return .shell_script;
        if (std.mem.indexOf(u8, self.url, "extension=zip") != null) return .zip;
        if (std.mem.indexOf(u8, self.url, "update.code.visualstudio.com/") != null) return .zip;
        if (std.mem.indexOf(u8, self.url, "download-chromium.appspot.com/") != null) return .zip;
        if (self.hasOnlyBinaryArtifacts()) return .binary;
        return .unknown;
    }

    fn hasOnlyBinaryArtifacts(self: *const Cask) bool {
        var binary_count: usize = 0;
        for (self.artifacts) |artifact| {
            switch (artifact) {
                .binary => binary_count += 1,
                .uninstall => {},
                .app, .pkg, .font, .artifact, .suite, .installer_script => return false,
            }
        }
        return binary_count == 1;
    }

    pub fn shouldVerifySha(self: *const Cask) bool {
        return !std.mem.eql(u8, self.sha256, "no_check");
    }

    pub fn caskroomPath(self: *const Cask, buf: []u8) []const u8 {
        const filesystem_token = if (std.mem.lastIndexOfScalar(u8, self.token, '/')) |idx|
            self.token[idx + 1 ..]
        else
            self.token;
        if (filesystem_token.len == 0 or
            std.mem.eql(u8, filesystem_token, ".") or
            std.mem.eql(u8, filesystem_token, "..")) return "";
        for (filesystem_token) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '@' and c != '+' and c != '_' and c != '.' and c != '-') return "";
        }
        return std.fmt.bufPrint(buf, @import("../platform/paths.zig").CASKROOM_DIR ++ "/{s}/{s}", .{ filesystem_token, self.version }) catch "";
    }

    pub fn deinit(self: Cask, alloc: std.mem.Allocator) void {
        alloc.free(self.token);
        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.url);
        alloc.free(self.sha256);
        alloc.free(self.homepage);
        alloc.free(self.desc);
        for (self.artifacts) |art| {
            switch (art) {
                .app => |a| alloc.free(a),
                .binary => |b| {
                    alloc.free(b.source);
                    alloc.free(b.target);
                },
                .pkg => |p| alloc.free(p),
                .font => |f| alloc.free(f),
                .artifact => |a| {
                    alloc.free(a.source);
                    alloc.free(a.target);
                },
                .suite => |s| {
                    alloc.free(s.source);
                    alloc.free(s.target);
                },
                .installer_script => |script| {
                    alloc.free(script.executable);
                    for (script.args) |arg| alloc.free(arg);
                    alloc.free(script.args);
                },
                .uninstall => |u| {
                    alloc.free(u.quit);
                    alloc.free(u.pkgutil);
                },
            }
        }
        alloc.free(self.artifacts);
        if (self.min_macos) |m| alloc.free(m);
        for (self.security_warnings) |warning| warning.deinit(alloc);
        if (self.security_warnings.len > 0) alloc.free(self.security_warnings);
        if (self.download_using) |u| alloc.free(u);
        for (self.post_data) |field| {
            alloc.free(field.key);
            alloc.free(field.value);
        }
        if (self.post_data.len > 0) alloc.free(self.post_data);
        if (self.referer) |r| alloc.free(r);
        if (self.user_agent) |u| alloc.free(u);
        for (self.cookies) |c| {
            alloc.free(c.key);
            alloc.free(c.value);
        }
        if (self.cookies.len > 0) alloc.free(self.cookies);
        for (self.headers) |h| alloc.free(h);
        if (self.headers.len > 0) alloc.free(self.headers);
    }
};

const testing = std.testing;

test "downloadFormat - detects dmg" {
    const c = Cask{
        .token = "firefox",
        .name = "Mozilla Firefox",
        .version = "147.0.3",
        .url = "https://example.com/Firefox.dmg",
        .sha256 = "abc123",
        .homepage = "",
        .desc = "Browser",
        .auto_updates = true,
        .artifacts = &.{},
        .min_macos = null,
    };
    try testing.expectEqual(DownloadFormat.dmg, c.downloadFormat());
}

test "downloadFormat - detects zip" {
    const c = Cask{
        .token = "vscode",
        .name = "Visual Studio Code",
        .version = "1.90",
        .url = "https://example.com/VSCode.zip",
        .sha256 = "abc123",
        .homepage = "",
        .desc = "Editor",
        .auto_updates = true,
        .artifacts = &.{},
        .min_macos = null,
    };
    try testing.expectEqual(DownloadFormat.zip, c.downloadFormat());
}

test "downloadFormat - detects pkg" {
    const c = Cask{
        .token = "docker",
        .name = "Docker",
        .version = "4.30",
        .url = "https://example.com/Docker.pkg",
        .sha256 = "abc123",
        .homepage = "",
        .desc = "Container runtime",
        .auto_updates = false,
        .artifacts = &.{},
        .min_macos = null,
    };
    try testing.expectEqual(DownloadFormat.pkg, c.downloadFormat());
}

test "downloadFormat - detects direct binary-only cask" {
    const c = Cask{
        .token = "claude-code",
        .name = "Claude Code",
        .version = "2.1.109",
        .url = "https://example.com/releases/darwin-arm64/claude",
        .sha256 = "abc123",
        .homepage = "",
        .desc = "CLI",
        .auto_updates = false,
        .artifacts = &.{
            .{ .binary = .{ .source = "claude", .target = "claude" } },
        },
        .min_macos = null,
    };
    try testing.expectEqual(DownloadFormat.binary, c.downloadFormat());
}

test "downloadFormat - leaves extensionless multi-binary archives unknown" {
    const c = Cask{
        .token = "multi",
        .name = "Multi",
        .version = "1.0",
        .url = "https://example.com/download",
        .sha256 = "abc123",
        .homepage = "",
        .desc = "CLI",
        .auto_updates = false,
        .artifacts = &.{
            .{ .binary = .{ .source = "bin/a", .target = "a" } },
            .{ .binary = .{ .source = "bin/b", .target = "b" } },
        },
        .min_macos = null,
    };
    try testing.expectEqual(DownloadFormat.unknown, c.downloadFormat());
}

test "shouldVerifySha - returns true for normal sha" {
    const c = Cask{
        .token = "test",
        .name = "Test",
        .version = "1.0",
        .url = "https://example.com/test.dmg",
        .sha256 = "deadbeef",
        .homepage = "",
        .desc = "",
        .auto_updates = false,
        .artifacts = &.{},
        .min_macos = null,
    };
    try testing.expect(c.shouldVerifySha());
}

test "shouldVerifySha - returns false for no_check" {
    const c = Cask{
        .token = "test",
        .name = "Test",
        .version = "1.0",
        .url = "https://example.com/test.dmg",
        .sha256 = "no_check",
        .homepage = "",
        .desc = "",
        .auto_updates = true,
        .artifacts = &.{},
        .min_macos = null,
    };
    try testing.expect(!c.shouldVerifySha());
}

test "caskroomPath - formats token and version" {
    const c = Cask{
        .token = "firefox",
        .name = "Firefox",
        .version = "147.0.3",
        .url = "",
        .sha256 = "",
        .homepage = "",
        .desc = "",
        .auto_updates = false,
        .artifacts = &.{},
        .min_macos = null,
    };
    var buf: [512]u8 = undefined;
    const p = c.caskroomPath(&buf);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Caskroom/firefox/147.0.3", p);
}

test "caskroomPath uses basename for third-party tap tokens" {
    const c = Cask{
        .token = "indaco/tap/sley",
        .name = "Sley",
        .version = "1.2.3",
        .url = "",
        .sha256 = "",
        .homepage = "",
        .desc = "",
        .auto_updates = false,
        .artifacts = &.{},
        .min_macos = null,
    };
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Caskroom/sley/1.2.3", c.caskroomPath(&buf));
}
