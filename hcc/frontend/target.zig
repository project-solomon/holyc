//! The compilation target: the structured (LLVM-free) view the front end needs.
//! arch drives the `__amd64__`/`__arm64__` macros and `asm` block selection; OS
//! drives the platform macros and the backend's OS-specific lowering; an
//! optional libc ABI applies to Linux/Windows triples. `llvmTriple` is the one
//! seam mapping these to LLVM's spellings.
//!
//! Covers only the architectures and OSes the toolchain compiles for. The
//! triple syntax still reads/writes the vendor component, but it is derived from
//! the OS rather than stored.

const std = @import("std");
const builtin = @import("builtin");

pub const Os = enum {
    darwin,
    linux,
    windows,

    pub fn fromString(s: []const u8) ?Os {
        const map = std.StaticStringMap(Os).initComptime(.{
            .{ "darwin", .darwin },
            .{ "macosx", .darwin },
            .{ "linux", .linux },
            .{ "windows", .windows },
        });
        return map.get(s);
    }
};

pub const Arch = enum {
    /// 64-bit Intel.
    amd64,
    /// 64-bit ARM (aarch64).
    arm64,
    /// 64-bit RISC-V (RV64GC). Linux-only: no darwin, windows out of scope
    /// (see docs/asm-roadmap.md).
    riscv64,
    /// 64-bit little-endian POWER (ELFv2). Linux-only.
    ppc64le,
    /// IBM z/Architecture. Linux-only.
    s390x,

    pub fn fromString(s: []const u8) ?Arch {
        const map = std.StaticStringMap(Arch).initComptime(.{
            // "amd64" is canonical (matches the __amd64__ macro); "x86_64" is
            // the GNU triple alias.
            .{ "amd64", .amd64 },
            .{ "x86_64", .amd64 },
            // "arm64" is canonical (matches __arm64__); "aarch64" is the GNU
            // triple alias.
            .{ "arm64", .arm64 },
            .{ "aarch64", .arm64 },
            // "riscv64" is canonical and the GNU/LLVM spelling; "rv64" is the
            // ISA-style shorthand.
            .{ "riscv64", .riscv64 },
            .{ "rv64", .riscv64 },
            // "ppc64le" is canonical; "powerpc64le" is the GNU/LLVM spelling.
            .{ "ppc64le", .ppc64le },
            .{ "powerpc64le", .ppc64le },
            // "s390x" is canonical and the GNU/LLVM spelling.
            .{ "s390x", .s390x },
        });
        return map.get(s);
    }
};

/// The libc/runtime environment: the optional 4th triple component (the "gnu"
/// in x86_64-unknown-linux-gnu). `.unset` means no ABI component (always so for
/// darwin).
pub const Abi = enum {
    unset,
    /// glibc (Linux) or mingw (Windows).
    gnu,
    /// The musl libc (Linux).
    musl,
    /// The Microsoft Visual C++ runtime (Windows).
    msvc,

    pub fn fromString(s: []const u8) ?Abi {
        const abi = std.meta.stringToEnum(Abi, s) orelse return null;
        return if (abi == .unset) null else abi;
    }
};

pub const ParseError = error{
    MissingComponents,
    InvalidArch,
    InvalidVendor,
    InvalidOs,
    InvalidAbi,
    AppleDarwinMismatch,
    AbiNotValidForOs,
    ArchNotValidForOs,
};

/// Human-readable explanation for each parse/validation failure, for CLI error
/// messages.
pub fn explain(e: ParseError) []const u8 {
    return switch (e) {
        error.MissingComponents => "expected <arch>-<vendor>-<os>[-<abi>]",
        error.InvalidArch => "unknown architecture (amd64/x86_64, arm64/aarch64, riscv64, ppc64le, or s390x)",
        error.InvalidVendor => "unknown vendor",
        error.InvalidOs => "unknown OS (darwin, linux, or windows)",
        error.InvalidAbi => "unknown ABI (gnu, musl, or msvc)",
        error.AppleDarwinMismatch => "apple vendor and darwin OS must be used together",
        error.AbiNotValidForOs => "the ABI is not valid on that OS",
        error.ArchNotValidForOs => "the architecture is not supported on that OS (riscv64, ppc64le, and s390x are linux-only)",
    };
}

/// Vendor spellings accepted in a triple. Not stored: the vendor is derived
/// from the OS when rendering.
const vendors = std.StaticStringMap(void).initComptime(.{
    .{"unknown"}, .{"pc"}, .{"apple"}, .{"none"}, .{"w64"},
});

