// count primes below 400000 by trial division: integer div/mod in a hot loop.
#include <stdio.h>

long long IsPrime(long long n)
{
  if (n < 2)
    return 0;
  for (long long d = 2; d * d <= n; d++)
    if (n % d == 0)
      return 0;
  return 1;
}

int main(void)
{
  long long count = 0;
  for (long long i = 2; i < 400000; i++)
    if (IsPrime(i))
      count++;
  printf("%lld\n", count);
  return 0;
}
