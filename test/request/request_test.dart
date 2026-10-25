import 'dart:convert';

import 'package:orbiter/orbiter.dart';
import 'package:test/test.dart';

void main() {
  group('Request', () {
    test('constructs with URI, method, headers and context', () {
      final req = Request(
        method: 'POST',
        uri: Uri.parse('http://localhost:8080/api/v1/patients/42?page=1'),
        headers: {
          'authorization': ['Bearer token123'],
        },
        pathParameters: {'id': '42'},
      );

      expect(req.method, equals('POST'));
      expect(req.uri.path, equals('/api/v1/patients/42'));
      expect(req.uri.queryParameters['page'], equals('1'));
      expect(req.pathParameters['id'], equals('42'));
      expect(req.getHeader('authorization'), equals('Bearer token123'));
      expect(req.getHeader('AUTHORIZATION'), equals('Bearer token123'));
      expect(req.context, isNotNull);
    });

    test('reads body as bytes, string and JSON', () async {
      final payload = jsonEncode({'name': 'John Doe', 'age': 30});
      final stream = Stream.value(utf8.encode(payload));

      final req = Request(
        method: 'POST',
        uri: Uri.parse('http://localhost:8080/users'),
        bodyStream: stream,
      );

      final json = await req.readAsJson() as Map<String, dynamic>;
      expect(json['name'], equals('John Doe'));
      expect(json['age'], equals(30));
    });

    test('runs cleanup hooks in LIFO order even if a hook throws', () async {
      final order = <int>[];

      final req = Request(
        method: 'GET',
        uri: Uri.parse('http://localhost:8080/resource'),
      );

      req.addCleanupHook(() async {
        order.add(1);
      });

      req.addCleanupHook(() async {
        order.add(2);
        throw Exception('Failure in hook 2');
      });

      req.addCleanupHook(() async {
        order.add(3);
      });

      await req.runCleanupHooks();

      // LIFO: hook 3 runs first, then 2 (throws but handled), then 1.
      expect(order, equals([3, 2, 1]));
    });

    test('readAsBytes enforces maxBodySize while streaming', () async {
      final req = Request(
        method: 'POST',
        uri: Uri.parse('http://localhost:8080/upload'),
        bodyStream: Stream.fromIterable([
          List<int>.filled(10, 1),
          List<int>.filled(10, 1),
        ]),
        maxBodySize: 16,
      );

      await expectLater(req.readAsBytes(), throwsA(isA<PayloadTooLargeException>()));
    });

    test('readAsBytes rejects a declared content-length above maxBodySize before reading', () async {
      var listened = false;
      final req = Request(
        method: 'POST',
        uri: Uri.parse('http://localhost:8080/upload'),
        headers: {
          'content-length': ['100'],
        },
        bodyStream: Stream<List<int>>.empty().map((c) {
          listened = true;
          return c;
        }),
        maxBodySize: 16,
      );

      await expectLater(req.readAsBytes(), throwsA(isA<PayloadTooLargeException>()));
      expect(listened, isFalse);
    });

    test('maxBodySize null means unlimited', () async {
      final req = Request(
        method: 'POST',
        uri: Uri.parse('http://localhost:8080/upload'),
        bodyStream: Stream.value(List<int>.filled(4096, 1)),
      );

      expect((await req.readAsBytes()).length, 4096);
    });

    test('runCleanupHooks reports hook errors and still runs the others', () async {
      final req = Request(method: 'GET', uri: Uri.parse('http://localhost/'));
      final reported = <Object>[];
      var ran = false;
      req.addCleanupHook(() => ran = true);
      req.addCleanupHook(() => throw StateError('boom'));

      await req.runCleanupHooks(onError: (e, s) => reported.add(e));

      expect(ran, isTrue);
      expect(reported.single, isA<StateError>());
    });

    test('runCleanupHooks without hooks completes', () async {
      final req = Request(method: 'GET', uri: Uri.parse('http://localhost/'));
      await req.runCleanupHooks();
    });
  });
}
