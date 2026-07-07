// Multiply a runtime value by small constants (3, 5, 7, 9) — exercises the
// C = 2^k ± 1 → (x<<k) ± x strength reduction, including negatives.
I64 i;
for (i = -3; i <= 3; i++)
  "%d %d %d %d\n", i * 3, i * 5, i * 7, i * 9;