pub const Target = struct {
    arch: Arch,
    os: Os,
    abi: Abi = .unset,

    /// The target for the machine hcc is running on, from the compile-time
    /// target of the hcc binary. ABI is left unset (glibc and musl hosts look
    /// the same at run time).
    pub fn host() Target {
        const arch: Arch = switch (builtin.target.cpu.arch) {
            .x86_64 => .amd64,
            .aarch64 => .arm64,
            .riscv64 => .riscv64,
            .powerpc64le => .ppc64le,
            .s390x => .s390x,
            else => @compileError("unsupported host architecture for hcc"),
        };
        return switch (builtin.target.os.tag) {
            .macos => .{ .arch = arch, .os = .darwin },
            .linux => .{ .arch = arch, .os = .linux },
            .windows => .{ .arch = arch, .os = .windows },
            else => @compileError("unsupported host OS for hcc"),
        };
    }

    /// Parses "<arch>-<vendor>-<os>[-<abi>]" and validates the combination.
    pub fn parse(s: []const u8) ParseError!Target {
        var it = std.mem.splitScalar(u8, s, '-');
        const arch_s = it.next() orelse return error.MissingComponents;
        const vendor_s = it.next() orelse return error.MissingComponents;
        const os_s = it.next() orelse return error.MissingComponents;

        var t: Target = .{
            .arch = Arch.fromString(arch_s) orelse return error.InvalidArch,
            .os = Os.fromString(os_s) orelse return error.InvalidOs,
        };
        if (!vendors.has(vendor_s)) return error.InvalidVendor;
        // apple and darwin imply each other.
        if (std.mem.eql(u8, vendor_s, "apple") != (t.os == .darwin)) {
            return error.AppleDarwinMismatch;
        }

        if (it.next()) |abi_s| {
            t.abi = Abi.fromString(abi_s) orelse return error.InvalidAbi;
        }
        if (it.next() != null) return error.MissingComponents;

        // An unset ABI is always fine (the norm for darwin). A set ABI must be
        // one the OS knows.
        const abi_ok = switch (t.abi) {
            .unset => true,
            .gnu => t.os != .darwin,
            .musl => t.os == .linux,
            .msvc => t.os == .windows,
        };
        if (!abi_ok) return error.AbiNotValidForOs;
        const linux_only = switch (t.arch) {
            .riscv64, .ppc64le, .s390x => true,
            .amd64, .arm64 => false,
        };
        if (linux_only and t.os != .linux) return error.ArchNotValidForOs;
        return t;
    }

    /// The vendor component for the OS (not stored on Target).
    fn vendor(t: Target) []const u8 {
        return switch (t.os) {
            .darwin => "apple",
            .linux => "unknown",
            .windows => "pc",
        };
    }

    pub fn format(t: Target, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}-{s}-{s}", .{ @tagName(t.arch), t.vendor(), @tagName(t.os) });
        if (t.abi != .unset) try w.print("-{s}", .{@tagName(t.abi)});
    }

    /// Renders the target in LLVM's spelling (x86_64/aarch64, macosx), for the
    /// backend to hand to LLVMCreateTargetMachine. darwin carries a deployment
    /// version so Mach-O objects get their platform load command (11.0 = first
    /// arm64 macOS).
    pub fn llvmTriple(t: Target, buf: []u8) []const u8 {
        const arch = switch (t.arch) {
            .amd64 => "x86_64",
            .arm64 => "aarch64",
            .riscv64 => "riscv64",
            .ppc64le => "powerpc64le",
            .s390x => "s390x",
        };
        const os = switch (t.os) {
            .darwin => "macosx11.0",
            else => @tagName(t.os),
        };
        var w = std.Io.Writer.fixed(buf);
        w.print("{s}-{s}-{s}", .{ arch, t.vendor(), os }) catch unreachable;
        if (t.abi != .unset) {
            w.print("-{s}", .{@tagName(t.abi)}) catch unreachable;
        } else if (t.os == .windows) {
            // LLVM defaults a bare *-windows triple to MSVC (it emits the
            // `_fltused` CRT marker); the toolchain links mingw by default, so
            // spell the environment out.
            w.writeAll("-gnu") catch unreachable;
        }
        return w.buffered();
    }
};

/// Writes the list of supported targets, for `hcc --target --help`. Curated
/// (aliases and per-OS notes need prose); keep in sync with the Arch/Os/Abi
/// enums above.
pub fn writeSupported(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print(
        \\A target is <arch>-<vendor>-<os>[-<abi>]. The default is the host ({f}).
        \\
        \\Architectures  amd64 (x86_64), arm64 (aarch64), riscv64, ppc64le, s390x
        \\Systems        darwin, linux, windows
        \\ABIs           gnu, musl, msvc   (optional; omit for the OS default)
        \\
        \\Examples:
        \\  arm64-apple-darwin         Apple Silicon macOS
        \\  amd64-apple-darwin         Intel macOS
        \\  amd64-unknown-linux-gnu    x86-64 Linux (glibc)
        \\  arm64-unknown-linux-musl   ARM64 Linux (musl)
        \\  riscv64-unknown-linux      RISC-V Linux
        \\  ppc64le-unknown-linux      POWER (little-endian) Linux
        \\  s390x-unknown-linux        IBM Z Linux
        \\  amd64-pc-windows           x86-64 Windows
        \\
        \\riscv64, ppc64le, and s390x are linux-only; apple and darwin imply
        \\each other. The vendor is otherwise free (unknown/pc/…).
        \\
    , .{Target.host()});
}

