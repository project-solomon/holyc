// bubble sort a 5000-element pseudo-random array: branchy memory traffic.
#include <stdio.h>

long long a[5000];

int main(void)
{
  long long i, j, t;
  long long seed = 1;
  for (i = 0; i < 5000; i++) {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    a[i] = seed;
  }
  for (i = 0; i < 5000; i++)
    for (j = 0; j < 4999 - i; j++)
      if (a[j] > a[j + 1]) {
        t = a[j];
        a[j] = a[j + 1];
        a[j + 1] = t;
      }
  long long sum = 0;
  for (i = 0; i < 5000; i++)
    sum += a[i] * i;
  printf("%lld\n", sum);
  return 0;
}
