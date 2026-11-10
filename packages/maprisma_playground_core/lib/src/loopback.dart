import 'dart:io';

int currentUid({String proc = '/proc'}) {
  final text = File('$proc/self/status').readAsStringSync();
  return int.parse(
    RegExp(r'^Uid:\s+(\d+)', multiLine: true).firstMatch(text)![1]!,
  );
}

List<int> loopbackListeners(int port, {String procNet = '/proc/net'}) {
  if (port < 1 || port > 65535) throw ArgumentError('not a port');
  final owners = <int>[];
  for (final name in ['tcp', 'tcp6']) {
    String text;
    try {
      text = File('$procNet/$name').readAsStringSync();
    } on FileSystemException {
      continue;
    }
    for (final line in text.split('\n').skip(1)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 8 || fields[3] != '0A') continue;
      final parts = fields[1].split(':');
      if (parts.length != 2 || int.tryParse(parts[1], radix: 16) != port) {
        continue;
      }
      final address = parts[0];
      final reachable = name == 'tcp'
          ? address == '00000000' || address.endsWith('7F')
          : address == '00000000000000000000000000000000' ||
                address == '00000000000000000000000001000000' ||
                (address.startsWith('0000000000000000FFFF0000') &&
                    address.endsWith('7F'));
      final uid = int.tryParse(fields[7]);
      if (reachable && uid != null) owners.add(uid);
    }
  }
  return owners;
}

void requireOwnListener(int port, {String procNet = '/proc/net', int? uid}) {
  final owners = loopbackListeners(port, procNet: procNet);
  if (owners.isEmpty) throw StateError('not running');
  final me = uid ?? currentUid();
  if (owners.any((owner) => owner != me)) {
    throw StateError('port $port belongs to another user account');
  }
}

int localClients(int port, {String procNet = '/proc/net'}) {
  var count = 0;
  for (final name in ['tcp', 'tcp6']) {
    try {
      for (final line in File('$procNet/$name').readAsLinesSync().skip(1)) {
        final f = line.trim().split(RegExp(r'\s+'));
        if (f.length > 3 &&
            f[3] == '01' &&
            int.tryParse(f[2].split(':').last, radix: 16) == port) {
          count++;
        }
      }
    } on FileSystemException {
      /* missing table */
    }
  }
  return count;
}
