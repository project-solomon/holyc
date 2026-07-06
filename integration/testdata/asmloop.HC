// An inline-asm loop with intra-block labels and branches, summing 1..v into a
// register-pinned accumulator. Exercises label resolution and branch-displacement
// patching in both assemblers (amd64 rel32 jcc/jmp; arm64 imm19 cbz / imm26 b).
//
// Only the pinned register *name* is arch-specific (needs a #define); the asm blocks
// are unguarded — the backend assembles the one matching the build target and skips
// the other.

#ifdef __amd64__
#define PINACC R15
#define PINCTR R14
#endif
#ifdef __arm64__
#define PINACC X19
#define PINCTR X20
#endif
#ifdef __riscv64__
#define PINACC s2
#define PINCTR s3
#endif
#ifdef __ppc64le__
#define PINACC R14
#define PINCTR R15
#endif
#ifdef __s390x__
#define PINACC R6
#define PINCTR R7
#endif

I64 Sum(I64 v)
{
  I64 reg PINACC acc = 0;
  I64 reg PINCTR i = v;
  asm {
  LOOP::
    TEST R14, R14
    JE &DONE
    ADD R15, R14
    DEC R14
    JMP &LOOP
  DONE::
  }
  asm arm64 {
  LOOP::
    CBZ X20, &DONE
    ADD X19, X19, X20
    SUB X20, X20, 1
    B &LOOP
  DONE::
  }
  asm riscv64 {
  LOOP::
    BEQZ s3, &DONE
    ADD s2, s2, s3
    ADDI s3, s3, -1
    J &LOOP
  DONE::
  }
  asm ppc64le {
  LOOP::
    CMPDI R15, 0
    BEQ &DONE
    ADD R14, R14, R15
    ADDI R15, R15, -1
    B &LOOP
  DONE::
  }
  asm s390x {
  LOOP::
    CGHI R7, 0
    JE &DONE
    AGR R6, R7
    AGHI R7, -1
    J &LOOP
  DONE::
  }
  return acc;
}

"%d\n", Sum(5);
"%d\n", Sum(10);
"%d\n", Sum(100);
