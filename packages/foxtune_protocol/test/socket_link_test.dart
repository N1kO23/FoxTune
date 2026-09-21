@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:foxtune_protocol/io.dart';
import 'package:test/test.dart';

void main() {
  test('a peer that resets ends the link instead of crashing', () async {
    // A TCP reset, as a WiFi bridge or a simulator that dies mid-session
    // sends: the peer closes with our bytes still unread. Writes after that
    // fail through the socket's `done` future - which, unwatched, surfaced
    // as an unhandled error and took down whatever was running.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final accepted = Completer<Socket>();
    server.listen(accepted.complete);

    final link = await SocketEcuLink.connect('127.0.0.1', server.port);
    addTearDown(link.close);
    final peer = await accepted.future;
    // Never read, so the close below resets rather than ending cleanly.
    peer.listen((_) {}).pause();

    final errors = <Object>[];
    link.incoming.listen((_) {}, onError: errors.add);

    link.send(List.filled(64, 1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    peer.destroy();

    for (var i = 0; i < 100 && link.isOpen; i++) {
      try {
        link.send(List.filled(1024, 2));
      } on StateError {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(link.isOpen, isFalse);
  });
}
