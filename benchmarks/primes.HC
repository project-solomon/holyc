// count primes below 400000 by trial division: integer div/mod in a hot loop.
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
I64 count = 0;
for (i = 2; i < 400000; i++)
  if (IsPrime(i))
    count++;
"%d\n", count;
