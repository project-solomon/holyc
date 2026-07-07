// Inline asm referencing a HolyC local variable by name. The variable is named in
// the asm, so it is forced to a frame slot, and each `n` operand resolves to an
// SP-relative memory reference to that slot (amd64 reads/writes it directly; arm64
// loads/stores it through a register, as AArch64 requires).
//
// Both blocks are given unguarded; the backend assembles only the one matching the
// build target (arch-pairing), so no #ifdef is needed.

I64 SevenX(I64 v)
{
  I64 n = v;
  asm {
    MOV RAX, n
    IMUL RAX, 7
    MOV n, RAX
  }
  asm arm64 {
    LDR X9, n
    MOV X10, 7
    MUL X9, X9, X10
    STR X9, n
  }
  asm riscv64 {
    LD a1, n
    LI a2, 7
    MUL a1, a1, a2
    SD a1, n
  }
  asm ppc64le {
    LD R5, n
    MULLI R5, R5, 7
    STD R5, n
  }
  asm s390x {
    LG R1, n
    MGHI R1, 7
    STG R1, n
  }
  return n;
}

"%d\n", SevenX(6);
"%d\n", SevenX(3);
