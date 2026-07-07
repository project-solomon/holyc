// nested try/catch; the inner handler rethrows a new value to the outer one.
try {
  try {
    throw(1);
  } catch {
    "inner %d\n", Fs->except_ch;
    throw(2);
  }
} catch {
  "outer %d\n", Fs->except_ch;
}
"done\n";
