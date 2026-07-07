// Math.HC — floating-point math primitives. #include <Math.HC>.
//
// Each function lowers to the matching LLVM math intrinsic (llvm.sqrt.f64, ...),
// which becomes a hardware instruction, constant-folds, or falls back to a libm
// call. The prototype bodies are never emitted; these are compiler intrinsics,
// like MAlloc in <Mem.HC>. F64 only.
#ifndef __STD_MATH_HC
#define __STD_MATH_HC

public F64 Sqrt(F64 x);              // square root
public F64 Pow(F64 base, F64 e);     // base raised to e
public F64 Sin(F64 x);               // sine (radians)
public F64 Cos(F64 x);               // cosine (radians)
public F64 Exp(F64 x);               // e**x
public F64 Exp2(F64 x);              // 2**x
public F64 Log(F64 x);               // natural log
public F64 Log2(F64 x);              // base-2 log
public F64 Log10(F64 x);             // base-10 log
public F64 Floor(F64 x);             // round toward -inf
public F64 Ceil(F64 x);              // round toward +inf
public F64 Trunc(F64 x);             // round toward zero
public F64 Round(F64 x);             // round half away from zero
public F64 Abs(F64 x);               // absolute value

#endif // __STD_MATH_HC
