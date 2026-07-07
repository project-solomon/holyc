// Standard library <Math.HC>: compiler math primitives (each call lowers to an
// LLVM math intrinsic), resolved from HCC_ROOT/std.
#include <Math.HC>

"sqrt=%.3f\n", Sqrt(2.0);
"pow=%.1f\n", Pow(2.0, 10.0);
"exp=%.3f\n", Exp(0.0);
"exp2=%.1f\n", Exp2(10.0);
"log=%.3f\n", Log(1.0);
"log2=%.1f\n", Log2(8.0);
"log10=%.1f\n", Log10(1000.0);
"floor=%.1f\n", Floor(3.7);
"ceil=%.1f\n", Ceil(3.2);
"trunc=%.1f\n", Trunc(3.7);
"round=%.1f\n", Round(2.5);
"abs=%.1f\n", Abs(-4.5);
