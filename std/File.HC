// File.HC — file-descriptor I/O and filesystem mutation on the host OS.
// `#include <File.HC>`.
//
// Not TempleOS-native (TempleOS is a single-address-space machine with no
// POSIX fds): this is the compiler's real-OS target layer. Compiler intrinsics
// — the prototypes put the names in scope for the type-checker and each call
// lowers directly to the libc equivalent (Open translates Linux-style flags on
// darwin), so no bodies exist. A host service, not part of the dialect core.
#ifndef __STD_FILE_HC
#define __STD_FILE_HC

public I64 Open(U8 *path, I64 flags, I64 mode); // a file fd, or -errno
public I64 LSeek(I64 fd, I64 off, I64 whence);
public I64 Read(I64 fd, U8 *buf, I64 n);
public I64 Write(I64 fd, U8 *buf, I64 n);
public I64 Close(I64 fd);

public I64 Remove(U8 *path);
public I64 Rename(U8 *oldpath, U8 *newpath);
public I64 Mkdir(U8 *path, I64 mode);
public I64 Chdir(U8 *path);
public I64 Getcwd(U8 *buf, I64 size);

#endif // __STD_FILE_HC
