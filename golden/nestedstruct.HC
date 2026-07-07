// a class whose members are themselves classes.
class Inner { I64 a, b; };
class Outer { Inner lo, hi; I64 tag; };

Outer o;
o.lo.a = 1; o.lo.b = 2;
o.hi.a = 3; o.hi.b = 4;
o.tag = 99;
"%d %d %d %d %d\n", o.lo.a, o.lo.b, o.hi.a, o.hi.b, o.tag;
