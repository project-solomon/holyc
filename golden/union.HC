// a union aliases the same storage (little-endian on arm64).
union U { U64 word; U8 bytes[8]; };
U u;
u.word = 0;
u.bytes[0] = 0x11;
u.bytes[1] = 0x22;
"%x\n", u.word; // low byte first
