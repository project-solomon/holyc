// Inline asm spliced into a function, operating on a `reg <REG>` variable through its
// pinned register. The variable lives in the named register for the whole function
// (Phase 1), the inline asm reads/writes that register, and the backend withholds it
// from the allocator so nothing else is clobbered. The register name is arch-specific,
// so the target macros pick a callee-saved register and the matching asm block.

#ifdef __amd64__
#define PIN R15
#elif defined(__ppc64le__)
#define PIN R14
#elif defined(__s390x__)
#define PIN R6
#else
#define PIN X19
#endif

I64 Compute(I64 seed)
{
  I64 reg PIN acc = seed;
  asm {
    ADD R15, 10
    IMUL R15, 2
  }
  asm arm64 {
    ADD X19, X19, 10
    ADD X19, X19, X19
  }
  asm riscv64 {
    ADDI X19, X19, 10
    ADD X19, X19, X19
  }
  asm ppc64le {
    ADDI R14, R14, 10
    ADD R14, R14, R14
  }
  asm s390x {
    AGHI R6, 10
    AGR R6, R6
  }
  return acc;
}

"%d\n", Compute(1);
"%d\n", Compute(5);