// ---- tests ----

const testing = std.testing;

test "writeSupported renders" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeSupported(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "riscv64") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Examples:") != null);
}

test "parse canonical and alias triples" {
    const t1 = try Target.parse("amd64-unknown-linux");
    try testing.expectEqual(Arch.amd64, t1.arch);
    try testing.expectEqual(Os.linux, t1.os);
    try testing.expectEqual(Abi.unset, t1.abi);

    const t2 = try Target.parse("x86_64-pc-linux-gnu");
    try testing.expectEqual(Arch.amd64, t2.arch);
    try testing.expectEqual(Abi.gnu, t2.abi);

    const t3 = try Target.parse("aarch64-apple-macosx");
    try testing.expectEqual(Arch.arm64, t3.arch);
    try testing.expectEqual(Os.darwin, t3.os);

    const t4 = try Target.parse("riscv64-unknown-linux-gnu");
    try testing.expectEqual(Arch.riscv64, t4.arch);
    try testing.expectEqual(Os.linux, t4.os);
    try testing.expectEqual(Abi.gnu, t4.abi);
    const t5 = try Target.parse("rv64-unknown-linux");
    try testing.expectEqual(Arch.riscv64, t5.arch);

    const t6 = try Target.parse("ppc64le-unknown-linux-gnu");
    try testing.expectEqual(Arch.ppc64le, t6.arch);
    const t7 = try Target.parse("powerpc64le-unknown-linux");
    try testing.expectEqual(Arch.ppc64le, t7.arch);
    const t8 = try Target.parse("s390x-unknown-linux-gnu");
    try testing.expectEqual(Arch.s390x, t8.arch);
}

test "reject incoherent triples" {
    try testing.expectError(error.AppleDarwinMismatch, Target.parse("arm64-apple-linux"));
    try testing.expectError(error.AppleDarwinMismatch, Target.parse("arm64-unknown-darwin"));
    try testing.expectError(error.AbiNotValidForOs, Target.parse("arm64-apple-darwin-gnu"));
    try testing.expectError(error.AbiNotValidForOs, Target.parse("amd64-unknown-linux-msvc"));
    try testing.expectError(error.MissingComponents, Target.parse("amd64-linux"));
    try testing.expectError(error.InvalidArch, Target.parse("mips-unknown-linux"));
    try testing.expectError(error.InvalidAbi, Target.parse("amd64-unknown-linux-gnueabi"));
    try testing.expectError(error.ArchNotValidForOs, Target.parse("riscv64-pc-windows"));
    try testing.expectError(error.AppleDarwinMismatch, Target.parse("riscv64-unknown-darwin"));
    try testing.expectError(error.ArchNotValidForOs, Target.parse("ppc64le-pc-windows"));
    try testing.expectError(error.ArchNotValidForOs, Target.parse("s390x-pc-windows"));
}

test "format round-trip and llvm triple" {
    var buf: [64]u8 = undefined;
    const t = try Target.parse("arm64-apple-darwin");
    try testing.expectEqualStrings("arm64-apple-darwin", try std.fmt.bufPrint(&buf, "{f}", .{t}));
    var lbuf: [64]u8 = undefined;
    try testing.expectEqualStrings("aarch64-apple-macosx11.0", t.llvmTriple(&lbuf));

    const t2 = try Target.parse("amd64-unknown-linux-musl");
    try testing.expectEqualStrings("x86_64-unknown-linux-musl", t2.llvmTriple(&lbuf));

    const t3 = try Target.parse("riscv64-unknown-linux-gnu");
    try testing.expectEqualStrings("riscv64-unknown-linux-gnu", t3.llvmTriple(&lbuf));

    const t3b = try Target.parse("ppc64le-unknown-linux");
    try testing.expectEqualStrings("powerpc64le-unknown-linux", t3b.llvmTriple(&lbuf));
    const t3c = try Target.parse("s390x-unknown-linux-gnu");
    try testing.expectEqualStrings("s390x-unknown-linux-gnu", t3c.llvmTriple(&lbuf));

    // A bare windows target renders with the gnu environment spelled out
    // (LLVM would otherwise default to msvc, mismatching the mingw link).
    const t4 = try Target.parse("amd64-pc-windows");
    try testing.expectEqualStrings("x86_64-pc-windows-gnu", t4.llvmTriple(&lbuf));
    const t5 = try Target.parse("amd64-pc-windows-msvc");
    try testing.expectEqualStrings("x86_64-pc-windows-msvc", t5.llvmTriple(&lbuf));
}

test "host is valid" {
    const h = Target.host();
    var buf: [64]u8 = undefined;
    _ = h.llvmTriple(&buf);
}
