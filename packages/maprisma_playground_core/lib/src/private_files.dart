import 'i18n.dart';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

// Linux is the supported desktop platform. libc gives the guarantees dart:io's
// temp-directory and open APIs cannot express (0700 at creation and O_NOFOLLOW).
final _libc = DynamicLibrary.open('libc.so.6');
final _malloc = _libc.lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('malloc');
final _free = _libc.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');
final _mkdtemp = _libc.lookupFunction<Pointer<Uint8> Function(Pointer<Uint8>), Pointer<Uint8> Function(Pointer<Uint8>)>(
  'mkdtemp',
);
final _open = _libc.lookupFunction<Int32 Function(Pointer<Uint8>, Int32), int Function(Pointer<Uint8>, int)>('open');
final _read = _libc
    .lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>('read');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
Pointer<Uint8> _allocate(int bytes) {
  final ptr = _malloc(bytes).cast<Uint8>();
  if (ptr.address == 0) throw StateError(tr("Cannot allocate a file buffer."));
  return ptr;
}

Pointer<Uint8> _text(String text) {
  final bytes = utf8.encode(text);
  if (bytes.contains(0)) throw ArgumentError(tr("Invalid file path."));
  final ptr = _allocate(bytes.length + 1);
  ptr.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  return ptr;
}

/// Empty private folder, with 0700 set atomically before its name is returned.
Directory createPrivateTempDirectory({String prefix = 'maprisma-playground-'}) {
  if (prefix.contains('/') || prefix.contains('\u0000')) {
    throw ArgumentError(tr("Invalid temporary folder prefix."));
  }
  final template =
      '${Directory.systemTemp.path}/$prefix'
      'XXXXXX';
  final ptr = _text(template);
  try {
    if (_mkdtemp(ptr).address == 0) {
      throw FileSystemException(tr("Cannot create a private temporary folder."));
    }
    return Directory(utf8.decode(ptr.asTypedList(utf8.encode(template).length)));
  } finally {
    _free(ptr.cast());
  }
}

/// Bounded configuration read without following a final symlink. O_NONBLOCK
/// also prevents a replaced FIFO from blocking the core isolate.
String readRegularNoFollow(String path, {int maxBytes = 512 * 1024, bool requireOwner = false}) {
  if (maxBytes < 0) throw ArgumentError(tr("Invalid file size limit."));
  try {
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) {
      return '';
    }
    final name = _text(path);
    int fd;
    try {
      fd = _open(name, 0x20000 | 0x800);
    } finally {
      _free(name.cast());
    }
    if (fd < 0) return '';
    final identity = fileIdentity('', fd: fd);
    if (identity == null ||
        identity.mode & 0xf000 != 0x8000 ||
        (requireOwner && (identity.uid != fileOwnerUid || identity.links != 1))) {
      _close(fd);
      return '';
    }
    final buffer = _allocate(maxBytes + 1);
    try {
      var total = 0;
      while (total <= maxBytes) {
        final count = _read(fd, buffer + total, maxBytes + 1 - total);
        if (count < 0) return '';
        if (count == 0) break;
        total += count;
      }
      return total > maxBytes ? '' : utf8.decode(buffer.asTypedList(total), allowMalformed: true);
    } finally {
      _close(fd);
      _free(buffer.cast());
    }
  } on Object {
    return '';
  }
}

final _openMode = _libc
    .lookupFunction<Int32 Function(Pointer<Uint8>, Int32, Int32), int Function(Pointer<Uint8>, int, int)>('open');
final _statx = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>, Int32, Uint32, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>, int, int, Pointer<Uint8>)
    >('statx');
final _getuid = _libc.lookupFunction<Uint32 Function(), int Function()>('getuid');
final _flock = _libc.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('flock');
final _writeFd = _libc
    .lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>('write');
final _truncate = _libc.lookupFunction<Int32 Function(Int32, Int64), int Function(int, int)>('ftruncate');
final _fchmod = _libc.lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>('fchmod');
final _fsync = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');

