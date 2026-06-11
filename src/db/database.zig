// nanobrew — Installation state database
//
// Lightweight file-based database (JSON for v0).
// Tracks installed kegs, store references, and linked files.
// File: /opt/nanobrew/db/state.json

const std = @import("std");
const paths = @import("../platform/paths.zig");

const DB_PATH = paths.DB_PATH;

pub const Keg = struct {
    name: []const u8,
    version: []const u8,
    sha256: []const u8 = "",
    pinned: bool = false,
    installed_at: i64 = 0,
};

pub const CaskRecord = struct {
    token: []const u8,
    version: []const u8,
    apps: []const []const u8,
    binaries: []const []const u8,
};

pub const HistoryEntry = struct {
    version: []const u8,
    sha256: []const u8,
    installed_at: i64,
};

pub const DebRecord = struct {
    name: []const u8,
    version: []const u8,
    files: []const []const u8,
    sha256: []const u8 = "",
    installed_at: i64 = 0,
};

pub const Database = struct {
    alloc: std.mem.Allocator,
    kegs: std.ArrayList(Keg),
    casks: std.ArrayList(CaskRecord),
    debs: std.ArrayList(DebRecord),
    history: std.StringHashMap(std.ArrayList(HistoryEntry)),
    dirty: bool = false,

    pub const MAX_DB_SIZE: usize = 16 * 1024 * 1024;

    pub fn open(alloc: std.mem.Allocator) !Database {
        var db = Database{
            .alloc = alloc,
            .kegs = .empty,
            .casks = .empty,
            .debs = .empty,
            .history = std.StringHashMap(std.ArrayList(HistoryEntry)).init(alloc),
        };

        const lib_io = paths.safe_io;
        const file = std.Io.Dir.openFileAbsolute(lib_io, DB_PATH, .{}) catch return db;
        defer file.close(lib_io);

        const max_state_bytes = MAX_DB_SIZE;
        const st = file.stat(lib_io) catch return db;
        const sz = @min(st.size, max_state_bytes);
        const contents = alloc.alloc(u8, sz) catch return db;
        const n_read = file.readPositionalAll(lib_io, contents, 0) catch {
            alloc.free(contents);
            std.Io.File.stderr().writeStreamingAll(paths.safe_io, "warning: nanobrew database read failed: " ++ DB_PATH ++ "\n") catch {};
            return db;
        };
        defer alloc.free(contents);
        const data = contents[0..n_read];
        if (data.len == 0) return db;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch {
            std.Io.File.stderr().writeStreamingAll(paths.safe_io, "warning: nanobrew database parse failed; returning empty database. File may be corrupted: " ++ DB_PATH ++ "\n") catch {};
            return db;
        };
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("kegs")) |kegs_val| {
                if (kegs_val == .array) {
                    for (kegs_val.array.items) |item| {
                        if (item == .object) {
                            const kname = getStr(item.object, "name") orelse continue;
                            const kver = getStr(item.object, "version") orelse continue;
                            const ksha = getStr(item.object, "sha256") orelse "";
                            const kpinned = getBool(item.object, "pinned");
                            const kinst = getInt(item.object, "installed_at");
                            // All-or-nothing: free any prior dupes if a
                            // later alloc or append fails so we never
                            // leak a partial Keg on OOM.
                            const k_name = alloc.dupe(u8, kname) catch continue;
                            const k_ver = alloc.dupe(u8, kver) catch {
                                alloc.free(k_name);
                                continue;
                            };
                            const k_sha = alloc.dupe(u8, ksha) catch {
                                alloc.free(k_name);
                                alloc.free(k_ver);
                                continue;
                            };
                            db.kegs.append(alloc, .{
                                .name = k_name,
                                .version = k_ver,
                                .sha256 = k_sha,
                                .pinned = kpinned,
                                .installed_at = kinst,
                            }) catch {
                                alloc.free(k_name);
                                alloc.free(k_ver);
                                alloc.free(k_sha);
                            };
                        }
                    }
                }
            }
            if (parsed.value.object.get("casks")) |casks_val| {
                if (casks_val == .array) {
                    for (casks_val.array.items) |item| {
                        if (item != .object) continue;
                        const ctoken = getStr(item.object, "token") orelse continue;
                        const cver = getStr(item.object, "version") orelse continue;

                        var capps: std.ArrayList([]const u8) = .empty;
                        if (item.object.get("apps")) |apps_val| {
                            if (apps_val == .array) {
                                for (apps_val.array.items) |a| {
                                    if (a == .string) {
                                        capps.append(alloc, alloc.dupe(u8, a.string) catch continue) catch {};
                                    }
                                }
                            }
                        }

                        var cbins: std.ArrayList([]const u8) = .empty;
                        if (item.object.get("binaries")) |bins_val| {
                            if (bins_val == .array) {
                                for (bins_val.array.items) |b| {
                                    if (b == .string) {
                                        cbins.append(alloc, alloc.dupe(u8, b.string) catch continue) catch {};
                                    }
                                }
                            }
                        }

                        const c_token = alloc.dupe(u8, ctoken) catch continue;
                        const c_ver = alloc.dupe(u8, cver) catch {
                            alloc.free(c_token);
                            continue;
                        };
                        const c_apps = capps.toOwnedSlice(alloc) catch {
                            alloc.free(c_token);
                            alloc.free(c_ver);
                            continue;
                        };
                        const c_bins = cbins.toOwnedSlice(alloc) catch {
                            alloc.free(c_token);
                            alloc.free(c_ver);
                            for (c_apps) |s| alloc.free(s);
                            alloc.free(c_apps);
                            continue;
                        };
                        db.casks.append(alloc, .{
                            .token = c_token,
                            .version = c_ver,
                            .apps = c_apps,
                            .binaries = c_bins,
                        }) catch {
                            alloc.free(c_token);
                            alloc.free(c_ver);
                            for (c_apps) |s| alloc.free(s);
                            alloc.free(c_apps);
                            for (c_bins) |s| alloc.free(s);
                            alloc.free(c_bins);
                        };
                    }
                }
            }
            if (parsed.value.object.get("history")) |hist_val| {
                if (hist_val == .object) {
                    var hist_iter = hist_val.object.iterator();
                    while (hist_iter.next()) |entry| {
                        const pkg_name = alloc.dupe(u8, entry.key_ptr.*) catch continue;
                        var entries: std.ArrayList(HistoryEntry) = .empty;
                        if (entry.value_ptr.* == .array) {
                            for (entry.value_ptr.array.items) |h_item| {
                                if (h_item != .object) continue;
                                const hver = getStr(h_item.object, "version") orelse continue;
                                const hsha = getStr(h_item.object, "sha256") orelse "";
                                const hinst = getInt(h_item.object, "installed_at");
                                const h_ver_s = alloc.dupe(u8, hver) catch continue;
                                const h_sha_s = alloc.dupe(u8, hsha) catch {
                                    alloc.free(h_ver_s);
                                    continue;
                                };
                                entries.append(alloc, .{
                                    .version = h_ver_s,
                                    .sha256 = h_sha_s,
                                    .installed_at = hinst,
                                }) catch {
                                    alloc.free(h_ver_s);
                                    alloc.free(h_sha_s);
                                };
                            }
                        }
                        db.history.put(pkg_name, entries) catch {};
                    }
                }
            }
            if (parsed.value.object.get("deb_packages")) |debs_val| {
                if (debs_val == .array) {
                    for (debs_val.array.items) |item| {
                        if (item != .object) continue;
                        const dname = getStr(item.object, "name") orelse continue;
                        const dver = getStr(item.object, "version") orelse continue;
                        const dsha = getStr(item.object, "sha256") orelse "";
                        const dinst = getInt(item.object, "installed_at");

                        var dfiles: std.ArrayList([]const u8) = .empty;
                        if (item.object.get("files")) |files_val| {
                            if (files_val == .array) {
                                for (files_val.array.items) |f| {
                                    if (f == .string) {
                                        dfiles.append(alloc, alloc.dupe(u8, f.string) catch continue) catch {};
                                    }
                                }
                            }
                        }

                        const d_name = alloc.dupe(u8, dname) catch continue;
                        const d_ver = alloc.dupe(u8, dver) catch {
                            alloc.free(d_name);
                            continue;
                        };
                        const d_files = dfiles.toOwnedSlice(alloc) catch {
                            alloc.free(d_name);
                            alloc.free(d_ver);
                            continue;
                        };
                        const d_sha = alloc.dupe(u8, dsha) catch {
                            alloc.free(d_name);
                            alloc.free(d_ver);
                            for (d_files) |s| alloc.free(s);
                            alloc.free(d_files);
                            continue;
                        };
                        db.debs.append(alloc, .{
                            .name = d_name,
                            .version = d_ver,
                            .files = d_files,
                            .sha256 = d_sha,
                            .installed_at = dinst,
                        }) catch {
                            alloc.free(d_name);
                            alloc.free(d_ver);
                            for (d_files) |s| alloc.free(s);
                            alloc.free(d_files);
                            alloc.free(d_sha);
                        };
                    }
                }
            }
        }

        return db;
    }

    pub fn close(self: *Database) void {
        self.save() catch |err| {
            var _warn_buf: [256]u8 = undefined; const _warn_msg = std.fmt.bufPrint(&_warn_buf, "nb: WARNING: failed to save package database: {}\n", .{err}) catch "nb: WARNING: failed to save package database\n"; std.Io.File.stderr().writeStreamingAll(paths.safe_io, _warn_msg) catch {};
        };
        for (self.kegs.items) |keg| {
            self.alloc.free(keg.name);
            self.alloc.free(keg.version);
            self.alloc.free(keg.sha256);
        }
        self.kegs.deinit(self.alloc);
        for (self.casks.items) |c| {
            self.alloc.free(c.token);
            self.alloc.free(c.version);
            for (c.apps) |a| self.alloc.free(a);
            self.alloc.free(c.apps);
            for (c.binaries) |b| self.alloc.free(b);
            self.alloc.free(c.binaries);
        }
        self.casks.deinit(self.alloc);
        for (self.debs.items) |d| {
            self.alloc.free(d.name);
            self.alloc.free(d.version);
            self.alloc.free(d.sha256);
            for (d.files) |f| self.alloc.free(f);
            self.alloc.free(d.files);
        }
        self.debs.deinit(self.alloc);
        var hist_it = self.history.iterator();
        while (hist_it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |h| {
                self.alloc.free(h.version);
                self.alloc.free(h.sha256);
            }
            entry.value_ptr.deinit(self.alloc);
        }
        self.history.deinit();
    }

    pub fn recordInstall(self: *Database, name: []const u8, version: []const u8, sha256: []const u8) !void {
        const _lib_io_ri = paths.safe_io;
        const _now_ts = std.Io.Timestamp.now(_lib_io_ri, .real);
        const now: i64 = @as(i64, @truncate(@divTrunc(_now_ts.nanoseconds, std.time.ns_per_s)));

        var i: usize = 0;
        while (i < self.kegs.items.len) {
            if (std.mem.eql(u8, self.kegs.items[i].name, name)) {
                const old = self.kegs.items[i];
                self.pushHistory(name, old) catch {};
                self.alloc.free(old.name);
                self.alloc.free(old.version);
                self.alloc.free(old.sha256);
                _ = self.kegs.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        try self.kegs.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .version = try self.alloc.dupe(u8, version),
            .sha256 = try self.alloc.dupe(u8, sha256),
            .pinned = false,
            .installed_at = now,
        });
        self.dirty = true;
    }

    fn pushHistory(self: *Database, name: []const u8, old: Keg) !void {
        const gop = try self.history.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.alloc.dupe(u8, name);
            gop.value_ptr.* = .empty;
        }
        // All-or-nothing: if append fails we must free both dupes, and
        // if the second dupe fails we must free the first. `catch ""`
        // on a leaked dupe would silently leak on OOM.
        const ver_owned = try self.alloc.dupe(u8, old.version);
        errdefer self.alloc.free(ver_owned);
        const sha_owned = try self.alloc.dupe(u8, old.sha256);
        errdefer self.alloc.free(sha_owned);
        try gop.value_ptr.append(self.alloc, .{
            .version = ver_owned,
            .sha256 = sha_owned,
            .installed_at = old.installed_at,
        });
    }

    pub fn recordRemoval(self: *Database, name: []const u8, alloc: std.mem.Allocator) !void {
        _ = alloc;
        var i: usize = 0;
        while (i < self.kegs.items.len) {
            if (std.mem.eql(u8, self.kegs.items[i].name, name)) {
                const keg = self.kegs.items[i];
                self.alloc.free(keg.name);
                self.alloc.free(keg.version);
                self.alloc.free(keg.sha256);
                _ = self.kegs.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        self.dirty = true;
    }

    pub fn findKeg(self: *Database, name: []const u8) ?Keg {
        for (self.kegs.items) |keg| {
            if (std.mem.eql(u8, keg.name, name)) return keg;
        }
        return null;
    }

    pub fn listInstalled(self: *Database, alloc: std.mem.Allocator) ![]Keg {
        const result = try alloc.alloc(Keg, self.kegs.items.len);
        @memcpy(result, self.kegs.items);
        return result;
    }

    pub fn recordCaskInstall(self: *Database, token: []const u8, version: []const u8, apps: []const []const u8, binaries: []const []const u8) !void {
        var i: usize = 0;
        while (i < self.casks.items.len) {
            if (std.mem.eql(u8, self.casks.items[i].token, token)) {
                const old_cask = self.casks.items[i];
                self.alloc.free(old_cask.token);
                self.alloc.free(old_cask.version);
                for (old_cask.apps) |a| self.alloc.free(a);
                self.alloc.free(old_cask.apps);
                for (old_cask.binaries) |b| self.alloc.free(b);
                self.alloc.free(old_cask.binaries);
                _ = self.casks.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        const dapps = try self.alloc.alloc([]const u8, apps.len);
        for (apps, 0..) |a, idx| dapps[idx] = try self.alloc.dupe(u8, a);
        const dbins = try self.alloc.alloc([]const u8, binaries.len);
        for (binaries, 0..) |b, idx| dbins[idx] = try self.alloc.dupe(u8, b);

        try self.casks.append(self.alloc, .{
            .token = try self.alloc.dupe(u8, token),
            .version = try self.alloc.dupe(u8, version),
            .apps = dapps,
            .binaries = dbins,
        });
        self.dirty = true;
    }

    /// Persist the database to disk now if there are unsaved changes, without
    /// closing it. close() still flushes implicitly; this lets a long-running
    /// multi-item install checkpoint progress so an interrupted run does not
    /// lose records for items that already completed (issue #302).
    pub fn flush(self: *Database) !void {
        return self.save();
    }

    pub fn recordCaskRemoval(self: *Database, token: []const u8, alloc: std.mem.Allocator) !void {
        _ = alloc;
        var i: usize = 0;
        while (i < self.casks.items.len) {
            if (std.mem.eql(u8, self.casks.items[i].token, token)) {
                const old_cask = self.casks.items[i];
                self.alloc.free(old_cask.token);
                self.alloc.free(old_cask.version);
                for (old_cask.apps) |a| self.alloc.free(a);
                self.alloc.free(old_cask.apps);
                for (old_cask.binaries) |b| self.alloc.free(b);
                self.alloc.free(old_cask.binaries);
                _ = self.casks.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        self.dirty = true;
    }

    pub fn findCask(self: *Database, token: []const u8) ?CaskRecord {
        for (self.casks.items) |c| {
            if (std.mem.eql(u8, c.token, token)) return c;
        }
        return null;
    }

    pub fn listInstalledCasks(self: *Database, alloc: std.mem.Allocator) ![]CaskRecord {
        const result = try alloc.alloc(CaskRecord, self.casks.items.len);
        @memcpy(result, self.casks.items);
        return result;
    }

    pub fn setPinned(self: *Database, name: []const u8, pinned: bool) !void {
        for (self.kegs.items) |*keg| {
            if (std.mem.eql(u8, keg.name, name)) {
                keg.pinned = pinned;
                self.dirty = true;
                return;
            }
        }
        return error.NotFound;
    }

    pub fn getHistory(self: *Database, name: []const u8) []const HistoryEntry {
        if (self.history.get(name)) |list| {
            return list.items;
        }
        return &.{};
    }

    pub fn recordDebInstall(self: *Database, name: []const u8, version: []const u8, sha256: []const u8, files: []const []const u8) !void {
        var ts_now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts_now);
        const now: i64 = ts_now.sec;

        var i: usize = 0;
        while (i < self.debs.items.len) {
            if (std.mem.eql(u8, self.debs.items[i].name, name)) {
                const old_deb = self.debs.items[i];
                self.alloc.free(old_deb.name);
                self.alloc.free(old_deb.version);
                self.alloc.free(old_deb.sha256);
                for (old_deb.files) |f| self.alloc.free(f);
                self.alloc.free(old_deb.files);
                _ = self.debs.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        const dfiles = try self.alloc.alloc([]const u8, files.len);
        for (files, 0..) |f, idx| dfiles[idx] = try self.alloc.dupe(u8, f);

        try self.debs.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .version = try self.alloc.dupe(u8, version),
            .files = dfiles,
            .sha256 = try self.alloc.dupe(u8, sha256),
            .installed_at = now,
        });
        self.dirty = true;
    }

    pub fn recordDebRemoval(self: *Database, name: []const u8) !void {
        var i: usize = 0;
        while (i < self.debs.items.len) {
            if (std.mem.eql(u8, self.debs.items[i].name, name)) {
                const old_deb = self.debs.items[i];
                self.alloc.free(old_deb.name);
                self.alloc.free(old_deb.version);
                self.alloc.free(old_deb.sha256);
                for (old_deb.files) |f| self.alloc.free(f);
                self.alloc.free(old_deb.files);
                _ = self.debs.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        self.dirty = true;
    }

    pub fn findDeb(self: *Database, name: []const u8) ?DebRecord {
        for (self.debs.items) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    pub fn listInstalledDebs(self: *Database, alloc: std.mem.Allocator) ![]DebRecord {
        const result = try alloc.alloc(DebRecord, self.debs.items.len);
        @memcpy(result, self.debs.items);
        return result;
    }

    pub fn writeJsonEscaped(writer: anytype, s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '"' => writer.writeAll("\\\"") catch {},
                '\\' => writer.writeAll("\\\\") catch {},
                '\n' => writer.writeAll("\\n") catch {},
                '\r' => writer.writeAll("\\r") catch {},
                '\t' => writer.writeAll("\\t") catch {},
                else => {
                    if (c < 0x20) {
                        const hex = "0123456789abcdef";
                        writer.writeAll("\\u00") catch {};
                        writer.writeAll(&.{ hex[c >> 4], hex[c & 0x0f] }) catch {};
                    } else {
                        writer.writeAll(&.{c}) catch {};
                    }
                },
            }
        }
    }

    pub fn writeJsonString(writer: anytype, s: []const u8) void {
        writer.writeAll("\"") catch {};
        writeJsonEscaped(writer, s);
        writer.writeAll("\"") catch {};
    }

    fn save(self: *Database) !void {
        if (!self.dirty) return;
        const tmp_path = DB_PATH ++ ".tmp";
        const lib_io = paths.safe_io;
        const file = try std.Io.Dir.createFileAbsolute(lib_io, tmp_path, .{});
        errdefer std.Io.Dir.deleteFileAbsolute(lib_io, tmp_path) catch {};

        var write_buf: [65536]u8 = undefined;
        var writer = file.writer(lib_io, &write_buf);
        var write_ok = true;
        writer.interface.writeAll("{\"kegs\":[") catch { write_ok = false; };
        for (self.kegs.items, 0..) |keg, i| {
            if (i > 0) writer.interface.writeAll(",") catch {};
            writer.interface.writeAll("{\"name\":") catch {};
            writeJsonString(&writer.interface, keg.name);
            writer.interface.writeAll(",\"version\":") catch {};
            writeJsonString(&writer.interface, keg.version);
            writer.interface.writeAll(",\"sha256\":") catch {};
            writeJsonString(&writer.interface, keg.sha256);
            writer.interface.print(",\"pinned\":{s},\"installed_at\":{d}}}", .{
                if (keg.pinned) "true" else "false", keg.installed_at,
            }) catch {};
        }
        writer.interface.writeAll("],\"casks\":[") catch { write_ok = false; };
        for (self.casks.items, 0..) |c, i| {
            if (i > 0) writer.interface.writeAll(",") catch {};
            writer.interface.writeAll("{\"token\":") catch {};
            writeJsonString(&writer.interface, c.token);
            writer.interface.writeAll(",\"version\":") catch {};
            writeJsonString(&writer.interface, c.version);
            writer.interface.writeAll(",\"apps\":[") catch {};
            for (c.apps, 0..) |a, j| {
                if (j > 0) writer.interface.writeAll(",") catch {};
                writeJsonString(&writer.interface, a);
            }
            writer.interface.writeAll("],\"binaries\":[") catch {};
            for (c.binaries, 0..) |b, j| {
                if (j > 0) writer.interface.writeAll(",") catch {};
                writeJsonString(&writer.interface, b);
            }
            writer.interface.writeAll("]}") catch {};
        }
        writer.interface.writeAll("],\"history\":{") catch { write_ok = false; };
        var hist_iter = self.history.iterator();
        var hist_first = true;
        while (hist_iter.next()) |entry| {
            if (!hist_first) writer.interface.writeAll(",") catch {};
            hist_first = false;
            writeJsonString(&writer.interface, entry.key_ptr.*);
            writer.interface.writeAll(":[") catch {};
            for (entry.value_ptr.items, 0..) |h, hi| {
                if (hi > 0) writer.interface.writeAll(",") catch {};
                writer.interface.writeAll("{\"version\":") catch {};
                writeJsonString(&writer.interface, h.version);
                writer.interface.writeAll(",\"sha256\":") catch {};
                writeJsonString(&writer.interface, h.sha256);
                writer.interface.print(",\"installed_at\":{d}}}", .{h.installed_at}) catch {};
            }
            writer.interface.writeAll("]") catch {};
        }
        writer.interface.writeAll("},\"deb_packages\":[") catch { write_ok = false; };
        for (self.debs.items, 0..) |d, i| {
            if (i > 0) writer.interface.writeAll(",") catch {};
            writer.interface.writeAll("{\"name\":") catch {};
            writeJsonString(&writer.interface, d.name);
            writer.interface.writeAll(",\"version\":") catch {};
            writeJsonString(&writer.interface, d.version);
            writer.interface.writeAll(",\"sha256\":") catch {};
            writeJsonString(&writer.interface, d.sha256);
            writer.interface.print(",\"installed_at\":{d},\"files\":[", .{d.installed_at}) catch {};
            for (d.files, 0..) |f, j| {
                if (j > 0) writer.interface.writeAll(",") catch {};
                writeJsonString(&writer.interface, f);
            }
            writer.interface.writeAll("]}") catch {};
        }
        writer.interface.writeAll("]}") catch { write_ok = false; };

        writer.interface.flush() catch {};
        file.sync(lib_io) catch {};
        file.close(lib_io);

        if (!write_ok) {
            std.Io.Dir.deleteFileAbsolute(lib_io, tmp_path) catch {};
            return error.SaveFailed;
        }

        try std.Io.Dir.renameAbsolute(tmp_path, DB_PATH, lib_io);
        self.dirty = false;
    }
};

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    if (obj.get(key)) |val| {
        if (val == .bool) return val.bool;
    }
    return false;
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    if (obj.get(key)) |val| {
        if (val == .integer) return val.integer;
    }
    return 0;
}

const testing = std.testing;

const TestBufWriter = struct {
    buf: [20480]u8 = undefined,
    pos: usize = 0,
    pub fn writeAll(self: *@This(), bytes: []const u8) anyerror!void {
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }
    pub fn written(self: *const @This()) []const u8 {
        return self.buf[0..self.pos];
    }
    pub fn reset(self: *@This()) void {
        self.pos = 0;
    }
};

test "writeJsonEscaped escapes double quotes" {
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, "hello\"world");
    try testing.expectEqualStrings("hello\\\"world", w.written());
}

test "writeJsonEscaped escapes backslashes" {
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, "path\\to\\file");
    try testing.expectEqualStrings("path\\\\to\\\\file", w.written());
}

test "writeJsonEscaped escapes newlines and tabs" {
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, "line1\nline2\ttab");
    try testing.expectEqualStrings("line1\\nline2\\ttab", w.written());
}

test "writeJsonEscaped escapes control characters" {
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, "null\x00byte");
    try testing.expectEqualStrings("null\\u0000byte", w.written());
}

test "writeJsonEscaped passes normal text through" {
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, "normal-package_1.2.3");
    try testing.expectEqualStrings("normal-package_1.2.3", w.written());
}

test "writeJsonString produces valid JSON string" {
    var w: TestBufWriter = .{};
    Database.writeJsonString(&w, "test\"pkg");
    try testing.expectEqualStrings("\"test\\\"pkg\"", w.written());
}

test "writeJsonEscaped blocks JSON injection payload" {
    var w: TestBufWriter = .{};
    const malicious = "evil\",\"pinned\":true,\"x\":\"";
    Database.writeJsonEscaped(&w, malicious);
    const escaped = w.written();
    var unescaped_quotes: usize = 0;
    for (escaped, 0..) |c, i| {
        if (c == '"' and (i == 0 or escaped[i - 1] != '\\')) {
            unescaped_quotes += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), unescaped_quotes);
}
