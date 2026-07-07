// switch with HolyC range cases and a default.
U0 Grade(I64 score)
{
  switch (score) {
    case 90 ... 100:
      "A\n";
      break;
    case 80 ... 89:
      "B\n";
      break;
    case 70 ... 79:
      "C\n";
      break;
    default:
      "F\n";
  }
}

Grade(95);
Grade(83);
Grade(71);
Grade(50);
