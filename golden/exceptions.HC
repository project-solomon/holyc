// try/catch/throw: the thrown value is read from Fs->except_ch in the handler.
U0 Risky(I64 n)
{
  if (n < 0)
    throw(n);
  "ok %d\n", n;
}

try {
  Risky(5);
  Risky(-3);
  Risky(99); // not reached — the throw above jumps to catch
} catch {
  "caught %d\n", Fs->except_ch;
}
"done\n";
