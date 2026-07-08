//! Computes the in-memory size, alignment, and field offsets of every
//! class/union, plus the compile-time constant-expression evaluator.
//!
//! Standalone pass: the frontend runs it after sema and folds its errors into
//! the shared diagnostics; the backends consume its results. The model is
//! natural alignment with padding, matching the x86-64 C ABI:
//!   - Scalar alignments equal their sizes: I8=1, I16=2, I32=4,
//!     I64/U64/F64/pointer=8.
//!   - Each field goes at the next offset that is a multiple of its alignment,
//!     inserting padding as needed.
//!   - A class's alignment is the max of its fields'; its size is rounded up to
//!     that alignment so arrays of it stay aligned.
//!   - A union places every field at offset 0; its size is the largest field,
//!     rounded up to the max alignment.
//!   - A base class is a subobject at offset 0, before derived fields.
//!
//! The whole rule lives in alignOfScalar and roundUp; a packed layout
//! (alignment 1) would change only those. Constant folding follows Go's int64
//! semantics: two's-complement wrapping arithmetic, truncated division, and
//! shift counts masked to 32 bits with >= 64 shifting everything out.

const std = @import("std");
const source = @import("source.zig");
const diag = @import("diag.zig");
const ast = @import("ast.zig");

/// The layout of one field within an aggregate.
pub const FieldLayout = struct {
    name: []const u8,
    ty: ast.Type,
    offset: u64,
    size: u64,
};

