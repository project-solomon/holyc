// Recursive functions: factorial and Fibonacci.
I64 Fact(I64 n)
{
  if (n <= 1)
    return 1;
  return n * Fact(n - 1);
}

I64 Fib(I64 n)
{
  if (n < 2)
    return n;
  return Fib(n - 1) + Fib(n - 2);
}

"%d %d\n", Fact(5), Fact(10);
"%d\n", Fib(10);
