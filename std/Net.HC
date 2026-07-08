// Net.HC — host TCP sockets (no TempleOS analog). `#include <Net.HC>`.
//
// Compiler intrinsics; see <File.HC> for the conventions. Read/Write (from
// <File.HC>) work on connected socket fds. The caller builds sockaddr bytes
// itself (layouts differ per OS; see the __APPLE__ target macro), as does
// byte-order conversion. A host service, not part of the dialect core.
#ifndef __STD_NET_HC
#define __STD_NET_HC

public I64 Socket(I64 domain, I64 kind, I64 proto);            // a socket fd, or -errno
public I64 Connect(I64 fd, U8 *addr, I64 len);                 // 0, or -errno
public I64 Bind(I64 fd, U8 *addr, I64 len);                    // 0, or -errno
public I64 Listen(I64 fd, I64 backlog);                        // 0, or -errno
public I64 Accept(I64 fd, U8 *addr, U32 *len);                 // a connected fd, or -errno; addr/len may be NULL
public I64 SetSockOpt(I64 fd, I64 level, I64 opt, U8 *val, I64 len); // 0, or -errno
public I64 Shutdown(I64 fd, I64 how);                          // 0, or -errno

#endif // __STD_NET_HC
