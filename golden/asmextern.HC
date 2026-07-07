// A standalone asm routine bound to a typed HolyC name with `_extern`, then called
// like an ordinary function. The routine follows the backend calling convention
// (amd64: arg in RDI, return in RAX; arm64: arg in X0, return in X0).
//
// Both an amd64 and an arm64 definition of the TRIPLE label are given unguarded; the
// backend assembles only the block matching the build target into the .text region
// the `_extern` resolves to, so no #ifdef is needed.

asm {
TRIPLE::
  MOV RAX, RDI
  IMUL RAX, 3
  RET
}

asm arm64 {
TRIPLE::
  MOV X1, 3
  MUL X0, X0, X1
  RET
}

asm riscv64 {
TRIPLE::
  LI a1, 3
  MUL a0, a0, a1
  RET
}

asm ppc64le {
TRIPLE::
  MULLI R3, R3, 3
  BLR
}

asm s390x {
TRIPLE::
  MGHI R2, 3
  BR R14
}

_extern TRIPLE I64 Triple(I64 x);

"%d\n", Triple(14);
"%d\n", Triple(100);
