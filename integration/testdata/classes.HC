// A class with members, passed by reference to a helper.
class Point {
  I64 x, y;
};

I64 NormSq(Point *p)
{
  return p->x * p->x + p->y * p->y;
}

Point p;
p.x = 3;
p.y = 4;
"%d\n", NormSq(&p); // 3*3 + 4*4
