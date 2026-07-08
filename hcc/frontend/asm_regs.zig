//! Per-architecture assembler register vocabularies, shared by the parser (is
//! this identifier operand a register or a HolyC variable?) and the LLVM backend
//! (which registers may a `reg <REG>` pin claim, and what does a named register
//! clobber?). One source for both so the views can't drift; the backend builds
//! constraint strings from these names, never the reverse (this module links no
//! LLVM, like the rest of the front end).
//!
//! Adding an architecture: add its qualifier to `arches`, its classification
//! set, and its canonical-GP map here, then give the backend an `AsmArchInfo`
//! entry (see hcc/llvm/lower.zig and docs/asm-roadmap.md).

const std = @import("std");
const target = @import("target.zig");

/// Architecture qualifiers an asm block may carry (`asm amd64 { … }`). A bare
/// `asm { … }` defaults to amd64; sema validates the qualifier.
pub const arches = [_][]const u8{ "amd64", "arm64", "riscv64", "ppc64le", "s390x" };

pub fn isArch(name: []const u8) bool {
    for (arches) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

/// The asm-block qualifier for a target architecture.
pub fn archName(arch: target.Arch) []const u8 {
    return switch (arch) {
        .amd64 => "amd64",
        .arm64 => "arm64",
        .riscv64 => "riscv64",
        .ppc64le => "ppc64le",
        .s390x => "s390x",
    };
}

/// Whether name (case-insensitive) is a register of arch, distinguishing a
/// register operand from a variable/symbol reference. Register names are
/// case-insensitive: RAX and rax are the same register. This is the full operand
/// vocabulary (a superset of the pinnable GP set), including the
/// stack/frame/instruction/zero registers and the FP/vector files.
pub fn isRegister(arch: []const u8, name: []const u8) bool {
    var buf: [8]u8 = undefined;
    if (name.len > buf.len) return false;
    const lowered = std.ascii.lowerString(&buf, name);
    if (std.mem.eql(u8, arch, "amd64")) return amd64_registers.has(lowered);
    if (std.mem.eql(u8, arch, "arm64")) return arm64_registers.has(lowered);
    if (std.mem.eql(u8, arch, "riscv64")) return riscv64_registers.has(lowered);
    if (std.mem.eql(u8, arch, "ppc64le")) return ppc64le_registers.has(lowered);
    if (std.mem.eql(u8, arch, "s390x")) return s390x_registers.has(lowered);
    return false;
}

/// The canonical 64-bit GP register for a register spelling (case-insensitive),
/// or null when it has no pinnable/clobberable GP form. The
/// stack/frame/instruction/zero registers are absent: they may be named in an
/// operand but are never pinned or clobbered.
pub fn canonGp(arch: target.Arch, name: []const u8) ?[]const u8 {
    var buf: [8]u8 = undefined;
    if (name.len > buf.len) return null;
    const lowered = std.ascii.lowerString(&buf, name);
    return switch (arch) {
        .amd64 => amd64_canon_gp.get(lowered),
        .arm64 => arm64_canon_gp.get(lowered),
        .riscv64 => riscv64_canon_gp.get(lowered),
        .ppc64le => ppc64le_canon_gp.get(lowered),
        .s390x => s390x_canon_gp.get(lowered),
    };
}

// ---- operand-classification sets (any spelling the parser accepts) ----

const amd64_registers = std.StaticStringMap(void).initComptime(blk: {
    @setEvalBranchQuota(40_000);
    var names: []const []const u8 = &.{
        "rip",
        "rax",
        "rbx",
        "rcx",
        "rdx",
        "rsi",
        "rdi",
        "rbp",
        "rsp",
        "eax",
        "ebx",
        "ecx",
        "edx",
        "esi",
        "edi",
        "ebp",
        "esp",
        "ax",
        "bx",
        "cx",
        "dx",
        "si",
        "di",
        "bp",
        "sp",
        "al",
        "bl",
        "cl",
        "dl",
        "sil",
        "dil",
        "bpl",
        "spl",
        "ah",
        "bh",
        "ch",
        "dh",
    };
    for (8..16) |i| {
        const n = std.fmt.comptimePrint("{d}", .{i});
        names = names ++ [_][]const u8{ "r" ++ n, "r" ++ n ++ "d", "r" ++ n ++ "w", "r" ++ n ++ "b" };
    }
    for (0..16) |i| {
        names = names ++ [_][]const u8{"xmm" ++ std.fmt.comptimePrint("{d}", .{i})};
    }
    break :blk registerEntries(names);
});

const arm64_registers = std.StaticStringMap(void).initComptime(blk: {
    @setEvalBranchQuota(40_000);
    var names: []const []const u8 = &.{ "sp", "xzr", "wzr", "lr", "fp" };
    for (0..31) |i| {
        const n = std.fmt.comptimePrint("{d}", .{i});
        names = names ++ [_][]const u8{ "x" ++ n, "w" ++ n };
    }
    for (0..32) |i| {
        const n = std.fmt.comptimePrint("{d}", .{i});
        names = names ++ [_][]const u8{ "v" ++ n, "d" ++ n, "s" ++ n, "q" ++ n };
    }
    break :blk registerEntries(names);
});

const riscv64_registers = std.StaticStringMap(void).initComptime(blk: {
    @setEvalBranchQuota(40_000);
    var names: []const []const u8 = &.{ "zero", "ra", "sp", "gp", "tp", "fp" };
    for (0..32) |i| {
        const n = std.fmt.comptimePrint("{d}", .{i});
        names = names ++ [_][]const u8{ "x" ++ n, "f" ++ n };
    }
    for (0..7) |i| { // temporaries t0–t6
        names = names ++ [_][]const u8{"t" ++ std.fmt.comptimePrint("{d}", .{i})};
    }
    for (0..12) |i| { // saved s0–s11 and their float twins fs0–fs11, ft0–ft11
        const n = std.fmt.comptimePrint("{d}", .{i});
        names = names ++ [_][]const u8{ "s" ++ n, "fs" ++ n, "ft" ++ n };
    }
    for (0..8) |i| { // arguments a0–a7 / fa0–fa7
        const n = std.fmt.comptimePrint("{d}", .{i});
        names = names ++ [_][]const u8{ "a" ++ n, "fa" ++ n };
    }
    break :blk registerEntries(names);
});

const ppc64le_registers = std.StaticStringMap(void).initComptime(blk: {
    @setEvalBranchQuota(40_000);
    // HolyC source names PPC registers (r3, f1, v2, cr0) though the assembler
    // wants bare numbers; the backend strips the prefix when rendering.
    // lr/ctr/xer only appear via mnemonics but classify anyway.
    var names: []const []const u8 = &.{ "lr", "ctr", "xer" };
    for (0..32) |i| {
        const n = std.fmt.comptimePrint("{d}", .{i});
        names = names ++ [_][]const u8{ "r" ++ n, "f" ++ n, "v" ++ n };
    }
    for (0..8) |i| {
        names = names ++ [_][]const u8{"cr" ++ std.fmt.comptimePrint("{d}", .{i})};
    }
    break :blk registerEntries(names);
});

const s390x_registers = std.StaticStringMap(void).initComptime(blk: {
    @setEvalBranchQuota(40_000);
    // HolyC source names s390x registers bare (r2); the backend renders the
    // %-prefixed spelling the assembler wants.
    var names: []const []const u8 = &.{};
    for (0..16) |i| {
        const n = std.fmt.comptimePrint("{d}", .{i});
        names = names ++ [_][]const u8{ "r" ++ n, "f" ++ n };
    }
    for (0..32) |i| {
        names = names ++ [_][]const u8{"v" ++ std.fmt.comptimePrint("{d}", .{i})};
    }
    break :blk registerEntries(names);
});

fn registerEntries(comptime names: []const []const u8) [names.len]struct { []const u8 } {
    var entries: [names.len]struct { []const u8 } = undefined;
    for (names, 0..) |n, i| entries[i] = .{n};
    return entries;
}

// ---- canonical GP maps (spelling of any width → canonical 64-bit name) ----

const CanonEntry = struct { []const u8, []const u8 };

const amd64_canon_gp = std.StaticStringMap([]const u8).initComptime(blk: {
    @setEvalBranchQuota(40_000);
    const groups = [_][]const []const u8{
        &.{ "rax", "eax", "ax", "al", "ah" },
        &.{ "rbx", "ebx", "bx", "bl", "bh" },
        &.{ "rcx", "ecx", "cx", "cl", "ch" },
        &.{ "rdx", "edx", "dx", "dl", "dh" },
        &.{ "rsi", "esi", "si", "sil" },
        &.{ "rdi", "edi", "di", "dil" },
    };
    var entries: []const CanonEntry = &.{};
    for (groups) |g| {
        for (g) |n| entries = entries ++ [_]CanonEntry{.{ n, g[0] }};
    }
    for (8..16) |i| {
        const r = std.fmt.comptimePrint("r{d}", .{i});
        for ([_][]const u8{ r, r ++ "d", r ++ "w", r ++ "b" }) |n| {
            entries = entries ++ [_]CanonEntry{.{ n, r }};
        }
    }
    break :blk entries;
});

const arm64_canon_gp = std.StaticStringMap([]const u8).initComptime(blk: {
    @setEvalBranchQuota(40_000);
    var entries: []const CanonEntry = &.{.{ "lr", "x30" }};
    for (0..31) |i| {
        if (i == 29) continue; // x29 is the frame pointer: not pinnable
        const x = std.fmt.comptimePrint("x{d}", .{i});
        const w = std.fmt.comptimePrint("w{d}", .{i});
        entries = entries ++ [_]CanonEntry{ .{ x, x }, .{ w, x } };
    }
    break :blk entries;
});

const riscv64_canon_gp = std.StaticStringMap([]const u8).initComptime(blk: {
    @setEvalBranchQuota(40_000);
    // Canonical names are the x registers (LLVM's constraint spelling).
    // zero (x0), ra (x1), sp (x2), gp (x3), tp (x4), and s0/fp (x8) are absent:
    // never pinned or clobbered.
    var entries: []const CanonEntry = &.{};
    for (5..32) |i| {
        if (i == 8) continue;
        const x = std.fmt.comptimePrint("x{d}", .{i});
        entries = entries ++ [_]CanonEntry{.{ x, x }};
    }
    for (0..7) |i| { // t0–t2 → x5–x7, t3–t6 → x28–x31
        const t = std.fmt.comptimePrint("t{d}", .{i});
        const x = std.fmt.comptimePrint("x{d}", .{if (i < 3) i + 5 else i + 25});
        entries = entries ++ [_]CanonEntry{.{ t, x }};
    }
    for (1..12) |i| { // s1 → x9, s2–s11 → x18–x27 (s0 is the fp, absent)
        const s = std.fmt.comptimePrint("s{d}", .{i});
        const x = std.fmt.comptimePrint("x{d}", .{if (i == 1) 9 else i + 16});
        entries = entries ++ [_]CanonEntry{.{ s, x }};
    }
    for (0..8) |i| { // a0–a7 → x10–x17
        const a = std.fmt.comptimePrint("a{d}", .{i});
        const x = std.fmt.comptimePrint("x{d}", .{i + 10});
        entries = entries ++ [_]CanonEntry{.{ a, x }};
    }
    break :blk entries;
});

const ppc64le_canon_gp = std.StaticStringMap([]const u8).initComptime(blk: {
    @setEvalBranchQuota(40_000);
    // r1 (stack pointer), r2 (TOC), r13 (thread pointer), and r31 (frame pointer
    // when present) are absent: never pinned or clobbered. r0 stays clobberable
    // (a mutable GPR) though pinning it is inadvisable (r0 reads as zero in
    // address bases).
    var entries: []const CanonEntry = &.{};
    for (0..32) |i| {
        if (i == 1 or i == 2 or i == 13 or i == 31) continue;
        const r = std.fmt.comptimePrint("r{d}", .{i});
        entries = entries ++ [_]CanonEntry{.{ r, r }};
    }
    break :blk entries;
});

const s390x_canon_gp = std.StaticStringMap([]const u8).initComptime(blk: {
    @setEvalBranchQuota(40_000);
    // r15 (stack pointer) and r11 (frame pointer when present) are absent.
    // r14 (return address) stays, mirroring arm64's lr.
    var entries: []const CanonEntry = &.{};
    for (0..16) |i| {
        if (i == 11 or i == 15) continue;
        const r = std.fmt.comptimePrint("r{d}", .{i});
        entries = entries ++ [_]CanonEntry{.{ r, r }};
    }
    break :blk entries;
});

// ---- tests ----

test "asm register classification" {
    try std.testing.expect(isRegister("amd64", "RAX"));
    try std.testing.expect(isRegister("amd64", "r15d"));
    try std.testing.expect(isRegister("amd64", "xmm7"));
    try std.testing.expect(!isRegister("amd64", "x0"));
    try std.testing.expect(isRegister("arm64", "x0"));
    try std.testing.expect(isRegister("arm64", "W30"));
    try std.testing.expect(isRegister("arm64", "v31"));
    try std.testing.expect(!isRegister("arm64", "rax"));
    try std.testing.expect(!isRegister("amd64", "counter"));
    try std.testing.expect(isRegister("riscv64", "x31"));
    try std.testing.expect(isRegister("riscv64", "A0"));
    try std.testing.expect(isRegister("riscv64", "zero"));
    try std.testing.expect(isRegister("riscv64", "ft11"));
    try std.testing.expect(!isRegister("riscv64", "x32"));
    try std.testing.expect(!isRegister("riscv64", "t7"));
    try std.testing.expect(!isRegister("riscv64", "rax"));
    try std.testing.expect(isRegister("ppc64le", "R31"));
    try std.testing.expect(isRegister("ppc64le", "cr7"));
    try std.testing.expect(isRegister("ppc64le", "ctr"));
    try std.testing.expect(!isRegister("ppc64le", "r32"));
    try std.testing.expect(!isRegister("ppc64le", "rax"));
    try std.testing.expect(isRegister("s390x", "R15"));
    try std.testing.expect(isRegister("s390x", "f15"));
    try std.testing.expect(isRegister("s390x", "v31"));
    try std.testing.expect(!isRegister("s390x", "r16"));
    try std.testing.expect(!isRegister("s390x", "x0"));
}

test "canonical GP mapping" {
    try std.testing.expectEqualStrings("rax", canonGp(.amd64, "EAX").?);
    try std.testing.expectEqualStrings("rax", canonGp(.amd64, "ah").?);
    try std.testing.expectEqualStrings("r11", canonGp(.amd64, "r11b").?);
    try std.testing.expect(canonGp(.amd64, "rsp") == null);
    try std.testing.expect(canonGp(.amd64, "rip") == null);
    try std.testing.expectEqualStrings("x30", canonGp(.arm64, "LR").?);
    try std.testing.expectEqualStrings("x5", canonGp(.arm64, "w5").?);
    try std.testing.expect(canonGp(.arm64, "sp") == null);
    try std.testing.expect(canonGp(.arm64, "x29") == null);
    try std.testing.expect(canonGp(.arm64, "v3") == null);
    try std.testing.expectEqualStrings("x10", canonGp(.riscv64, "a0").?);
    try std.testing.expectEqualStrings("x5", canonGp(.riscv64, "T0").?);
    try std.testing.expectEqualStrings("x28", canonGp(.riscv64, "t3").?);
    try std.testing.expectEqualStrings("x9", canonGp(.riscv64, "s1").?);
    try std.testing.expectEqualStrings("x27", canonGp(.riscv64, "s11").?);
    try std.testing.expect(canonGp(.riscv64, "zero") == null);
    try std.testing.expect(canonGp(.riscv64, "ra") == null);
    try std.testing.expect(canonGp(.riscv64, "sp") == null);
    try std.testing.expect(canonGp(.riscv64, "x8") == null);
    try std.testing.expect(canonGp(.riscv64, "s0") == null);
    try std.testing.expect(canonGp(.riscv64, "fa0") == null);
    try std.testing.expectEqualStrings("r14", canonGp(.ppc64le, "R14").?);
    try std.testing.expectEqualStrings("r0", canonGp(.ppc64le, "r0").?);
    try std.testing.expect(canonGp(.ppc64le, "r1") == null);
    try std.testing.expect(canonGp(.ppc64le, "r2") == null);
    try std.testing.expect(canonGp(.ppc64le, "r13") == null);
    try std.testing.expect(canonGp(.ppc64le, "r31") == null);
    try std.testing.expect(canonGp(.ppc64le, "f5") == null);
    try std.testing.expectEqualStrings("r6", canonGp(.s390x, "R6").?);
    try std.testing.expectEqualStrings("r14", canonGp(.s390x, "r14").?);
    try std.testing.expect(canonGp(.s390x, "r15") == null);
    try std.testing.expect(canonGp(.s390x, "r11") == null);
    try std.testing.expect(canonGp(.s390x, "f0") == null);
}

test "every canonical GP spelling classifies as a register" {
    for (amd64_canon_gp.keys()) |k| {
        try std.testing.expect(isRegister("amd64", k));
    }
    for (arm64_canon_gp.keys()) |k| {
        try std.testing.expect(isRegister("arm64", k));
    }
    for (riscv64_canon_gp.keys()) |k| {
        try std.testing.expect(isRegister("riscv64", k));
    }
    for (ppc64le_canon_gp.keys()) |k| {
        try std.testing.expect(isRegister("ppc64le", k));
    }
    for (s390x_canon_gp.keys()) |k| {
        try std.testing.expect(isRegister("s390x", k));
    }
}
