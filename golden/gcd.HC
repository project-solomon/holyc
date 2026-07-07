// greatest common divisor (Euclid).
I64 Gcd(I64 a, I64 b)
{
  while (b != 0) {
    I64 t = b;
    b = a % b;
    a = t;
  }
  return a;
}

"%d\n", Gcd(48, 36);  // 12
"%d\n", Gcd(17, 5);   // 1
"%d\n", Gcd(100, 80); // 20
