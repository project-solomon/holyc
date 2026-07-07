// an array of structs.
class Pt { I64 x, y; };
Pt pts[3];
I64 i, total = 0;
for (i = 0; i < 3; i++) {
  pts[i].x = i;
  pts[i].y = i * i;
  total += pts[i].x + pts[i].y;
}
"%d\n", total; // (0+0)+(1+1)+(2+4)
