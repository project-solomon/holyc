// Signed divide by powers of two, rounding toward zero across the sign boundary.
// The loop variable is a runtime value, so the strength reduction (not constant
// folding) is what runs — and the authored golden, independent of the oracle,
// is what catches a wrong rewrite (oracle and native both run the rewritten IR).
I64 i;
for (i = -5; i <= 5; i++)
  "%d %d %d\n", i, i / 2, i / 4;
