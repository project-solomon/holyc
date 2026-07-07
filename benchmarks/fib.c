// recursive fibonacci: call overhead and branching.
#include <stdio.h>

long long Fib(long long n)
{
  if (n < 2)
    return n;
  return Fib(n - 1) + Fib(n - 2);
}

int main(void)
{
  printf("%lld\n", Fib(34));
  return 0;
}
