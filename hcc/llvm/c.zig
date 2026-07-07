//! Handwritten bindings for the subset of the LLVM-C API the backend uses.
//! Linked against the system libLLVM (see build.zig's -Dllvm-prefix). Kept as
//! extern declarations rather than @cImport/translate-c: the surface is small,
//! stable, and this keeps the build free of LLVM header dependencies.
//!
//! Naming: types drop the LLVM*Ref suffix (LLVMValueRef → *Value); functions
//! keep their exact C names so they read like the LLVM-C docs.

const std = @import("std");

pub const Context = opaque {};
pub const Module = opaque {};
pub const Type = opaque {};
pub const Value = opaque {};
pub const BasicBlock = opaque {};
pub const Builder = opaque {};
pub const Target = opaque {};
pub const TargetMachine = opaque {};
pub const TargetData = opaque {};
pub const PassBuilderOptions = opaque {};
pub const Attribute = opaque {};
pub const ErrorRef = opaque {};

pub const Bool = c_int;

// ---- version ----

/// Fills in the running libLLVM's version (it links dynamically, so the version
/// is a runtime property). Used to key the build cache: a libLLVM upgrade can
/// change codegen even when hcc itself is unchanged.
pub extern fn LLVMGetVersion(major: *c_uint, minor: *c_uint, patch: *c_uint) void;

// ---- context / module / builder ----

pub extern fn LLVMContextCreate() *Context;
pub extern fn LLVMContextDispose(*Context) void;
pub extern fn LLVMModuleCreateWithNameInContext(name: [*:0]const u8, ctx: *Context) *Module;
pub extern fn LLVMDisposeModule(*Module) void;
pub extern fn LLVMPrintModuleToString(*Module) [*:0]u8;
pub extern fn LLVMDisposeMessage(msg: [*:0]u8) void;
pub extern fn LLVMSetTarget(*Module, triple: [*:0]const u8) void;
pub extern fn LLVMSetModuleDataLayout(*Module, *TargetData) void;
pub extern fn LLVMAppendModuleInlineAsm(*Module, asm_text: [*]const u8, len: usize) void;
pub extern fn LLVMCreateBuilderInContext(*Context) *Builder;
pub extern fn LLVMDisposeBuilder(*Builder) void;

// ---- types ----

pub extern fn LLVMVoidTypeInContext(*Context) *Type;
pub extern fn LLVMInt1TypeInContext(*Context) *Type;
pub extern fn LLVMInt8TypeInContext(*Context) *Type;
pub extern fn LLVMInt16TypeInContext(*Context) *Type;
pub extern fn LLVMInt32TypeInContext(*Context) *Type;
pub extern fn LLVMInt64TypeInContext(*Context) *Type;
pub extern fn LLVMDoubleTypeInContext(*Context) *Type;
pub extern fn LLVMPointerTypeInContext(*Context, address_space: c_uint) *Type;
pub extern fn LLVMArrayType2(elem: *Type, count: u64) *Type;
pub extern fn LLVMFunctionType(ret: *Type, params: ?[*]const *Type, count: c_uint, is_vararg: Bool) *Type;
pub extern fn LLVMStructTypeInContext(*Context, elems: ?[*]const *Type, count: c_uint, is_packed: Bool) *Type;
pub extern fn LLVMTypeOf(*Value) *Type;
pub extern fn LLVMGetTypeKind(*Type) TypeKind;

pub const TypeKind = enum(c_int) {
    void = 0,
    half = 1,
    float = 2,
    double = 3,
    x86_fp80 = 4,
    fp128 = 5,
    ppc_fp128 = 6,
    label = 7,
    integer = 8,
    function = 9,
    @"struct" = 10,
    array = 11,
    pointer = 12,
    vector = 13,
    metadata = 14,
    _,
};

// ---- constants & globals ----

