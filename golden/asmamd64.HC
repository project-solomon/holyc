// The explicit `asm amd64 { … }` architecture qualifier (a bare `asm` defaults to
// amd64; this states it). Paired with `asm arm64`; the backend assembles only the
// block matching the build target and skips the other, so no #ifdef is needed.

I64 AddSeven(I64 v)
{
  I64 n = v;
  asm amd64 {
    MOV RAX, n
    ADD RAX, 7
    MOV n, RAX
  }
  asm arm64 {
    LDR X9, n
    ADD X9, X9, 7
    STR X9, n
  }
  asm riscv64 {
    LD a1, n
    ADDI a1, a1, 7
    SD a1, n
  }
  asm ppc64le {
    LD R5, n
    ADDI R5, R5, 7
    STD R5, n
  }
  asm s390x {
    LG R1, n
    AGHI R1, 7
    STG R1, n
  }
  return n;
}

"%d\n", AddSeven(10);
"%d\n", AddSeven(35);
