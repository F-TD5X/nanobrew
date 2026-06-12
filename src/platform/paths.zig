// nanobrew — Centralized path constants
//
// All path constants for the nanobrew directory tree.
// Same values on both macOS and Linux.

const std = @import("std");

pub const ROOT = "/opt/nanobrew";
pub const PREFIX = ROOT ++ "/prefix";
pub const CELLAR_DIR = PREFIX ++ "/Cellar";
pub const BIN_DIR = PREFIX ++ "/bin";
pub const OPT_DIR = PREFIX ++ "/opt";
pub const LIB_DIR = PREFIX ++ "/lib";
pub const INCLUDE_DIR = PREFIX ++ "/include";
pub const SHARE_DIR = PREFIX ++ "/share";
pub const ETC_DIR = PREFIX ++ "/etc";

// ── Process-wide threadsafe Io accessor ──────────────────────────────────
//
// `std.Io.Threaded.global_single_threaded` is the only `Io` instance Zig
// 0.16 makes available without an explicit `init`, but its docs spell out
// "This instance does not support concurrency or cancelation." — sharing
// it across worker threads is undefined behavior and the visible failure
// modes range from `error.OutOfMemory` (postinst pipe-aggregator races)
// to `error.CopyFailed` (vtable mismatch in std.process.run) to outright
// SIGSEGV (parallel deb extract corruption).
//
// `safe_io` holds the main thread's `init.io` — a real Threaded instance
// backed by a threadsafe gpa — and is intended as a drop-in replacement
// for the singleton anywhere code might run from a worker thread. main.zig
// is responsible for assigning it once during startup before any worker
// spawns; reading it before then is a programming error.
pub var safe_io: std.Io = std.Io.Threaded.global_single_threaded.io();

pub const STORE_DIR = ROOT ++ "/store";
/// Post-relocation store
pub const STORE_RELOCATED_DIR = ROOT ++ "/store-relocated";
pub const CACHE_DIR = ROOT ++ "/cache";
pub const CONFIG_DIR = ROOT ++ "/config";
pub const BLOBS_DIR = CACHE_DIR ++ "/blobs";
pub const TMP_DIR = CACHE_DIR ++ "/tmp";
pub const API_CACHE_DIR = CACHE_DIR ++ "/api";
pub const APT_CACHE_DIR = CACHE_DIR ++ "/apt";
pub const TOKEN_CACHE_DIR = CACHE_DIR ++ "/tokens";
pub const DB_PATH = ROOT ++ "/db/state.json";
pub const CASKROOM_DIR = PREFIX ++ "/Caskroom";

pub const PLACEHOLDER_PREFIX = "@@HOMEBREW_PREFIX@@";
pub const PLACEHOLDER_CELLAR = "@@HOMEBREW_CELLAR@@";
pub const PLACEHOLDER_REPOSITORY = "@@HOMEBREW_REPOSITORY@@";
pub const REAL_PREFIX = PREFIX;
pub const REAL_CELLAR = PREFIX ++ "/Cellar";
pub const REAL_REPOSITORY = ROOT;
pub const PLACEHOLDER_LIBRARY = "@@HOMEBREW_LIBRARY@@";
pub const REAL_LIBRARY = ROOT ++ "/Library";
// Shebang placeholder for formulae whose scripts run under brewed perl
// (autoconf, automake, …). Homebrew pours it as <prefix>/opt/perl/bin/perl.
pub const PLACEHOLDER_PERL = "@@HOMEBREW_PERL@@";
pub const REAL_PERL = PREFIX ++ "/opt/perl/bin/perl";
