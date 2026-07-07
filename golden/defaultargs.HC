// default arguments fill in omitted trailing parameters.
I64 Box(I64 w = 2, I64 h = 3) { return w * h; }
"%d\n", Box();     // 2*3
"%d\n", Box(5);    // 5*3
"%d\n", Box(5, 5); // 5*5
