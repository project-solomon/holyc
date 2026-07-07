// Top-level command line. At the top level (inside the synthesized @entry, with no
// enclosing function) `argc`/`argv` are the program's command line. The conformance
// harness runs each binary with no extra arguments, so argc is 1 (just the program
// name) and argv is a non-null, NULL-terminated vector. argv[0] (the binary's path)
// is not printed because it varies between runs.

"argc=%d\n", argc;
if (argv != NULL)
  "argv non-null\n";
if (argv[argc] == NULL)
  "argv null-terminated\n";