/// Linux statx has a stable layout on every supported Linux architecture.
({int uid, int links, int mode, int inode, int device, int size})? fileIdentity(
  String path, {
  int fd = -100,
  bool noFollow = true,
}) {
  final name = _text(path), buffer = _allocate(256);
  try {
    if (_statx(fd, name, (path.isEmpty ? 0x1000 : 0) | (noFollow ? 0x100 : 0), 0x7ff, buffer) != 0) return null;
    final b = buffer.asTypedList(256).buffer.asByteData();
    return (
      uid: b.getUint32(20, Endian.host),
      links: b.getUint32(16, Endian.host),
      mode: b.getUint16(28, Endian.host),
      inode: b.getUint64(32, Endian.host),
      device: b.getUint32(136, Endian.host) << 32 | b.getUint32(140, Endian.host),
      size: b.getUint64(40, Endian.host),
    );
  } finally {
    _free(name.cast());
    _free(buffer.cast());
  }
}

final _access = _libc.lookupFunction<Int32 Function(Pointer<Uint8>, Int32), int Function(Pointer<Uint8>, int)>(
  'access',
);
bool executableByUser(String path) {
  final name = _text(path);
  try {
    return _access(name, 1) == 0;
  } finally {
    _free(name.cast());
  }
}

int get fileOwnerUid => _getuid();
bool ownRegularFile(String path) {
  final s = fileIdentity(path);
  return s != null && s.uid == fileOwnerUid && s.links == 1 && s.mode & 0xf000 == 0x8000;
}

bool ownFolder(String path) {
  final s = fileIdentity(path, noFollow: false);
  return s != null && s.uid == fileOwnerUid && s.mode & 0xf000 == 0x4000 && s.mode & 0x12 == 0;
}

/// Settings directories must already belong to this account and be exactly 0700.
void requirePrivateFolder(String path) {
  final s = fileIdentity(path);
  if (s == null || s.uid != fileOwnerUid || s.mode & 0xf000 != 0x4000 || s.mode & 0xfff != 0x1c0) {
    throw FileSystemException(tr("Expected own private 0700 folder"), path);
  }
}

/// Own regular O_NOFOLLOW descriptor; advisory lock survives until close.
class StagingFile {
  StagingFile(String path, {bool resume = true, bool exclusive = false, int mode = 0x180}) : path = path {
    final name = _text(path);
    try {
      fd = _openMode(name, 2 | 0x20000 | 0x80000 | 0x800 | 0x40 | 0x80, mode);
      if (fd < 0 && !exclusive) fd = _openMode(name, 2 | 0x20000 | 0x80000 | 0x800, mode);
    } finally {
      _free(name.cast());
    }
    if (fd < 0) throw FileSystemException(tr("Cannot open own download"), path);
    final info = fileIdentity('', fd: fd);
    if (info == null || info.uid != fileOwnerUid || info.links != 1 || info.mode & 0xf000 != 0x8000) {
      close();
      throw FileSystemException(
        trf("{0} is not this account's own download; remove it and try again", [File(path).uri.pathSegments.last]),
      );
    }
    if (_fchmod(fd, info.mode & mode & 0x1ff) != 0) {
      close();
      throw FileSystemException(tr("Cannot set private file permissions"), path);
    }
    inode = info.inode;
    device = info.device;
    if (_flock(fd, 2 | 4) != 0) {
      close();
      throw StateError(trf("{0} is being downloaded already", [File(path).uri.pathSegments.last]));
    }
    if (!resume) truncate();
  }
  final String path;
  late int fd;
  late int inode, device;
  int get size => fileIdentity('', fd: fd)!.size;
  void truncate() {
    if (_truncate(fd, 0) != 0) throw FileSystemException(tr("Cannot empty staging file"), path);
  }

