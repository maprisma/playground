import 'i18n.dart';
import 'dart:io';

int currentUid({String proc = '/proc'}) {
  final text = File('$proc/self/status').readAsStringSync();
  return int.parse(RegExp(r'^Uid:\s+(\d+)', multiLine: true).firstMatch(text)![1]!);
}

List<int> loopbackListeners(int port, {String procNet = '/proc/net'}) {
  if (port < 1 || port > 65535) throw ArgumentError(tr("not a port"));
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
                (address.startsWith('0000000000000000FFFF0000') && address.endsWith('7F'));
      final uid = int.tryParse(fields[7]);
      if (reachable && uid != null) owners.add(uid);
    }
  }
  return owners;
}

void requireOwnListener(int port, {String procNet = '/proc/net', int? uid}) {
  final owners = loopbackListeners(port, procNet: procNet);
  if (owners.isEmpty) throw StateError(tr("not running"));
  final me = uid ?? currentUid();
  if (owners.any((owner) => owner != me)) {
    throw StateError(trf("port {0} belongs to another user account", [port]));
  }
}

int localClients(int port, {String procNet = '/proc/net'}) {
  var count = 0;
  for (final name in ['tcp', 'tcp6']) {
    try {
      for (final line in File('$procNet/$name').readAsLinesSync().skip(1)) {
        final f = line.trim().split(RegExp(r'\s+'));
        if (f.length > 3 && f[3] == '01' && int.tryParse(f[2].split(':').last, radix: 16) == port) {
          count++;
        }
      }
    } on FileSystemException {
      /* missing table */
    }
  }
  return count;
}

/// Verify the server endpoint of this established connection, including the
/// ephemeral client port. A listener-port check alone permits port substitution.
void requireOwnConnection(Socket socket, {String procNet = '/proc/net', int? uid}) {
  requireOwnConnectionPorts(socket.remotePort, socket.port, procNet: procNet, uid: uid);
}

void requireOwnConnectionPorts(int serverPort, int clientPort, {String procNet = '/proc/net', int? uid}) {
  final me = uid ?? currentUid();
  var found = false;
  for (final name in ['tcp', 'tcp6']) {
    String table;
    try {
      table = File('$procNet/$name').readAsStringSync();
    } on FileSystemException {
      continue;
    }
    final address = name == 'tcp' ? '0100007F' : '0000000000000000FFFF00000100007F';
    for (final line in table.split('\n').skip(1)) {
      final f = line.trim().split(RegExp(r'\s+'));
      if (f.length < 8 || f[3] != '01') continue;
      bool endpoint(String value, int port) {
        final parts = value.split(':');
        return parts.length == 2 && parts[0] == address && int.tryParse(parts[1], radix: 16) == port;
      }

      if (endpoint(f[1], serverPort) && endpoint(f[2], clientPort)) {
        if (int.tryParse(f[7]) != me) throw StateError(tr("connection belongs to another user account"));
        found = true;
      }
    }
  }
  if (!found) throw StateError(tr("cannot verify local connection owner"));
}
