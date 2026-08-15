// nanobrew — Service management dispatcher
//
// macOS: launchd (plist files)
// Linux: systemd (.service files)

const builtin = @import("builtin");

const impl = if (builtin.os.tag == .linux)
    @import("systemd.zig")
else
    @import("launchd.zig");

pub const Service = impl.Service;
pub const discoverServices = impl.discoverServices;
pub const isRunning = impl.isRunning;
pub const start = impl.start;
pub const stop = impl.stop;

const std = @import("std");

/// Free a single Service's owned string fields. Caller still owns the
/// memory for the Service value itself (e.g. on the stack or in a
/// slice).
pub fn freeService(alloc: std.mem.Allocator, svc: Service) void {
    alloc.free(svc.name);
    alloc.free(svc.label);
    alloc.free(svc.plist_path);
    alloc.free(svc.keg_name);
    alloc.free(svc.keg_version);
}

/// Free a slice returned by `discoverServices`: each Service's owned
/// strings, then the slice itself.
pub fn freeServiceList(alloc: std.mem.Allocator, list: []Service) void {
    for (list) |svc| freeService(alloc, svc);
    alloc.free(list);
}
