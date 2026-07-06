// 250x250 integer matrix multiply (flat arrays): mul-heavy inner loop.
I64 A[62500];
I64 B[62500];
I64 R[62500];
I64 i, j, k;
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
I64 trace = 0;
for (i = 0; i < 250; i++)
  trace += R[i * 250 + i];
"%d\n", trace;