/// The computed layout of a class or union.
pub const AggLayout = struct {
    size: u64 = 0,
    alignment: u64 = 1,
    is_union: bool = false,
    /// Fields in offset order, including those inherited from base classes and
    /// promoted from anonymous embedded unions/structs.
    fields: []const FieldLayout = &.{},

    pub fn field(l: *const AggLayout, name: []const u8) ?*const FieldLayout {
        for (l.fields) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

/// The layouts of all aggregate types in a program, plus size and alignment
/// queries for arbitrary types.
pub const Layouts = struct {
    classes: std.StringArrayHashMapUnmanaged(AggLayout) = .empty,

    /// The layout of a named class/union, if known.
    pub fn get(ls: *const Layouts, name: []const u8) ?*const AggLayout {
        return ls.classes.getPtr(name);
    }

    /// The size in bytes of a type. Unknown class types report 0.
    pub fn sizeOf(ls: *const Layouts, ty: ast.Type) u64 {
        switch (ty) {
            .named => |n| return if (ls.classes.getPtr(n)) |l| l.size else 0,
            .array => |arr| {
                const size_expr = arr.size orelse return 0;
                var count: u64 = 0;
                switch (constEvalIn(size_expr, ls)) {
                    .value => |v| if (v > 0) {
                        count = @intCast(v);
                    },
                    .err => {},
                }
                return ls.strideOf(arr.elem.*) *% count;
            },
            else => return scalarSize(ty) orelse 0,
        }
    }

    /// The alignment in bytes of a type.
    pub fn alignOf(ls: *const Layouts, ty: ast.Type) u64 {
        return switch (ty) {
            .named => |n| if (ls.classes.getPtr(n)) |l| l.alignment else 1,
            .array => |arr| ls.alignOf(arr.elem.*),
            else => alignOfScalar(ty),
        };
    }

    /// The per-element stride of ty as an array element: its size padded up to
    /// its alignment.
    pub fn strideOf(ls: *const Layouts, ty: ast.Type) u64 {
        return roundUp(ls.sizeOf(ty), ls.alignOf(ty));
    }

    /// The byte offset of field within class, if both exist.
    pub fn offsetOf(ls: *const Layouts, class: []const u8, field_name: []const u8) ?u64 {
        const l = ls.classes.getPtr(class) orelse return null;
        const f = l.field(field_name) orelse return null;
        return f.offset;
    }

    /// The byte offset of a possibly nested member path within class. Null if
    /// any class or field along the path is unknown, or if a non-final field
    /// is not itself a class or union.
    pub fn nestedOffsetOf(ls: *const Layouts, class: []const u8, path: []const []const u8) ?u64 {
        var current = class;
        var total: u64 = 0;
        for (path, 0..) |field_name, i| {
            const l = ls.classes.getPtr(current) orelse return null;
            const f = l.field(field_name) orelse return null;
            total +%= f.offset;
            if (i + 1 < path.len) {
                switch (f.ty) {
                    .named => |n| current = n,
                    else => return null,
                }
            }
        }
        return total;
    }
};

// ---- the layout pass ----

/// A class definition with its definition position, for base-class and cycle
/// errors.
const ClassDefRef = struct {
    def: *const ast.ClassDef,
    pos: source.Pos,
    file: u32,
};

/// Computes the in-memory layout of every class and union in prog and stores it
/// on prog.layouts. Layout errors (a cyclic by-value type, a non-constant or
/// negative field array size) are recorded as .layout diagnostics and
/// error.CompileFailed is returned; the table is still populated with
/// best-effort sizes, so callers can keep going.
pub fn compute(arena: std.mem.Allocator, diags: *diag.Diagnostics, prog: *ast.Program) diag.Error!void {
    const out = try arena.create(Layouts);
    out.* = .{};
    var l = Layouter{ .arena = arena, .diags = diags, .out = out };
    for (prog.items) |item| {
        switch (item.kind) {
            .class_def => |c| {
                // On a duplicate definition, keep the first; sema already
                // reports it.
                if (!l.defs.contains(c.name)) {
                    try l.defs.put(arena, c.name, .{ .def = c, .pos = item.span.pos, .file = item.span.file });
                }
            },
            else => {},
        }
    }
    for (l.defs.keys()) |name| {
        _ = try l.classLayout(name);
    }
    prog.layouts = out;
    if (l.had_error) return error.CompileFailed;
}

/// The layout pass state. Populates the layout table and reports errors through
/// the shared diagnostics.
const Layouter = struct {
    arena: std.mem.Allocator,
    diags: *diag.Diagnostics,
    defs: std.StringArrayHashMapUnmanaged(ClassDefRef) = .empty,
    out: *Layouts,
    /// Classes currently being laid out, for cycle detection.
    visiting: std.StringArrayHashMapUnmanaged(void) = .empty,
    had_error: bool = false,

    const SizeAlign = struct { size: u64, alignment: u64 };

    fn err(l: *Layouter, file: u32, pos: source.Pos, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        l.had_error = true;
        try l.diags.add(.@"error", .layout, file, pos, fmt, args);
    }

    /// Lays out a class and memoises the result, returning (size, align).
    fn classLayout(l: *Layouter, name: []const u8) error{OutOfMemory}!SizeAlign {
        if (l.out.classes.getPtr(name)) |lay| return .{ .size = lay.size, .alignment = lay.alignment };
        const ref = l.defs.get(name) orelse {
            // Unknown type. Sema reports this, so treat it as zero-size here.
            return .{ .size = 0, .alignment = 1 };
        };
        if (l.visiting.contains(name)) {
            try l.err(ref.file, ref.pos, "type `{s}` has an infinite size (cycle through itself)", .{name});
            return .{ .size = 0, .alignment = 1 };
        }
        try l.visiting.put(l.arena, name, {});
        const def = ref.def;

        var fields: std.ArrayList(FieldLayout) = .empty;
        var offset: u64 = 0;
        var max_align: u64 = 1;

        // A base class is a subobject at offset 0; its fields are inherited.
        if (def.base.len > 0) {
            const b = try l.classLayout(def.base);
            if (b.alignment > max_align) max_align = b.alignment;
            if (l.out.classes.getPtr(def.base)) |bl| {
                try fields.appendSlice(l.arena, bl.fields);
            }
            offset = b.size;
        }

        for (def.fields) |f| {
            const a = try l.typeAlign(f.ty);
            const s = try l.typeSize(f.ty);
            if (a > max_align) max_align = a;
            var field_offset: u64 = 0;
            if (!def.is_union) field_offset = roundUp(offset, a);
            try fields.append(l.arena, .{ .name = f.name, .ty = f.ty, .offset = field_offset, .size = s });
            // An anonymous embedded union promotes its members into this class
            // at the union's offset, so obj.member resolves correctly.
            if (ast.isAnonField(f.name)) {
                switch (f.ty) {
                    .named => |inner| {
                        _ = try l.classLayout(inner);
                        if (l.out.classes.getPtr(inner)) |inner_layout| {
                            for (inner_layout.fields) |mf| {
                                try fields.append(l.arena, .{
                                    .name = mf.name,
                                    .ty = mf.ty,
                                    .offset = field_offset +% mf.offset,
                                    .size = mf.size,
                                });
                            }
                        }
                    },
                    else => {},
                }
            }
            if (def.is_union) {
                if (s > offset) offset = s;
            } else {
                offset = field_offset +% s;
            }
        }

        const size = roundUp(offset, max_align);
        _ = l.visiting.swapRemove(name);
        try l.out.classes.put(l.arena, name, .{
            .size = size,
            .alignment = max_align,
            .is_union = def.is_union,
            .fields = try fields.toOwnedSlice(l.arena),
        });
        return .{ .size = size, .alignment = max_align };
    }

    fn typeAlign(l: *Layouter, ty: ast.Type) error{OutOfMemory}!u64 {
        return switch (ty) {
            .named => |n| (try l.classLayout(n)).alignment,
            .array => |arr| try l.typeAlign(arr.elem.*),
            else => alignOfScalar(ty),
        };
    }

    fn typeSize(l: *Layouter, ty: ast.Type) error{OutOfMemory}!u64 {
        switch (ty) {
            .named => |n| return (try l.classLayout(n)).size,
            .array => |arr| {
                const size_expr = arr.size orelse return 0;
                const stride = roundUp(try l.typeSize(arr.elem.*), try l.typeAlign(arr.elem.*));
                // A sizeof(aggregate) in the dimension (e.g.
                // U8 buf[sizeof(Other)]) is a compile-time constant, but
                // folding it needs that aggregate's size, so force each
                // referenced class first, then fold against the layouts so far.
                var referenced: std.ArrayList([]const u8) = .empty;
                try collectSizeofAggregates(l.arena, size_expr, &referenced);
                for (referenced.items) |rn| {
                    _ = try l.classLayout(rn);
                }
                switch (constEvalIn(size_expr, l.out)) {
                    .err => |e| {
                        try l.err(e.file, e.pos, "{s}", .{e.message});
                        return 0;
                    },
                    .value => |v| {
                        if (v < 0) {
                            try l.err(size_expr.span.file, size_expr.span.pos, "array size cannot be negative", .{});
                            return 0;
                        }
                        return stride *% @as(u64, @intCast(v));
                    },
                }
            },
            else => return scalarSize(ty) orelse 0,
        }
    }
};

/// Collects the base named aggregate of every sizeof(non-scalar) in e, so the
/// layout pass can force those classes before folding e as an array dimension.
/// Pointers are skipped (a pointer's size never depends on its pointee).
fn collectSizeofAggregates(arena: std.mem.Allocator, e: *const ast.Expr, out: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
    switch (e.kind) {
        .sizeof => |k| {
            if (k.ty) |t| {
                if (scalarSize(t) == null) {
                    if (baseNamedType(t)) |n| try out.append(arena, n);
                }
            }
        },
        .unary => |k| try collectSizeofAggregates(arena, k.expr, out),
        .cast => |k| try collectSizeofAggregates(arena, k.expr, out),
        .binary => |k| {
            try collectSizeofAggregates(arena, k.lhs, out);
            try collectSizeofAggregates(arena, k.rhs, out);
        },
        else => {},
    }
}

/// The base named type of t, peeling only array wrappers (Box[3] -> Box). A
/// pointer stops the peel: its size is fixed regardless of the pointee.
fn baseNamedType(t: ast.Type) ?[]const u8 {
    return switch (t) {
        .named => |n| n,
        .array => |arr| baseNamedType(arr.elem.*),
        else => null,
    };
}

// ---- scalar sizes & alignment (the layout rule lives here) ----

/// The byte size of a non-aggregate type, or null for class/array types.
pub fn scalarSize(ty: ast.Type) ?u64 {
    return switch (ty) {
        .prim => |p| switch (p) {
            .U0, .I0 => 0,
            .I8, .U8 => 1,
            .I16, .U16 => 2,
            .I32, .U32 => 4,
            .I64, .U64, .F64 => 8,
        },
        .ptr, .func_ptr => 8,
        else => null, // .named, .array
    };
}

/// The alignment of a scalar type (natural alignment: equal to its size,
/// minimum 1). Aggregates derive theirs from their fields.
fn alignOfScalar(ty: ast.Type) u64 {
    if (scalarSize(ty)) |s| {
        if (s >= 1) return s;
    }
    return 1;
}

pub fn roundUp(value: u64, alignment: u64) u64 {
    if (alignment <= 1) return value;
    return ((value +% alignment - 1) / alignment) *% alignment;
}

// ---- constant expression evaluation (for field array sizes) ----

/// A constant-folding failure: the message and the position of the
/// subexpression that couldn't be folded.
pub const EvalError = struct {
    message: []const u8,
    pos: source.Pos,
    file: u32,
};

pub const EvalResult = union(enum) {
    value: i64,
    err: EvalError,
};

/// Evaluates a compile-time constant integer expression: literals; arithmetic,
/// bitwise, comparison, and logical operators; integer casts; and sizeof of a
/// scalar type. Anything else (a variable, a call, sizeof of an aggregate) is
/// rejected.
pub fn constEval(e: *const ast.Expr) EvalResult {
    return constEvalIn(e, null);
}

/// Like constEval, but with optional layout context. With layouts supplied,
/// sizeof(aggregate) folds to its computed size; without it, sizeof of a
/// non-scalar still errors.
pub fn constEvalIn(e: *const ast.Expr, layouts: ?*const Layouts) EvalResult {
    switch (e.kind) {
        .int_lit => |v| return .{ .value = v },
        .char_lit => |v| return .{ .value = v },
        .unary => |k| {
            const x = switch (constEvalIn(k.expr, layouts)) {
                .value => |v| v,
                .err => |er| return .{ .err = er },
            };
            return switch (k.op) {
                .neg => .{ .value = 0 -% x },
                .pos => .{ .value = x },
                .not => .{ .value = b2i(x == 0) },
                .bit_not => .{ .value = ~x },
                else => evalErr(e, "array size must be a constant integer expression"),
            };
        },
        .binary => |k| {
            const a = switch (constEvalIn(k.lhs, layouts)) {
                .value => |v| v,
                .err => |er| return .{ .err = er },
            };
            const b = switch (constEvalIn(k.rhs, layouts)) {
                .value => |v| v,
                .err => |er| return .{ .err = er },
            };
            return switch (k.op) {
                .add => .{ .value = a +% b },
                .sub => .{ .value = a -% b },
                .mul => .{ .value = a *% b },
                .div => if (b == 0)
                    evalErr(e, "division by zero in a constant expression")
                else if (b == -1)
                    .{ .value = 0 -% a } // INT_MIN/-1 wraps like Go, no trap
                else
                    .{ .value = @divTrunc(a, b) },
                .mod => if (b == 0)
                    evalErr(e, "division by zero in a constant expression")
                else if (b == -1)
                    .{ .value = 0 }
                else
                    .{ .value = @rem(a, b) },
                .bit_and => .{ .value = a & b },
                .bit_or => .{ .value = a | b },
                .bit_xor => .{ .value = a ^ b },
                .shl => .{ .value = shiftLeft(a, b) },
                .shr => .{ .value = shiftRight(a, b) },
                .eq => .{ .value = b2i(a == b) },
                .ne => .{ .value = b2i(a != b) },
                .lt => .{ .value = b2i(a < b) },
                .gt => .{ .value = b2i(a > b) },
                .le => .{ .value = b2i(a <= b) },
                .ge => .{ .value = b2i(a >= b) },
                .log_and => .{ .value = b2i(a != 0 and b != 0) },
                .log_or => .{ .value = b2i(a != 0 or b != 0) },
                else => evalErr(e, "array size must be a constant integer expression"),
            };
        },
        .cast => |k| {
            // An integer cast is a no-op for constant folding.
            return constEvalIn(k.expr, layouts);
        },
        .sizeof => |k| {
            // sizeof(scalar) always folds; sizeof(aggregate) folds only with
            // layout context. sizeof(expr) needs type inference the layout
            // pass doesn't run.
            if (k.ty) |t| {
                if (scalarSize(t)) |s| return .{ .value = @intCast(s) };
                if (layouts) |ls| return .{ .value = @bitCast(ls.sizeOf(t)) };
                return evalErr(e, "sizeof of a non-scalar type is not allowed here");
            }
            return evalErr(e, "array size must be a constant integer expression");
        },
        else => return evalErr(e, "array size must be a constant integer expression"),
    }
}

fn evalErr(e: *const ast.Expr, msg: []const u8) EvalResult {
    return .{ .err = .{ .message = msg, .pos = e.span.pos, .file = e.span.file } };
}

fn b2i(b: bool) i64 {
    return if (b) 1 else 0;
}

/// Go's `a << uint32(b)` semantics: the count is b truncated to 32 bits, and
/// a count >= 64 shifts every bit out.
fn shiftLeft(a: i64, b: i64) i64 {
    const s: u32 = @truncate(@as(u64, @bitCast(b)));
    if (s >= 64) return 0;
    return @bitCast(@as(u64, @bitCast(a)) << @intCast(s));
}

/// Go's `a >> uint32(b)` semantics: arithmetic shift, sign-filled for counts
/// >= 64.
fn shiftRight(a: i64, b: i64) i64 {
    const s: u32 = @truncate(@as(u64, @bitCast(b)));
    if (s >= 64) return if (a < 0) -1 else 0;
    return a >> @intCast(s);
}
