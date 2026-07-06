// Parenthesis-less function calls: a function name used as a value is a zero-argument
// call (HolyC). It calls in statement position, on the right of an assignment, and as
// a sub-expression operand. The function's address is taken only with &Func (covered
// by funcptr.HC).

I64 Five()
{
  return 5;
}

U0 Hello()
{
  "hi\n";
}

Hello;            // statement: Hello()
I64 x = Five;     // assignment RHS: Five()
"%d\n", x;
"%d\n", Five + 1; // sub-expression operand: Five() + 1