pub extern fn LLVMConstInt(ty: *Type, value: c_ulonglong, sign_extend: Bool) *Value;
pub extern fn LLVMConstReal(ty: *Type, value: f64) *Value;
pub extern fn LLVMConstNull(ty: *Type) *Value;
pub extern fn LLVMConstPointerNull(ty: *Type) *Value;
pub extern fn LLVMConstStringInContext2(*Context, s: [*]const u8, len: usize, dont_null_terminate: Bool) *Value;
pub extern fn LLVMConstArray2(elem_ty: *Type, values: ?[*]const *Value, count: u64) *Value;
pub extern fn LLVMConstStructInContext(*Context, values: ?[*]const *Value, count: c_uint, is_packed: Bool) *Value;
pub extern fn LLVMAddGlobal(*Module, ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMGetNamedGlobal(*Module, name: [*:0]const u8) ?*Value;
pub extern fn LLVMSetInitializer(global: *Value, value: *Value) void;
pub extern fn LLVMSetGlobalConstant(global: *Value, is_const: Bool) void;
pub extern fn LLVMSetLinkage(global: *Value, linkage: Linkage) void;
pub extern fn LLVMSetUnnamedAddress(global: *Value, addr: UnnamedAddr) void;
pub extern fn LLVMSetAlignment(v: *Value, bytes: c_uint) void;
pub extern fn LLVMSetSection(global: *Value, section: [*:0]const u8) void;

pub const Linkage = enum(c_int) {
    external = 0,
    private = 9,
    internal = 8,
    _,
};

pub const UnnamedAddr = enum(c_int) {
    no = 0,
    local = 1,
    global = 2,
};

// ---- functions ----

pub extern fn LLVMAddFunction(*Module, name: [*:0]const u8, fn_ty: *Type) *Value;
pub extern fn LLVMGetNamedFunction(*Module, name: [*:0]const u8) ?*Value;
pub extern fn LLVMGetParam(func: *Value, index: c_uint) *Value;
pub extern fn LLVMSetValueName2(*Value, name: [*]const u8, len: usize) void;
pub extern fn LLVMDeleteFunction(func: *Value) void;
pub extern fn LLVMGetFirstBasicBlock(func: *Value) ?*BasicBlock;

// Attributes (returns_twice for setjmp, noreturn for longjmp/exit).
pub extern fn LLVMGetEnumAttributeKindForName(name: [*]const u8, len: usize) c_uint;
pub extern fn LLVMCreateEnumAttribute(*Context, kind: c_uint, value: u64) *Attribute;
pub extern fn LLVMAddAttributeAtIndex(func: *Value, index: AttributeIndex, attr: *Attribute) void;
pub extern fn LLVMAddCallSiteAttribute(call: *Value, index: AttributeIndex, attr: *Attribute) void;

pub const AttributeIndex = c_uint;
pub const attribute_function_index: AttributeIndex = std.math.maxInt(c_uint); // ~0U

// ---- basic blocks & builder positioning ----

pub extern fn LLVMAppendBasicBlockInContext(*Context, func: *Value, name: [*:0]const u8) *BasicBlock;
pub extern fn LLVMPositionBuilderAtEnd(*Builder, block: *BasicBlock) void;
pub extern fn LLVMPositionBuilderBefore(*Builder, instr: *Value) void;
pub extern fn LLVMGetInsertBlock(*Builder) ?*BasicBlock;
pub extern fn LLVMGetBasicBlockParent(*BasicBlock) *Value;
pub extern fn LLVMGetBasicBlockTerminator(*BasicBlock) ?*Value;
pub extern fn LLVMDeleteBasicBlock(*BasicBlock) void;
pub extern fn LLVMMoveBasicBlockAfter(*BasicBlock, move_after: *BasicBlock) void;

// ---- instructions ----

pub extern fn LLVMBuildRet(*Builder, value: *Value) *Value;
pub extern fn LLVMBuildRetVoid(*Builder) *Value;
pub extern fn LLVMBuildBr(*Builder, dest: *BasicBlock) *Value;
pub extern fn LLVMBuildCondBr(*Builder, cond: *Value, then: *BasicBlock, els: *BasicBlock) *Value;
pub extern fn LLVMBuildSwitch(*Builder, value: *Value, default: *BasicBlock, num_cases: c_uint) *Value;
pub extern fn LLVMAddCase(switch_inst: *Value, on_val: *Value, dest: *BasicBlock) void;
pub extern fn LLVMBuildUnreachable(*Builder) *Value;

pub extern fn LLVMBuildAdd(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildSub(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildMul(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildSDiv(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildUDiv(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildSRem(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildURem(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildAnd(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildOr(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildXor(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildShl(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildAShr(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildLShr(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildNeg(*Builder, value: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildNot(*Builder, value: *Value, name: [*:0]const u8) *Value;

pub extern fn LLVMBuildFAdd(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildFSub(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildFMul(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildFDiv(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildFRem(*Builder, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildFNeg(*Builder, value: *Value, name: [*:0]const u8) *Value;

pub extern fn LLVMBuildICmp(*Builder, op: IntPredicate, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildFCmp(*Builder, op: RealPredicate, lhs: *Value, rhs: *Value, name: [*:0]const u8) *Value;

pub const IntPredicate = enum(c_int) {
    eq = 32,
    ne = 33,
    ugt = 34,
    uge = 35,
    ult = 36,
    ule = 37,
    sgt = 38,
    sge = 39,
    slt = 40,
    sle = 41,
};

pub const RealPredicate = enum(c_int) {
    oeq = 1,
    ogt = 2,
    oge = 3,
    olt = 4,
    ole = 5,
    one = 6,
    une = 14,
};

pub extern fn LLVMBuildTrunc(*Builder, value: *Value, dest_ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildZExt(*Builder, value: *Value, dest_ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildSExt(*Builder, value: *Value, dest_ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildFPToSI(*Builder, value: *Value, dest_ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildFPToUI(*Builder, value: *Value, dest_ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildSIToFP(*Builder, value: *Value, dest_ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildUIToFP(*Builder, value: *Value, dest_ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildPtrToInt(*Builder, value: *Value, dest_ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildIntToPtr(*Builder, value: *Value, dest_ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildBitCast(*Builder, value: *Value, dest_ty: *Type, name: [*:0]const u8) *Value;

pub extern fn LLVMBuildAlloca(*Builder, ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildLoad2(*Builder, ty: *Type, ptr: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildStore(*Builder, value: *Value, ptr: *Value) *Value;
pub extern fn LLVMBuildGEP2(*Builder, ty: *Type, ptr: *Value, indices: [*]const *Value, num: c_uint, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildInBoundsGEP2(*Builder, ty: *Type, ptr: *Value, indices: [*]const *Value, num: c_uint, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildGlobalStringPtr(*Builder, s: [*:0]const u8, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildCall2(*Builder, fn_ty: *Type, func: *Value, args: ?[*]const *Value, num: c_uint, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildSelect(*Builder, cond: *Value, then: *Value, els: *Value, name: [*:0]const u8) *Value;
pub extern fn LLVMBuildPhi(*Builder, ty: *Type, name: [*:0]const u8) *Value;
pub extern fn LLVMAddIncoming(phi: *Value, values: [*]const *Value, blocks: [*]const *BasicBlock, count: c_uint) void;

pub extern fn LLVMBuildMemCpy(*Builder, dst: *Value, dst_align: c_uint, src: *Value, src_align: c_uint, size: *Value) *Value;
pub extern fn LLVMBuildMemSet(*Builder, ptr: *Value, val: *Value, len: *Value, alignment: c_uint) *Value;

pub extern fn LLVMBuildAtomicRMW(*Builder, op: AtomicRMWBinOp, ptr: *Value, val: *Value, ordering: AtomicOrdering, single_thread: Bool) *Value;
pub extern fn LLVMBuildAtomicCmpXchg(*Builder, ptr: *Value, cmp: *Value, new: *Value, success: AtomicOrdering, failure: AtomicOrdering, single_thread: Bool) *Value;
pub extern fn LLVMBuildExtractValue(*Builder, agg: *Value, index: c_uint, name: [*:0]const u8) *Value;
pub extern fn LLVMSetOrdering(memory_access_inst: *Value, ordering: AtomicOrdering) void;

pub const AtomicRMWBinOp = enum(c_int) {
    xchg = 0,
    add = 1,
    sub = 2,
    @"and" = 3,
    nand = 4,
    @"or" = 5,
    xor = 6,
    _,
};

pub const AtomicOrdering = enum(c_int) {
    not_atomic = 0,
    monotonic = 2,
    acquire = 4,
    release = 5,
    acq_rel = 6,
    seq_cst = 7,
};

// ---- inline asm ----

pub extern fn LLVMGetInlineAsm(
    fn_ty: *Type,
    asm_string: [*]const u8,
    asm_string_len: usize,
    constraints: [*]const u8,
    constraints_len: usize,
    has_side_effects: Bool,
    is_align_stack: Bool,
    dialect: InlineAsmDialect,
    can_throw: Bool,
) *Value;

pub const InlineAsmDialect = enum(c_int) {
    att = 0,
    intel = 1,
};

// ---- analysis ----

pub extern fn LLVMVerifyModule(*Module, action: VerifierFailureAction, out_message: *?[*:0]u8) Bool;

pub const VerifierFailureAction = enum(c_int) {
    abort_process = 0,
    print_message = 1,
    return_status = 2,
};

// ---- targets ----
// The LLVMInitializeAll* helpers are static inlines in the C headers, so the
// per-backend registration functions are declared directly; initAllTargets
// covers every architecture the hcc target model can name.

pub extern fn LLVMInitializeAArch64TargetInfo() void;
pub extern fn LLVMInitializeAArch64Target() void;
pub extern fn LLVMInitializeAArch64TargetMC() void;
pub extern fn LLVMInitializeAArch64AsmParser() void;
pub extern fn LLVMInitializeAArch64AsmPrinter() void;
pub extern fn LLVMInitializeX86TargetInfo() void;
pub extern fn LLVMInitializeX86Target() void;
pub extern fn LLVMInitializeX86TargetMC() void;
pub extern fn LLVMInitializeX86AsmParser() void;
pub extern fn LLVMInitializeX86AsmPrinter() void;
pub extern fn LLVMInitializeARMTargetInfo() void;
pub extern fn LLVMInitializeARMTarget() void;
pub extern fn LLVMInitializeARMTargetMC() void;
pub extern fn LLVMInitializeARMAsmParser() void;
pub extern fn LLVMInitializeARMAsmPrinter() void;
pub extern fn LLVMInitializeRISCVTargetInfo() void;
pub extern fn LLVMInitializeRISCVTarget() void;
pub extern fn LLVMInitializeRISCVTargetMC() void;
pub extern fn LLVMInitializeRISCVAsmParser() void;
pub extern fn LLVMInitializeRISCVAsmPrinter() void;
pub extern fn LLVMInitializePowerPCTargetInfo() void;
pub extern fn LLVMInitializePowerPCTarget() void;
pub extern fn LLVMInitializePowerPCTargetMC() void;
pub extern fn LLVMInitializePowerPCAsmParser() void;
pub extern fn LLVMInitializePowerPCAsmPrinter() void;
pub extern fn LLVMInitializeSystemZTargetInfo() void;
pub extern fn LLVMInitializeSystemZTarget() void;
pub extern fn LLVMInitializeSystemZTargetMC() void;
pub extern fn LLVMInitializeSystemZAsmParser() void;
pub extern fn LLVMInitializeSystemZAsmPrinter() void;

pub fn initAllTargets() void {
    LLVMInitializeAArch64TargetInfo();
    LLVMInitializeAArch64Target();
    LLVMInitializeAArch64TargetMC();
    LLVMInitializeAArch64AsmParser();
    LLVMInitializeAArch64AsmPrinter();
    LLVMInitializeX86TargetInfo();
    LLVMInitializeX86Target();
    LLVMInitializeX86TargetMC();
    LLVMInitializeX86AsmParser();
    LLVMInitializeX86AsmPrinter();
    LLVMInitializeARMTargetInfo();
    LLVMInitializeARMTarget();
    LLVMInitializeARMTargetMC();
    LLVMInitializeARMAsmParser();
    LLVMInitializeARMAsmPrinter();
    LLVMInitializeRISCVTargetInfo();
    LLVMInitializeRISCVTarget();
    LLVMInitializeRISCVTargetMC();
    LLVMInitializeRISCVAsmParser();
    LLVMInitializeRISCVAsmPrinter();
    LLVMInitializePowerPCTargetInfo();
    LLVMInitializePowerPCTarget();
    LLVMInitializePowerPCTargetMC();
    LLVMInitializePowerPCAsmParser();
    LLVMInitializePowerPCAsmPrinter();
    LLVMInitializeSystemZTargetInfo();
    LLVMInitializeSystemZTarget();
    LLVMInitializeSystemZTargetMC();
    LLVMInitializeSystemZAsmParser();
    LLVMInitializeSystemZAsmPrinter();
}

pub extern fn LLVMGetTargetFromTriple(triple: [*:0]const u8, out_target: **Target, out_error: *?[*:0]u8) Bool;
pub extern fn LLVMCreateTargetMachine(
    target: *Target,
    triple: [*:0]const u8,
    cpu: [*:0]const u8,
    features: [*:0]const u8,
    level: CodeGenOptLevel,
    reloc: RelocMode,
    code_model: CodeModel,
) *TargetMachine;
pub extern fn LLVMDisposeTargetMachine(*TargetMachine) void;
pub extern fn LLVMCreateTargetDataLayout(*TargetMachine) *TargetData;
pub extern fn LLVMDisposeTargetData(*TargetData) void;
pub extern fn LLVMTargetMachineEmitToFile(*TargetMachine, *Module, filename: [*:0]const u8, codegen: CodeGenFileType, out_error: *?[*:0]u8) Bool;

pub const CodeGenOptLevel = enum(c_int) {
    none = 0,
    less = 1,
    default = 2,
    aggressive = 3,
};

pub const RelocMode = enum(c_int) {
    default = 0,
    static = 1,
    pic = 2,
};

pub const CodeModel = enum(c_int) {
    default = 0,
};

pub const CodeGenFileType = enum(c_int) {
    assembly = 0,
    object = 1,
};

// ---- new pass manager ----

pub extern fn LLVMCreatePassBuilderOptions() *PassBuilderOptions;
pub extern fn LLVMDisposePassBuilderOptions(*PassBuilderOptions) void;
pub extern fn LLVMRunPasses(*Module, passes: [*:0]const u8, ?*TargetMachine, *PassBuilderOptions) ?*ErrorRef;
pub extern fn LLVMGetErrorMessage(*ErrorRef) [*:0]u8;
pub extern fn LLVMDisposeErrorMessage(msg: [*:0]u8) void;
