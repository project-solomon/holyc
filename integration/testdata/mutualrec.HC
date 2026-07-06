// mutual recursion (with a forward prototype, since HolyC is single-pass).
I64 IsEven(I64 n);
I64 IsOdd(I64 n)  { if (n == 0) return 0; return IsEven(n - 1); }
I64 IsEven(I64 n) { if (n == 0) return 1; return IsOdd(n - 1); }

"%d %d\n", IsEven(10), IsOdd(10);
"%d %d\n", IsEven(7), IsOdd(7);
