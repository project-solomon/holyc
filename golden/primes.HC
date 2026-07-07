// primes below 30 by trial division.
I64 IsPrime(I64 n)
{
  if (n < 2)
    return 0;
  I64 d;
  for (d = 2; d * d <= n; d++)
    if (n % d == 0)
      return 0;
  return 1;
}

I64 i;
for (i = 2; i < 30; i++)
  if (IsPrime(i))
    "%d ", i;
"\n";
