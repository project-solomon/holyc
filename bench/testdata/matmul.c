// 250x250 integer matrix multiply (flat arrays): mul-heavy inner loop.
#include <stdio.h>

long long A[62500];
long long B[62500];
long long R[62500];

int main(void)
{
  long long i, j, k;
  for (i = 0; i < 250; i++)
    for (j = 0; j < 250; j++) {
      A[i * 250 + j] = i + j;
      B[i * 250 + j] = i - j;
      R[i * 250 + j] = 0;
    }
  for (i = 0; i < 250; i++)
    for (k = 0; k < 250; k++)
      for (j = 0; j < 250; j++)
        R[i * 250 + j] += A[i * 250 + k] * B[k * 250 + j];
  long long trace = 0;
  for (i = 0; i < 250; i++)
    trace += R[i * 250 + i];
  printf("%lld\n", trace);
  return 0;
}
