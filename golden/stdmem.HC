// Standard library <Mem.HC>: byte-buffer utilities, resolved from HCC_ROOT/std.
#include <Mem.HC>

U8 a[8], b[8];
MemSet(a, 'A', 8);
MemCpy(b, a, 8);
"cmp_eq=%d\n", MemCmp(a, b, 8);
b[3] = 'B';
"cmp_ne=%d\n", MemCmp(a, b, 8) != 0;
"a0=%c b3=%c\n", a[0], b[3];
