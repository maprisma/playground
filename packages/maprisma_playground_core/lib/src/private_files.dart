import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

// Linux is the supported desktop platform. libc gives the guarantees dart:io's
// temp-directory and open APIs cannot express (0700 at creation and O_NOFOLLOW).
final _libc = DynamicLibrary.open('libc.so.6');
final _malloc = _libc
    .lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)
    >('malloc');
final _free = _libc
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'free',
    );
final _mkdtemp = _libc
    .lookupFunction<
      Pointer<Uint8> Function(Pointer<Uint8>),
      Pointer<Uint8> Function(Pointer<Uint8>)
    >('mkdtemp');
final _open = _libc
    .lookupFunction<
      Int32 Function(Pointer<Uint8>, Int32),
      int Function(Pointer<Uint8>, int)
    >('open');
final _read = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('read');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
Pointer<Uint8> _allocate(int bytes) {
  final ptr = _malloc(bytes).cast<Uint8>();
  if (ptr.address == 0) throw StateError('Cannot allocate a file buffer.');
  return ptr;
}

Pointer<Uint8> _text(String text) {
  final bytes = utf8.encode(text);
  if (bytes.contains(0)) throw ArgumentError('Invalid file path.');
  final ptr = _allocate(bytes.length + 1);
  ptr.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  return ptr;
}

/// Empty private folder, with 0700 set atomically before its name is returned.
Directory createPrivateTempDirectory({String prefix = 'maprisma-playground-'}) {
  if (prefix.contains('/') || prefix.contains('\u0000')) {
    throw ArgumentError('Invalid temporary folder prefix.');
  }
  final template =
      '${Directory.systemTemp.path}/$prefix'
      'XXXXXX';
  final ptr = _text(template);
  try {
    if (_mkdtemp(ptr).address == 0) {
      throw const FileSystemException(
        'Cannot create a private temporary folder.',
      );
    }
    return Directory(
      utf8.decode(ptr.asTypedList(utf8.encode(template).length)),
    );
  } finally {
    _free(ptr.cast());
  }
}

/// Bounded configuration read without following a final symlink. O_NONBLOCK
/// also prevents a replaced FIFO from blocking the core isolate.
String readRegularNoFollow(String path, {int maxBytes = 512 * 1024}) {
  if (maxBytes < 0) throw ArgumentError('Invalid file size limit.');
  try {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
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
    final buffer = _allocate(maxBytes + 1);
    try {
      var total = 0;
      while (total <= maxBytes) {
        final count = _read(fd, buffer + total, maxBytes + 1 - total);
        if (count < 0) return '';
        if (count == 0) break;
        total += count;
      }
      return total > maxBytes
          ? ''
          : utf8.decode(buffer.asTypedList(total), allowMalformed: true);
    } finally {
      _close(fd);
      _free(buffer.cast());
    }
  } on Object {
    return '';
  }
}