  void add(List<int> bytes) {
    final buffer = _allocate(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      // pwrite is unnecessary: a fresh descriptor starts at 0; resumed data uses
      // append mode set by lseek before the first chunk.
      while (offset < bytes.length) {
        final n = _writeFd(fd, buffer + offset, bytes.length - offset);
        if (n <= 0) throw FileSystemException(tr("Cannot write staging file"), path);
        offset += n;
      }
    } finally {
      _free(buffer.cast());
    }
  }

  void seekEnd() {
    final seek = _libc.lookupFunction<Int64 Function(Int32, Int64, Int32), int Function(int, int, int)>('lseek');
    if (seek(fd, 0, 2) < 0) throw FileSystemException(tr("Cannot resume staging file"), path);
  }

  void publish(String target) {
    final now = fileIdentity(path);
    if (_fsync(fd) != 0 || now?.inode != inode || now?.device != device) {
      throw StateError(trf("{0} was replaced while downloading; nothing was kept", [path]));
    }
    File(path).renameSync(target);
  }

  void close() {
    if (fd >= 0) {
      _close(fd);
      fd = -1;
    }
  }
}

/// Exclusive no-follow temporary file, 0600 before the first byte, then atomic rename.
void atomicPrivateWrite(String path, String text, {bool privateFolder = false}) {
  final dir = Directory(File(path).parent.path);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
    Process.runSync('/bin/chmod', ['700', dir.path]);
  }
  if (privateFolder) requirePrivateFolder(dir.path);
  final temp = '${dir.path}/.${File(path).uri.pathSegments.last}.$pid.${DateTime.now().microsecondsSinceEpoch}';
  final output = StagingFile(temp, exclusive: true);
  try {
    output.add(utf8.encode(text));
    output.publish(path);
  } finally {
    output.close();
    if (File(temp).existsSync()) File(temp).deleteSync();
  }
}

final _errnoLocation = _libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__errno_location');
final _strerror = _libc.lookupFunction<Pointer<Uint8> Function(Int32), Pointer<Uint8> Function(int)>('strerror');
final _mkdir = _libc.lookupFunction<Int32 Function(Pointer<Uint8>, Uint32), int Function(Pointer<Uint8>, int)>('mkdir');

/// The last libc error as an OSError (its own English text, as Python's strerror).
OSError _lastError() {
  final code = _errnoLocation().value;
  final text = _strerror(code);
  var length = 0;
  while (text[length] != 0) {
    length++;
  }
  return OSError(utf8.decode(text.asTypedList(length), allowMalformed: true), code);
}

/// A new file only its owner can read (0600 from the first byte): never through a link
/// (O_NOFOLLOW) and never over an existing file (O_EXCL).
void writeNewPrivate(String path, List<int> bytes) {
  final name = _text(path);
  int fd;
  try {
    fd = _openMode(name, 1 | 0x20000 | 0x80000 | 0x40 | 0x80, 0x180); // O_WRONLY|O_NOFOLLOW|O_CLOEXEC|O_CREAT|O_EXCL
  } finally {
    _free(name.cast());
  }
  if (fd < 0) throw FileSystemException('open', path, _lastError());
  final buffer = _allocate(bytes.isEmpty ? 1 : bytes.length);
  try {
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    var offset = 0;
    while (offset < bytes.length) {
      final n = _writeFd(fd, buffer + offset, bytes.length - offset);
      if (n <= 0) throw FileSystemException('write', path, _lastError());
      offset += n;
    }
  } finally {
    _free(buffer.cast());
    _close(fd);
  }
}

/// A folder of this account's that only it can open (0700 from the start); its parents are made
/// as usual. An existing folder is left as it is; a link or a file in its place is refused.
void makePrivateFolder(String path) {
  final there = FileSystemEntity.typeSync(path, followLinks: false);
  if (there == FileSystemEntityType.directory) return;
  if (there != FileSystemEntityType.notFound) {
    throw FileSystemException('mkdir', path, const OSError('File exists', 17));
  }
  Directory(File(path).parent.path).createSync(recursive: true);
  final name = _text(path);
  try {
    if (_mkdir(name, 0x1c0) != 0) {
      final error = _lastError(); // before any other call can change errno
      // Made meanwhile by someone else: fine when it is a real folder.
      if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.directory) {
        throw FileSystemException('mkdir', path, error);
      }
    }
  } finally {
    _free(name.cast());
  }
}

