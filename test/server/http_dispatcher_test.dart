import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:orbiter/orbiter.dart';
import 'package:test/test.dart';

void main() {
  group('HttpDispatcher & Error Boundary', () {
    late HttpServer server;
    late HttpClient client;
    late Uri baseUri;

    setUp(() {
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });

    test('dispatches GET request and writes response with headers', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');

      final dispatcher = HttpDispatcher(
        rootHandler: (request) async {
          expect(request.method, 'GET');
          expect(request.uri.path, '/hello');
          return Response.ok(
            body: 'Hello World',
            headers: {'x-custom-header': ['test-value']},
          );
        },
      );

      server.listen(dispatcher.dispatch);

      final req = await client.getUrl(baseUri.replace(path: '/hello'));
      final res = await req.close();

      expect(res.statusCode, 200);
      expect(res.headers.value('x-custom-header'), 'test-value');
      final body = await utf8.decoder.bind(res).join();
      expect(body, 'Hello World');
    });

    test('dispatches POST request, reads body and writes JSON response', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');

      final dispatcher = HttpDispatcher(
        rootHandler: (request) async {
          final payload = await request.readAsJson() as Map<String, dynamic>;
          expect(payload['name'], 'Dart');

          return Response.created(
            body: jsonEncode({'status': 'created', 'received': payload['name']}),
            headers: {
              'content-type': ['application/json; charset=utf-8'],
            },
          );
        },
      );

      server.listen(dispatcher.dispatch);

      final req = await client.postUrl(baseUri.replace(path: '/items'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'name': 'Dart'}));
      final res = await req.close();

      expect(res.statusCode, 201);
      final body = await utf8.decoder.bind(res).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['status'], 'created');
      expect(json['received'], 'Dart');
    });

    test('captures synchronous unhandled exception and returns 500 JSON', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');

      final dispatcher = HttpDispatcher(
        rootHandler: (request) {
          throw StateError('Simulated internal failure');
        },
      );

      server.listen(dispatcher.dispatch);

      final req = await client.getUrl(baseUri.replace(path: '/fail-sync'));
      final res = await req.close();

      expect(res.statusCode, 500);
      expect(res.headers.contentType?.mimeType, 'application/json');
      final body = await utf8.decoder.bind(res).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['error'], 'Internal Server Error');
      expect(json['code'], 500);
    });

    test('captures asynchronous unhandled rejection and returns 500 JSON', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');

      final dispatcher = HttpDispatcher(
        rootHandler: (request) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          throw Exception('Simulated async crash');
        },
      );

      server.listen(dispatcher.dispatch);

      final req = await client.getUrl(baseUri.replace(path: '/fail-async'));
      final res = await req.close();

      expect(res.statusCode, 500);
      final body = await utf8.decoder.bind(res).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['error'], 'Internal Server Error');
      expect(json['code'], 500);
    });

    test('supports custom ErrorHandler (Error Boundary)', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');

      final dispatcher = HttpDispatcher(
        rootHandler: (request) {
          throw const FormatException('Bad query param');
        },
        errorHandler: (error, stackTrace, request) {
          expect(error, isA<FormatException>());
          return Response.badRequest(body: {'error': 'Custom bad request'});
        },
      );

      server.listen(dispatcher.dispatch);

      final req = await client.getUrl(baseUri.replace(path: '/custom-error'));
      final res = await req.close();

      expect(res.statusCode, 400);
      final body = await utf8.decoder.bind(res).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['error'], 'Custom bad request');
    });

    test('guarantees execution of cleanup hooks in finally block on success and error', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');

      var successHookRan = false;
      var failureHookRan = false;

      final dispatcher = HttpDispatcher(
        rootHandler: (request) async {
          if (request.uri.path == '/ok') {
            request.addCleanupHook(() {
              successHookRan = true;
            });
            return Response.ok(body: 'success');
          } else {
            request.addCleanupHook(() {
              failureHookRan = true;
            });
            throw StateError('Crash in endpoint');
          }
        },
      );

      server.listen(dispatcher.dispatch);

      // 1. Successful call
      final req1 = await client.getUrl(baseUri.replace(path: '/ok'));
      final res1 = await req1.close();
      expect(res1.statusCode, 200);
      expect(successHookRan, isTrue);

      // 2. Call with failure
      final req2 = await client.getUrl(baseUri.replace(path: '/crash'));
      final res2 = await req2.close();
      expect(res2.statusCode, 500);
      expect(failureHookRan, isTrue);
    });

    test('dispatches binary byte payloads and streaming responses intact', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');

      final binaryPayload = [0x00, 0x01, 0x02, 0xFE, 0xFF];

      final dispatcher = HttpDispatcher(
        rootHandler: (request) {
          return Response.bytes(
            binaryPayload,
            headers: {'content-type': ['application/octet-stream']},
          );
        },
      );

      server.listen(dispatcher.dispatch);

      final req = await client.getUrl(baseUri.replace(path: '/binary'));
      final res = await req.close();

      expect(res.statusCode, 200);
      final receivedBytes = <int>[];
      await for (final chunk in res) {
        receivedBytes.addAll(chunk);
      }
      expect(receivedBytes, equals(binaryPayload));
    });
  });

  group('HttpDispatcher regressions', () {
    late HttpServer server;
    late HttpClient client;
    late Uri baseUri;
    late List<Object> reported;

    Future<void> serve(Handler handler, {int? maxBodySize = 1024 * 1024}) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
      final dispatcher = HttpDispatcher(
        rootHandler: handler,
        maxBodySize: maxBodySize,
        onError: (error, stackTrace, request) => reported.add(error),
      );
      server.listen(dispatcher.dispatch);
    }

    setUp(() {
      client = HttpClient();
      reported = <Object>[];
    });

    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });

    test('invalid response header yields 500 instead of a hanging connection', () async {
      await serve((request) => Response.ok(
            body: 'x',
            headers: {'x-bad': ['a\r\nInjected: 1']},
          ));

      final res = await (await client.getUrl(baseUri.replace(path: '/hdr')))
          .close()
          .timeout(const Duration(seconds: 5));
      await res.drain<void>();

      expect(res.statusCode, 500);
      expect(res.headers.value('injected'), isNull);
      expect(reported, hasLength(1));
    });

    test('a failing response stream closes the connection instead of hanging', () async {
      await serve((request) => Response(
            200,
            body: Stream<List<int>>.error(StateError('mid-stream')),
          ));

      final outcome = await () async {
        try {
          final res = await (await client.getUrl(baseUri.replace(path: '/s')))
              .close();
          await res.drain<void>();
          return 'completed';
        } on HttpException {
          return 'closed';
        }
      }()
          .timeout(const Duration(seconds: 5));

      expect(outcome, anyOf('completed', 'closed'));
      expect(reported, hasLength(1));
    });

    test('cleanup hooks run after the streamed body is fully written', () async {
      final order = <String>[];
      await serve((request) {
        request.addCleanupHook(() => order.add('cleanup'));
        final body = Stream<List<int>>.fromFuture(Future.delayed(
          const Duration(milliseconds: 30),
          () {
            order.add('emit');
            return utf8.encode('row');
          },
        ));
        return Response(200, body: body);
      });

      final res = await (await client.getUrl(baseUri.replace(path: '/s'))).close();
      expect(await utf8.decoder.bind(res).join(), 'row');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(order, ['emit', 'cleanup']);
    });

    test('cleanup hooks still run when the client disconnects mid-stream', () async {
      final cleaned = Completer<void>();
      final release = Completer<void>();
      await serve((request) {
        request.addCleanupHook(cleaned.complete);
        Stream<List<int>> body() async* {
          // Larger than dart:io's output buffer, so it reaches the client now.
          yield List<int>.filled(64 * 1024, 65);
          await release.future;
          for (var i = 0; i < 1000; i++) {
            yield List<int>.filled(64 * 1024, 65);
          }
        }

        return Response(200, body: body());
      });

      final res = await (await client.getUrl(baseUri.replace(path: '/s'))).close();
      await res.first;
      client.close(force: true);
      release.complete();

      await cleaned.future.timeout(const Duration(seconds: 5));
    });

    test('body above maxBodySize yields 413 (content-length known)', () async {
      await serve(
        (request) async => Response.ok(body: '${(await request.readAsBytes()).length}'),
        maxBodySize: 16,
      );

      final req = await client.postUrl(baseUri.replace(path: '/upload'));
      req.add(List<int>.filled(17, 1));
      final res = await req.close();
      await res.drain<void>();

      expect(res.statusCode, 413);
    });

    test('body above maxBodySize yields 413 (chunked)', () async {
      await serve(
        (request) async => Response.ok(body: '${(await request.readAsBytes()).length}'),
        maxBodySize: 16,
      );

      final req = await client.postUrl(baseUri.replace(path: '/upload'));
      req.headers.chunkedTransferEncoding = true;
      req.add(List<int>.filled(10, 1));
      req.add(List<int>.filled(10, 1));
      final res = await req.close();
      await res.drain<void>();

      expect(res.statusCode, 413);
    });

    test('body within maxBodySize is read intact', () async {
      await serve(
        (request) async => Response.ok(body: '${(await request.readAsBytes()).length}'),
        maxBodySize: 16,
      );

      final req = await client.postUrl(baseUri.replace(path: '/upload'));
      req.add(List<int>.filled(16, 1));
      final res = await req.close();

      expect(res.statusCode, 200);
      expect(await utf8.decoder.bind(res).join(), '16');
    });

    test('unhandled handler errors are reported to onError', () async {
      await serve((request) => throw StateError('boom'));

      final res = await (await client.getUrl(baseUri.replace(path: '/x'))).close();
      await res.drain<void>();

      expect(res.statusCode, 500);
      expect(reported.single, isA<StateError>());
    });

    test('exposes the raw HttpRequest and headers without copying eagerly', () async {
      await serve((request) => Response.ok(
            body: '${request.rawRequest != null}:${request.getHeader('X-Probe')}',
          ));

      final req = await client.getUrl(baseUri.replace(path: '/h'));
      req.headers.set('x-probe', 'v1');
      final res = await req.close();

      expect(await utf8.decoder.bind(res).join(), 'true:v1');
    });
  });
}
