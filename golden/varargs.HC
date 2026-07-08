// Variadic functions. Inside a function declared with `...`, the implicit `argc` is
// the number of variadic arguments and `argv` is an I64* to them (argv[i] is the i-th
// vararg) — the same convention the core's Print uses. Works with and without a
// leading named parameter.

I64 Total(...)
{
  I64 s = 0, i;
  for (i = 0; i < argc; i++)
    s += argv[i];
  return s;
}

I64 Count(...)
{
  return argc;
}

I64 SumFrom(I64 base, ...)
{
  I64 s = base, i;
  for (i = 0; i < argc; i++)
    s += argv[i];
  return s;
}

"%d\n", Total(10, 20, 30);
"%d\n", Total();
"%d\n", Count(1, 2, 3, 4, 5);
"%d\n", Count();
"%d\n", SumFrom(100, 1, 2, 3);
