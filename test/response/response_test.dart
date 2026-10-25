import 'dart:convert';
import 'dart:typed_data';

import 'package:orbiter/orbiter.dart';
import 'package:test/test.dart';

void main() {
  group('Response', () {
    test('Response.ok creates 200 with headers and body', () {
      final res = Response.ok(
        body: 'hello world',
        headers: {'x-custom': ['val1']},
      );
      expect(res.statusCode, equals(200));
      expect(res.body, equals('hello world'));
      expect(res.getHeader('x-custom'), equals('val1'));
      expect(res.getHeader('X-CUSTOM'), equals('val1'));
    });

    test('Response.json encodes data and sets content-type', () {
      final data = {'status': 'ok', 'count': 42};
      final res = Response.json(data);

      expect(res.statusCode, equals(200));
      expect(res.getHeader('content-type'), equals('application/json; charset=utf-8'));
      expect(res.body, equals(jsonEncode(data)));
    });

    test('Response.bytes sets binary body and content-length', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final res = Response.bytes(bytes, contentType: 'application/pdf');

      expect(res.statusCode, equals(200));
      expect(res.getHeader('content-type'), equals('application/pdf'));
      expect(res.getHeader('content-length'), equals('5'));
      expect(res.body, equals(bytes));
    });

    test('Response error factories construct expected status codes', () {
      expect(Response.badRequest(body: 'invalid').statusCode, equals(400));
      expect(Response.unauthorized().statusCode, equals(401));
      expect(Response.forbidden().statusCode, equals(403));
      expect(Response.notFound().statusCode, equals(404));

      final err500 = Response.internalServerError(message: 'database timeout');
      expect(err500.statusCode, equals(500));
      expect(err500.body, contains('database timeout'));
    });

    test('withHeader creates a new Response with updated header', () {
      final res = Response.ok(body: 'data');
      final updated = res.withHeader('cache-control', 'no-cache');

      expect(res.getHeader('cache-control'), isNull);
      expect(updated.getHeader('cache-control'), equals('no-cache'));
      expect(updated.body, equals('data'));
    });
  });
}
