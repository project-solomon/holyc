// numberless cases auto-number from 0.
U0 Name(I64 n)
{
  switch (n) {
    case: "zero\n"; break;
    case: "one\n"; break;
    case: "two\n"; break;
    default: "many\n";
  }
}

Name(0);
Name(2);
Name(5);
