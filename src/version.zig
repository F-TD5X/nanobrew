const std = @import("std");

/// Compare two version strings using numeric segment comparison.
/// Splits on '.' and '_' (underscore is revision separator in Homebrew).
/// Returns .lt, .eq, or .gt indicating if `a` is less than, equal to, or greater than `b`.
pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    // Fast path: identical strings
    if (std.mem.eql(u8, a, b)) return .eq;

    var it_a = SegmentIterator.init(a);
    var it_b = SegmentIterator.init(b);

    while (true) {
        const seg_a = it_a.next();
        const seg_b = it_b.next();

        // Both exhausted → equal
        if (seg_a == null and seg_b == null) return .eq;

        // Shorter version with no more segments is less (e.g., "10.47" < "10.47_1")
        const sa = seg_a orelse "";
        const sb = seg_b orelse "";

        // If one side is exhausted, its segment is effectively "0"
        if (seg_a == null) {
            // a is exhausted; if b's remaining segment is > 0, a < b
            const nb_val = parseNumeric(sb);
            if (nb_val) |val| {
                if (val > 0) return .lt;
                // val == 0 means this segment doesn't matter, continue
            } else {
                // non-numeric remaining segment in b → a < b
                return .lt;
            }
            continue;
        }
        if (seg_b == null) {
            const na_val = parseNumeric(sa);
            if (na_val) |val| {
                if (val > 0) return .gt;
            } else {
                return .gt;
            }
            continue;
        }

        // Both segments present — try numeric comparison first
        const na = parseNumeric(sa);
        const nb = parseNumeric(sb);

        if (na != null and nb != null) {
            // Both numeric
            if (na.? < nb.?) return .lt;
            if (na.? > nb.?) return .gt;
            // Equal numerically, continue to next segment
        } else {
            // At least one is non-numeric → lexicographic comparison
            const order = std.mem.order(u8, sa, sb);
            if (order != .eq) return order;
        }
    }
}

/// Returns true if version `a` is strictly newer than version `b`.
pub fn isNewer(a: []const u8, b: []const u8) bool {
    return compareVersions(a, b) == .gt;
}

/// Trim whitespace and a single leading release-tag `v`/`V` prefix.
pub fn normalizeVersion(v: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, v, " \t\r\n");
    if (trimmed.len > 0 and (trimmed[0] == 'v' or trimmed[0] == 'V')) return trimmed[1..];
    return trimmed;
}

/// Returns true only when `latest` is strictly newer than `current`.
pub fn isUpdateAvailable(current: []const u8, latest: []const u8) bool {
    const current_norm = normalizeVersion(current);
    const latest_norm = normalizeVersion(latest);
    if (current_norm.len == 0 or latest_norm.len == 0) return false;
    return isNewer(latest_norm, current_norm);
}

fn parseNumeric(s: []const u8) ?u64 {
    if (s.len == 0) return 0;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

const SegmentIterator = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) SegmentIterator {
        return .{ .data = data, .pos = 0 };
    }

    fn next(self: *SegmentIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;

        const start = self.pos;
        while (self.pos < self.data.len) : (self.pos += 1) {
            if (self.data[self.pos] == '.' or self.data[self.pos] == '_') {
                const seg = self.data[start..self.pos];
                self.pos += 1; // skip delimiter
                return seg;
            }
        }
        return self.data[start..self.pos];
    }
};

// ============================================================
// Tests
// ============================================================

test "compareVersions: revision makes newer" {
    // 10.47_1 > 10.47
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("10.47_1", "10.47"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("10.47", "10.47_1"));
}

test "compareVersions: leading zeros / different digit counts" {
    // 0.1.067 > 0.1.06  (67 > 6)
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.1.067", "0.1.06"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.1.06", "0.1.067"));
}

test "compareVersions: numeric segment ordering" {
    // 1.10 > 1.9  (10 > 9, not lexicographic)
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.10", "1.9"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("1.9", "1.10"));
}

test "compareVersions: major version difference" {
    // 2.0 > 1.99
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("2.0", "1.99"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("1.99", "2.0"));
}

test "compareVersions: equal versions" {
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("1.2.3", "1.2.3"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.1.068", "0.1.068"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("10.47_1", "10.47_1"));
}

test "compareVersions: empty and edge cases" {
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("", ""));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("", "1.0"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.0", ""));
}

test "compareVersions: non-numeric suffixes" {
    // alpha < beta (lexicographic)
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("1.0.alpha", "1.0.beta"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.0.beta", "1.0.alpha"));
}

test "isNewer: convenience function" {
    try std.testing.expect(isNewer("10.47_1", "10.47"));
    try std.testing.expect(isNewer("0.1.067", "0.1.06"));
    try std.testing.expect(isNewer("1.10", "1.9"));
    try std.testing.expect(isNewer("2.0", "1.99"));
    try std.testing.expect(!isNewer("1.0", "1.0"));
    try std.testing.expect(!isNewer("1.0", "2.0"));
}

test "isUpdateAvailable rejects downgrades and equal versions" {
    try std.testing.expect(!isUpdateAvailable("0.1.192", "0.1.191"));
    try std.testing.expect(!isUpdateAvailable("0.1.192", "0.1.192"));
    try std.testing.expect(isUpdateAvailable("0.1.191", "0.1.192"));
}

test "isUpdateAvailable normalizes release tag prefixes and whitespace" {
    try std.testing.expect(isUpdateAvailable("0.1.191", " v0.1.192\n"));
    try std.testing.expect(!isUpdateAvailable("v0.1.192", "0.1.191"));
}
