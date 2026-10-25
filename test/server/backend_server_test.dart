import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:orbiter/orbiter.dart';
import 'package:test/test.dart';

void main() {
  group('BackendServer Lifecycle', () {
    late HttpClient client;

    setUp(() {
      client = HttpClient();
    });

    tearDown(() {
      client.close(force: true);
    });

    test('binds on ephemeral port and serves HTTP requests', () async {
      final server = await BackendServer.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
        handler: (request) => Response.ok(body: 'server-running'),
      );

      expect(server.port, greaterThan(0));
      expect(server.address, equals(InternetAddress.loopbackIPv4));

      final req = await client.getUrl(
        Uri.parse('http://${server.address.host}:${server.port}/test'),
      );
      final res = await req.close();

      expect(res.statusCode, 200);
      final body = await utf8.decoder.bind(res).join();
      expect(body, 'server-running');

      final host = server.address.host;
      final port = server.port;

      await server.close();

      // Confirms that the socket was released after close
      expect(
        () async {
          final reqAfterClose = await client.getUrl(
            Uri.parse('http://$host:$port/test'),
          );
          await reqAfterClose.close();
        },
        throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
      );
    });

    test('supports shared: true on same port for multi-worker scaling', () async {
      // 1. Creates the first server with shared: true
      final server1 = await BackendServer.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
        shared: true,
        handler: (request) => Response.ok(body: 'worker-1'),
      );

      final commonPort = server1.port;

      // 2. Creates the second server on the SAME port with shared: true
      final server2 = await BackendServer.bind(
        address: InternetAddress.loopbackIPv4,
        port: commonPort,
        shared: true,
        handler: (request) => Response.ok(body: 'worker-2'),
      );

      expect(server2.port, equals(commonPort));

      // 3. Makes requests confirming the shared port serves without a bind conflict
      final req = await client.getUrl(
        Uri.parse('http://${server1.address.host}:$commonPort/'),
      );
      final res = await req.close();
      expect(res.statusCode, 200);
      final body = await utf8.decoder.bind(res).join();
      expect(body, anyOf('worker-1', 'worker-2'));

      await server1.close();
      await server2.close();
    });
  });

  group('BackendServer close and cleanup lifecycle', () {
    late HttpClient client;

    setUp(() => client = HttpClient());
    tearDown(() => client.close(force: true));

    test('close waits for in-flight requests and their cleanup hooks', () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      var hookDone = false;

      final server = await BackendServer.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
        handler: (request) async {
          request.addCleanupHook(() async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            hookDone = true;
          });
          entered.complete();
          await gate.future;
          return Response.ok(body: 'late');
        },
      );

      final pending = client
          .getUrl(Uri.parse('http://127.0.0.1:${server.port}/'))
          .then((r) => r.close())
          .then((res) => utf8.decoder.bind(res).join());
      await entered.future;

      var closed = false;
      final closing = server.close().then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(closed, isFalse, reason: 'close must wait for the in-flight request');

      gate.complete();
      expect(await pending, 'late');
      await closing;
      expect(hookDone, isTrue, reason: 'close must resolve after the hooks');
    });

    test('close returns and reports when drainTimeout elapses', () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      final reported = <Object>[];

      final server = await BackendServer.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
        onError: (error, stack, request) => reported.add(error),
        handler: (request) async {
          entered.complete();
          await gate.future;
          return Response.ok();
        },
      );

      unawaited(client
          .getUrl(Uri.parse('http://127.0.0.1:${server.port}/'))
          .then((r) => r.close())
          .then<void>((_) {}, onError: (_) {}));
      await entered.future;

      await server.close(
        force: true,
        drainTimeout: const Duration(milliseconds: 100),
      );
      expect(reported, hasLength(1));
      expect(reported.single, isA<TimeoutException>());
      gate.complete();
    });

    test('cleanup hook runs when the client disconnects during the handler',
        () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      final hookRan = Completer<void>();

      final server = await BackendServer.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
        handler: (request) async {
          request.addCleanupHook(hookRan.complete);
          entered.complete();
          await gate.future;
          return Response.ok(body: 'nobody listens');
        },
      );

      final req = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/'));
      unawaited(req.close().then<void>((_) {}, onError: (_) {}));
      await entered.future;
      client.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      gate.complete();
      await hookRan.future.timeout(const Duration(seconds: 5));
      await server.close();
    });

    test('an error thrown by a cleanup hook reaches onError', () async {
      final reported = <Object>[];
      final server = await BackendServer.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
        onError: (error, stack, request) => reported.add(error),
        handler: (request) {
          request.addCleanupHook(() => throw StateError('hook failed'));
          return Response.ok();
        },
      );

      final res = await (await client
              .getUrl(Uri.parse('http://127.0.0.1:${server.port}/')))
          .close();
      await res.drain<void>();
      await server.close();

      expect(reported.whereType<StateError>(), hasLength(1));
    });

    test(
        'a client that leaves before the first byte: no step of the stream '
        'generator runs after the cleanup hooks started', () async {
      var cleanupStarted = false;
      var cleanups = 0;
      var stepsAfterCleanup = 0;
      final server = await BackendServer.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
        handler: (request) {
          request.addCleanupHook(() {
            cleanupStarted = true;
            cleanups++;
          });
          Stream<List<int>> body() async* {
            for (var i = 0; i < 6; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 3));
              if (cleanupStarted) stepsAfterCleanup++; // work on a resource already handed back
              yield utf8.encode('step$i|');
            }
          }

          return Response(200, body: body());
        },
      );
      for (var i = 0; i < 20; i++) {
        cleanupStarted = false;
        final c = HttpClient();
        final req = await c.getUrl(Uri.parse('http://127.0.0.1:${server.port}/'));
        unawaited(req.close().then<void>((_) {}, onError: (_) {}));
        await Future<void>.delayed(Duration(milliseconds: i % 8));
        c.close(force: true);
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      final end = DateTime.now().add(const Duration(seconds: 3));
      while (cleanups < 20 && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await server.close();

      expect(cleanups, 20);
      expect(stepsAfterCleanup, 0);
    });

    test('inFlight counts requests until their cleanup hooks finish', () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      final server = await BackendServer.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
        handler: (request) async {
          entered.complete();
          await gate.future;
          return Response.ok();
        },
      );
      expect(server.inFlight, 0);
      final pending = client
          .getUrl(Uri.parse('http://127.0.0.1:${server.port}/'))
          .then((r) => r.close())
          .then((r) => r.drain<void>());
      await entered.future;
      expect(server.inFlight, 1);
      gate.complete();
      await pending;
      await server.close();
      expect(server.inFlight, 0);
    });
  });
}
