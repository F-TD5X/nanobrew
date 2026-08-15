// nanobrew — build-driven single-module test harness
//
// Per-module `zig build test-*` steps compile this file from the `src/` module
// root, then select the requested source file below. Keeping the root at `src/`
// lets target files keep sibling imports such as `../platform/paths.zig` under
// Zig 0.16's module-boundary checks.

const std = @import("std");
const options = @import("module_test_options");

comptime {
    const step = options.step_name;
    if (std.mem.eql(u8, step, "test-api")) {
        _ = @import("api/client.zig");
    } else if (std.mem.eql(u8, step, "test-tap")) {
        _ = @import("api/tap.zig");
    } else if (std.mem.eql(u8, step, "test-cask")) {
        _ = @import("api/cask.zig");
    } else if (std.mem.eql(u8, step, "test-deb-index")) {
        _ = @import("deb/index.zig");
    } else if (std.mem.eql(u8, step, "test-deb-resolver")) {
        _ = @import("deb/resolver.zig");
    } else if (std.mem.eql(u8, step, "test-deb-extract")) {
        _ = @import("deb/extract.zig");
    } else if (std.mem.eql(u8, step, "test-deb-distro")) {
        _ = @import("deb/distro.zig");
    } else if (std.mem.eql(u8, step, "test-deb-sources")) {
        _ = @import("deb/sources.zig");
    } else if (std.mem.eql(u8, step, "test-version")) {
        _ = @import("version.zig");
    } else if (std.mem.eql(u8, step, "test-upstream-registry")) {
        _ = @import("upstream/registry.zig");
    } else if (std.mem.eql(u8, step, "test-tar")) {
        _ = @import("extract/tar.zig");
    } else if (std.mem.eql(u8, step, "test-security")) {
        _ = @import("security_test.zig");
    } else if (std.mem.eql(u8, step, "test-search")) {
        _ = @import("api/search.zig");
    } else if (std.mem.eql(u8, step, "test-upstream-github")) {
        _ = @import("upstream_github_test.zig");
    } else if (std.mem.eql(u8, step, "test-macho")) {
        _ = @import("macho/relocate.zig");
    } else {
        @compileError("unknown per-module test step: " ++ step);
    }
}
