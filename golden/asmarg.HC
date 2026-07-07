// Accessing a function argument from inline asm. This compiler passes arguments in
// registers (not on the stack), so TempleOS's SF_ARGn frame symbols have no direct
// analogue; the faithful equivalent is naming the parameter, which forces it to a
// frame slot the asm can read and write.
//
// Both an amd64 and an arm64 block are given unguarded: the backend assembles only
// the one matching the build target and skips the other (the arch-pairing rule), so
// no #ifdef is needed.

I64 Dbl(I64 a)
{
  asm {
    MOV RAX, a
    ADD RAX, RAX
    MOV a, RAX
  }
  asm arm64 {
    LDR X9, a
    ADD X9, X9, X9
    STR X9, a
  }
  asm riscv64 {
    LD a1, a
    ADD a1, a1, a1
    SD a1, a
  }
  asm ppc64le {
    LD R5, a
    ADD R5, R5, R5
    STD R5, a
  }
  asm s390x {
    LG R1, a
    AGR R1, R1
    STG R1, a
  }
  return a;
}

"%d\n", Dbl(21);
"%d\n", Dbl(50);
