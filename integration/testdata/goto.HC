// goto drives a manual loop.
I64 i = 0;
loop:
"%d ", i;
i++;
if (i < 5)
  goto loop;
"\n";
