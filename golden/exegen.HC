// Compile-time code generation with #exe: the block is compiled and run while
// hcc is compiling, and its stdout is spliced back in as source. The block can
// call functions declared earlier in the file, so here it runs Sq() at compile
// time to emit a lookup table the program then reads at runtime.
I64 Sq(I64 x) { return x * x; }

#exe {
  I64 i;
  "I64 squares[8] = {";
  for (i = 0; i < 8; i++) "%d,", Sq(i);
  "};\n";
}

I64 i;
for (i = 0; i < 8; i++) "%d\n", squares[i];
