import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('FakeEcuLink', () {
    late FakeEcuLink link;

    setUp(() => link = FakeEcuLink());
    tearDown(() => link.close());

    test('records sent bytes in order across calls', () {
      link
        ..send(const <int>[0x51])
        ..send(const <int>[0x53, 0x01]);
      expect(link.sent, const <int>[0x51, 0x53, 0x01]);
    });

    test('delivers bytes to listeners', () async {
      final received = <int>[];
      final sub = link.incoming.listen(received.addAll);
      addTearDown(sub.cancel);

      link.deliver(const <int>[0x00, 0x2A]);
      await Future<void>.delayed(Duration.zero);

      expect(received, const <int>[0x00, 0x2A]);
    });

    test('reports open state and rejects use after close', () async {
      expect(link.isOpen, isTrue);
      await link.close();
      expect(link.isOpen, isFalse);
      expect(() => link.send(const <int>[0x51]), throwsStateError);
      expect(() => link.deliver(const <int>[0x00]), throwsStateError);
    });

    test('close is idempotent', () async {
      await link.close();
      await expectLater(link.close(), completes);
    });

    test('clearSent resets the recording', () {
      link.send(const <int>[0x51]);
      link.clearSent();
      expect(link.sent, isEmpty);
    });
  });
}