final _openAt = _libc
    .lookupFunction<Int32 Function(Int32, Pointer<Uint8>, Int32, Uint32), int Function(int, Pointer<Uint8>, int, int)>(
      'openat',
    );
final _unlinkAt = _libc
    .lookupFunction<Int32 Function(Int32, Pointer<Uint8>, Int32), int Function(int, Pointer<Uint8>, int)>('unlinkat');

/// Tests only: a write of a new file fails after this many bytes (a full disk, an I/O error).
int? debugFailWriteAfter;

/// A handle on a folder of this account's that only it may write to: made 0700 when missing; used
/// only when it is a real folder (opened with O_NOFOLLOW|O_DIRECTORY, so no link), owned by this
/// account and not writable by group or others (checked on the opened handle). Files are made
/// relative to that handle, so the folder cannot be swapped between the check and the write.
final class PrivateFolder {
  PrivateFolder._(this.path, this._fd);

  factory PrivateFolder.open(String path) {
    makePrivateFolder(path);
    final name = _text(path);
    int fd;
    try {
      fd = _openMode(name, 0x10000 | 0x20000 | 0x80000, 0); // O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC
    } finally {
      _free(name.cast());
    }
    if (fd < 0) throw FileSystemException('open', path, _lastError());
    final info = fileIdentity('', fd: fd);
    if (info == null || info.mode & 0xf000 != 0x4000 || info.uid != fileOwnerUid || info.mode & 0x12 != 0) {
      _close(fd);
      throw FileSystemException('not a private folder of yours', path, const OSError('Permission denied', 13));
    }
    return PrivateFolder._(path, fd);
  }

  final String path;
  int _fd;

  static void _plain(String name) {
    if (name.isEmpty || name == '.' || name == '..' || name.contains('/')) {
      throw ArgumentError.value(name, 'name', 'not a plain file name');
    }
  }

  /// Something of that name is in the folder (also a link that points nowhere).
  bool taken(String name) {
    _plain(name);
    return fileIdentity(name, fd: _fd) != null;
  }

  /// A new file of our own in the folder (0600, never through a link, never over an existing
  /// file), written completely and synced, or removed again.
  void writeNew(String name, List<int> bytes) {
    _plain(name);
    final where = '$path/$name';
    final cName = _text(name);
    try {
      final out = _openAt(_fd, cName, 1 | 0x20000 | 0x80000 | 0x40 | 0x80, 0x180);
      if (out < 0) throw FileSystemException('open', where, _lastError());
      final buffer = _allocate(bytes.isEmpty ? 1 : bytes.length);
      var ok = false;
      try {
        buffer.asTypedList(bytes.length).setAll(0, bytes);
        var offset = 0;
        while (offset < bytes.length) {
          final limit = debugFailWriteAfter;
          if (limit != null && offset >= limit) {
            throw FileSystemException('write', where, const OSError('No space left on device', 28));
          }
          final want = limit == null ? bytes.length - offset : (limit - offset).clamp(1, bytes.length - offset);
          final n = _writeFd(out, buffer + offset, want); // a short write: the loop goes on
          if (n <= 0) throw FileSystemException('write', where, _lastError());
          offset += n;
        }
        if (_fsync(out) != 0) throw FileSystemException('fsync', where, _lastError());
        ok = true;
      } finally {
        _free(buffer.cast());
        _close(out);
        if (!ok) _unlinkAt(_fd, cName, 0); // nothing half-written is left behind
      }
    } finally {
      _free(cName.cast());
    }
  }

  void close() {
    if (_fd >= 0) {
      _close(_fd);
      _fd = -1;
    }
  }
}
