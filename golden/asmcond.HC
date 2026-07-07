// Conditional branches in inline asm: clamp a value to a maximum of 100 using a
// compare and a forward conditional branch (amd64 cmp/jl; arm64 cmp/b.lt).

#ifdef __amd64__
#define PIN R15
#elif defined(__ppc64le__)
#define PIN R14
#elif defined(__s390x__)
#define PIN R6
#else
#define PIN X19
#endif

I64 Cap100(I64 a)
{
  I64 reg PIN r = a;
  asm {
    MOV RAX, 100
    CMP R15, RAX
    JL &SKIP
    MOV R15, RAX
  SKIP::
  }
  asm arm64 {
    MOV X9, 100
    CMP X19, X9
    B.LT &SKIP
    MOV X19, X9
  SKIP::
  }
  asm riscv64 {
    LI a1, 100
    BLT X19, a1, &SKIP
    MV X19, a1
  SKIP::
  }
  asm ppc64le {
    LI R5, 100
    CMPD R14, R5
    BLT &SKIP
    MR R14, R5
  SKIP::
  }
  asm s390x {
    LGHI R1, 100
    CGR R6, R1
    JL &SKIP
    LGR R6, R1
  SKIP::
  }
  return r;
}

"%d\n", Cap100(7);
"%d\n", Cap100(250);
