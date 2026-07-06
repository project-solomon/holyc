// Anonymous aggregate types: `class { … }` / `union { … }` written directly as a
// type, with inline instances. The compiler synthesizes a named aggregate and
// hoists it to the top level, so an anonymous type works wherever a type may
// appear: top-level instances, a local in a function, a union, and a parameter.

class { I64 x; I64 y; } a, b;
a.x = 3;
a.y = 4;
b.x = 10;
"%d\n", a.x + a.y + b.x;

I64 Area(class { I64 w; I64 h; } *r)
{
  return r->w * r->h;
}

class { I64 w; I64 h; } box;
box.w = 6;
box.h = 7;
"%d\n", Area(&box);

U0 Alias()
{
  union { I64 i; U8 b[8]; } v;
  v.i = 0;
  v.b[0] = 1;
  v.b[1] = 1;
  "%d\n", v.i;
}

Alias();
