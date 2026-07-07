// `reg <REG>` register pinning and `noreg`. The pinned variable lives in a named
// callee-saved register for the whole function (true physical placement): it must
// survive the call to Helper inside the loop, and reads/writes must consistently
// go to the register (if a write went to the register but a read came from the
// never-written stack slot, acc would stay 0). The register name is arch-specific,
// so the target macros pick a callee-saved register for each backend.

#ifdef __amd64__
#define PIN R15
#elif defined(__ppc64le__)
#define PIN R14
#elif defined(__s390x__)
#define PIN R6
#else
#define PIN X19
#endif

I64 Helper(I64 x)
{
  return x * 2;
}

I64 Sum(I64 n)
{
  I64 reg PIN acc = 0; // pinned to a callee-saved register
  I64 noreg i;         // forced onto the stack
  for (i = 1; i <= n; i++)
    acc += Helper(i);  // call inside the loop: acc must survive
  return acc;
}

"%d\n", Sum(5);
"%d\n", Sum(10);
