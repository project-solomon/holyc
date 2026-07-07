// recursive fibonacci: call overhead and branching.
I64 Fib(I64 n)
{
  if (n < 2)
    return n;
  return Fib(n - 1) + Fib(n - 2);
}

"%d\n", Fib(34);
