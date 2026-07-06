// A loopback TCP echo server and its client in one process: main binds,
// listens, accepts, and echoes; a Thread()-spawned client connects, sends,
// and reads the echo back. All printing happens on the main thread so the
// golden's ordering is deterministic.

#define PORT 43217

U8 reply[64];
I64 reply_n = 0;

U0 FillAddr(U8 *sa, I64 port)
{
  I64 i;
  for (i = 0; i < 16; i++)
    sa[i] = 0;
#ifdef __APPLE__
  sa[0] = 16; // sin_len
  sa[1] = 2;  // sin_family = AF_INET
#else
  sa[0] = 2;  // sin_family = AF_INET (little-endian U16)
#endif
  sa[2] = port >> 8; // sin_port, big-endian
  sa[3] = port & 0xFF;
  sa[4] = 127; // 127.0.0.1
  sa[7] = 1;
}

I64 Client(I64 port)
{
  U8 sa[16];
  FillAddr(sa, port);
  I64 fd = Socket(2, 1, 0); // AF_INET, SOCK_STREAM
  if (fd < 0)
    return -1;
  if (Connect(fd, sa, 16) < 0)
    return -2;
  Write(fd, "ping over tcp", 13);
  Shutdown(fd, 1); // SHUT_WR: that's all from us
  reply_n = Read(fd, reply, 64);
  Close(fd);
  return 0;
}

U8 sa[16];
FillAddr(sa, PORT);
I64 sfd = Socket(2, 1, 0);
I64 one = 1;
#ifdef __APPLE__
SetSockOpt(sfd, 0xFFFF, 4, &one, 4); // SOL_SOCKET, SO_REUSEADDR
#else
SetSockOpt(sfd, 1, 2, &one, 4);
#endif
"bind ok: %d\n", Bind(sfd, sa, 16) == 0;
"listen ok: %d\n", Listen(sfd, 4) == 0;

I64 th = Thread(&Client, PORT);

I64 conn = Accept(sfd, NULL, NULL);
"accepted: %d\n", conn >= 0;
U8 buf[64];
I64 n = Read(conn, buf, 64);
buf[n] = 0;
"server got %d: %s\n", n, buf;
Write(conn, buf, n); // the echo
Close(conn);

I64 rc = Join(th);
reply[reply_n] = 0;
"client rc %d echo %d: %s\n", rc, reply_n, reply;
Close(sfd);
