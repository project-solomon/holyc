// the Fibonacci sequence, computed iteratively.
I64 a = 0, b = 1, i, t;
for (i = 0; i < 10; i++) {
  "%d ", a;
  t = a + b;
  a = b;
  b = t;
}
"\n";
