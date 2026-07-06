// Arrays and pointers: build a string in a buffer, sum an int array.
U8 buf[4];
buf[0] = 'a';
buf[1] = 'b';
buf[2] = 'c';
buf[3] = 0;
"%s\n", buf;

I64 arr[5], i, sum = 0;
for (i = 0; i < 5; i++)
  arr[i] = i * i;
for (i = 0; i < 5; i++)
  sum += arr[i];
"%d\n", sum; // 0+1+4+9+16
