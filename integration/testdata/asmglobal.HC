// Accessing a global from inline asm. A global can't be named directly in the asm
// (it has no frame slot), so the idiom is to take its address into a register-pinned
// pointer and dereference that register — which works on both architectures without
// any PC-relative addressing in the asm itself.

#ifdef __amd64__
#define PIN R15
#elif defined(__ppc64le__)
#define PIN R14
#elif defined(__s390x__)
#define PIN R6
#else
#define PIN X19
#endif

I64 g = 0;

U0 SetG(I64 v)
{
  I64 reg PIN *p = &g;
  asm {
    MOV RAX, v
    MOV [R15], RAX
  }
  asm arm64 {
    LDR X9, v
    STR X9, [X19]
  }
  asm riscv64 {
    LD a1, v
    SD a1, [X19]
  }
  asm ppc64le {
    LD R5, v
    STD R5, [R14]
  }
  asm s390x {
    LG R1, v
    STG R1, [R6]
  }
}

SetG(42);
"%d\n", g;
SetG(777);
"%d\n", g;
