// a two-dimensional array.
I64 grid[2][3];
I64 i, j;
for (i = 0; i < 2; i++)
  for (j = 0; j < 3; j++)
    grid[i][j] = i * 10 + j;
for (i = 0; i < 2; i++) {
  for (j = 0; j < 3; j++)
    "%d ", grid[i][j];
  "\n";
}
