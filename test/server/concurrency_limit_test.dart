import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:orbiter/orbiter.dart';
import 'package:orbiter/src/server/concurrency_limit.dart' show AdmissionGate;
import 'package:test/test.dart';

void main() {
  group('ConcurrencyLimit', () {
    test('maxQueued defaults to maxInFlight; Retry-After rounds up', () {
      final l = ConcurrencyLimit(
          maxInFlight: 4, retryAfter: const Duration(milliseconds: 1500));
      expect(l.maxQueued, 4);
      expect(l.retryAfterSeconds, 2);
      expect(ConcurrencyLimit(maxInFlight: 1).retryAfterSeconds, 1);
      expect(
          ConcurrencyLimit(maxInFlight: 1, retryAfter: Duration.zero)
              .retryAfterSeconds,
          0);
    });

    test('rejects invalid values', () {
      expect(() => ConcurrencyLimit(maxInFlight: 0), throwsArgumentError);
      expect(() => ConcurrencyLimit(maxInFlight: 1, maxQueued: -1),
          throwsArgumentError);
      expect(
          () => ConcurrencyLimit(
              maxInFlight: 1, queueTimeout: const Duration(seconds: -1)),
          throwsArgumentError);
      expect(
          () => ConcurrencyLimit(
              maxInFlight: 1, retryAfter: const Duration(seconds: -1)),
          throwsArgumentError);
    });
  });

  group('AdmissionGate', () {
    test('admits up to maxInFlight, then queues, then refuses', () async {
      final gate = AdmissionGate(ConcurrencyLimit(
          maxInFlight: 2,
          maxQueued: 1,
          queueTimeout: const Duration(seconds: 5)));
      expect(gate.acquire(), isTrue);
      expect(gate.acquire(), isTrue);
      final third = gate.acquire();
      expect(third, isA<Future<bool>>());
      expect(gate.queued, 1);
      expect(gate.acquire(), isFalse);
      expect(gate.rejected, 1);
      gate.release();
      expect(await third, isTrue);
      expect(gate.active, 2, reason: 'the slot passed straight to the waiter');
      expect(gate.queued, 0);
      gate
        ..release()
        ..release();
      expect(gate.active, 0);
    });

    test('waiters get the slot in arrival order', () async {
      final gate = AdmissionGate(ConcurrencyLimit(
          maxInFlight: 1,
          maxQueued: 3,
          queueTimeout: const Duration(seconds: 5)));
      expect(gate.acquire(), isTrue);
      final order = <int>[];
      final waits = [
        for (var i = 0; i < 3; i++)
          (gate.acquire() as Future<bool>).then((ok) => order.add(i)),
      ];
      for (var i = 0; i < 3; i++) {
        gate.release();
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait(waits);
      expect(order, [0, 1, 2]);
    });

    test('a waiter past queueTimeout is refused and leaves the queue',
        () async {
      final gate = AdmissionGate(ConcurrencyLimit(
          maxInFlight: 1,
          maxQueued: 1,
          queueTimeout: const Duration(milliseconds: 20)));
      expect(gate.acquire(), isTrue);
      expect(await (gate.acquire() as Future<bool>), isFalse);
      expect(gate.queued, 0);
      expect(gate.rejected, 1);
      gate.release();
      expect(gate.active, 0);
    });
  });

  group('HttpDispatcher with a ConcurrencyLimit', () {
    late HttpServer server;
    late HttpClient client;
    late Uri base;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://${server.address.host}:${server.port}/');
      client = HttpClient()..maxConnectionsPerHost = 16;
    });

    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });

    Future<(int, String, String?)> get(String path) async {
      final req = await client.getUrl(base.resolve(path));
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      return (res.statusCode, body, res.headers.value('retry-after'));
    }

    // Waits until [dispatcher] has [n] admitted and [q] queued requests.
    Future<void> settle(HttpDispatcher d, {int? admitted, int? queued}) async {
      for (var i = 0; i < 500; i++) {
        if ((admitted == null || d.admitted == admitted) &&
            (queued == null || d.queued == queued)) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      fail('dispatcher did not settle: admitted=${d.admitted} '
          'queued=${d.queued}');
    }

    test('full slots and no queue: immediate 503, handler not called',
        () async {
      final release = Completer<void>();
      final calls = <String>[];
      final d = HttpDispatcher(
        rootHandler: (r) async {
          calls.add(r.uri.path);
          await release.future;
          return Response.ok(body: 'ok');
        },
        concurrencyLimit: ConcurrencyLimit(maxInFlight: 2, maxQueued: 0),
      );
      server.listen(d.dispatch);

      final a = get('/a');
      final b = get('/b');
      await settle(d, admitted: 2);
      final (status, body, retryAfter) = await get('/c');
      expect(status, 503);
      expect(retryAfter, '1');
      expect(jsonDecode(body), {'error': 'Service Unavailable', 'code': 503});
      expect(calls, unorderedEquals(['/a', '/b']));
      expect(d.rejected, 1);

      release.complete();
      expect((await a).$1, 200);
      expect((await b).$1, 200);
      expect(await d.drain(const Duration(seconds: 2)), isTrue);
      expect(d.admitted, 0);
    });

    test('queued requests are served in arrival order when a slot frees',
        () async {
      final gates = <String, Completer<void>>{};
      final started = <String>[];
      final d = HttpDispatcher(
        rootHandler: (r) async {
          started.add(r.uri.path);
          await (gates[r.uri.path] ??= Completer<void>()).future;
          return Response.ok(body: r.uri.path);
        },
        concurrencyLimit: ConcurrencyLimit(
            maxInFlight: 1,
            maxQueued: 2,
            queueTimeout: const Duration(seconds: 5)),
      );
      server.listen(d.dispatch);

      for (final p in ['/1', '/2', '/3']) {
        gates[p] = Completer<void>();
      }
      final first = get('/1');
      await settle(d, admitted: 1);
      final second = get('/2');
      await settle(d, queued: 1);
      final third = get('/3');
      await settle(d, queued: 2);
      expect(started, ['/1']);

      gates['/1']!.complete();
      expect((await first).$2, '/1');
      await settle(d, queued: 1);
      expect(started, ['/1', '/2']);
      gates['/2']!.complete();
      expect((await second).$2, '/2');
      gates['/3']!.complete();
      expect((await third).$2, '/3');
      expect(started, ['/1', '/2', '/3']);
      expect(d.rejected, 0);
    });

    test('a request past queueTimeout gets 503 and its handler never runs',
        () async {
      final release = Completer<void>();
      final calls = <String>[];
      final d = HttpDispatcher(
        rootHandler: (r) async {
          calls.add(r.uri.path);
          await release.future;
          return Response.ok();
        },
        concurrencyLimit: ConcurrencyLimit(
            maxInFlight: 1,
            maxQueued: 1,
            queueTimeout: const Duration(milliseconds: 30),
            retryAfter: const Duration(seconds: 3)),
      );
      server.listen(d.dispatch);

      final a = get('/a');
      await settle(d, admitted: 1);
      final (status, _, retryAfter) = await get('/late');
      expect(status, 503);
      expect(retryAfter, '3');
      expect(calls, ['/a']);
      release.complete();
      expect((await a).$1, 200);
    });

    test('the slot is held until the cleanup hooks finish', () async {
      final hookDone = Completer<void>();
      final calls = <String>[];
      final d = HttpDispatcher(
        rootHandler: (r) {
          calls.add(r.uri.path);
          if (r.uri.path == '/a') r.addCleanupHook(() => hookDone.future);
          return Response.ok(body: r.uri.path);
        },
        concurrencyLimit: ConcurrencyLimit(
            maxInFlight: 1,
            maxQueued: 1,
            queueTimeout: const Duration(seconds: 5)),
      );
      server.listen(d.dispatch);

      // /a answers at once but its hook is still pending.
      expect((await get('/a')).$1, 200);
      expect(d.admitted, 1);
      final b = get('/b');
      await settle(d, queued: 1);
      expect(calls, ['/a']);
      hookDone.complete();
      expect((await b).$2, '/b');
    });

    test('a handler that throws gives its slot back', () async {
      final d = HttpDispatcher(
        rootHandler: (r) =>
            r.uri.path == '/boom' ? throw StateError('boom') : Response.ok(),
        onError: (_, __, ___) {},
        concurrencyLimit: ConcurrencyLimit(maxInFlight: 1, maxQueued: 0),
      );
      server.listen(d.dispatch);

      expect((await get('/boom')).$1, 500);
      expect(d.admitted, 0);
      expect((await get('/ok')).$1, 200);
      expect(d.rejected, 0);
    });

    test('drain waits for queued requests too', () async {
      final release = Completer<void>();
      final d = HttpDispatcher(
        rootHandler: (r) async {
          await release.future;
          return Response.ok();
        },
        concurrencyLimit: ConcurrencyLimit(
            maxInFlight: 1,
            maxQueued: 1,
            queueTimeout: const Duration(seconds: 5)),
      );
      server.listen(d.dispatch);

      final a = get('/a');
      await settle(d, admitted: 1);
      final b = get('/b');
      await settle(d, queued: 1);
      expect(d.inFlight, 2);
      expect(await d.drain(const Duration(milliseconds: 30)), isFalse);
      release.complete();
      await Future.wait([a, b]);
      expect(await d.drain(const Duration(seconds: 2)), isTrue);
    });

    Future<HttpClientResponse> send(String path, {String? origin}) async {
      final req = await client.getUrl(base.resolve(path));
      if (origin != null) req.headers.set('origin', origin);
      return req.close();
    }

    // Takes the only slot with a request parked on [release].
    Future<Future<(int, String, String?)>> occupy(HttpDispatcher d) async {
      final held = get('/held');
      await settle(d, admitted: 1);
      return held;
    }

    Handler parking(Completer<void> release, [List<String>? calls]) =>
        (r) async {
          calls?.add(r.uri.path);
          if (r.uri.path == '/held') await release.future;
          return Response.ok(body: r.uri.path);
        };

    test('default refusal is byte for byte the pre-built one', () async {
      final release = Completer<void>();
      final d = HttpDispatcher(
        rootHandler: parking(release),
        concurrencyLimit: ConcurrencyLimit(
            maxInFlight: 1,
            maxQueued: 0,
            retryAfter: const Duration(seconds: 2)),
      );
      server.listen(d.dispatch);
      final held = await occupy(d);

      final res = await send('/x', origin: 'https://app.example');
      final body = await utf8.decoder.bind(res).join();
      expect(res.statusCode, 503);
      expect(
          res.headers.value('content-type'), 'application/json; charset=utf-8');
      expect(res.headers.value('retry-after'), '2');
      expect(res.headers.value('access-control-allow-origin'), isNull);
      expect(body, '{"error":"Service Unavailable","code":503}');
      release.complete();
      expect((await held).$1, 200);
    });

    for (final async in [false, true]) {
      test(
          'rejectResponse (${async ? 'async' : 'sync'}) sees the request and '
          'its headers go out, with retry-after added', () async {
        final release = Completer<void>();
        final calls = <String>[];
        final seen = <(String?, int)>[];
        Response build(Request r, int retryAfter) {
          seen.add((r.getHeader('origin'), retryAfter));
          return Response.json(
            {'message': 'busy'},
            statusCode: 503,
            headers: {
              'access-control-allow-origin': [r.getHeader('origin') ?? '*'],
            },
          );
        }

        final d = HttpDispatcher(
          rootHandler: parking(release, calls),
          concurrencyLimit: ConcurrencyLimit(
            maxInFlight: 1,
            maxQueued: 0,
            retryAfter: const Duration(seconds: 3),
            rejectResponse: async
                ? (r, s) async {
                    await Future<void>.delayed(Duration.zero);
                    return build(r, s);
                  }
                : build,
          ),
        );
        server.listen(d.dispatch);
        final held = await occupy(d);

        final res = await send('/x', origin: 'https://app.example');
        final body = await utf8.decoder.bind(res).join();
        expect(res.statusCode, 503);
        expect(res.headers.value('access-control-allow-origin'),
            'https://app.example');
        expect(res.headers.value('retry-after'), '3');
        expect(jsonDecode(body), {'message': 'busy'});
        expect(seen, [('https://app.example', 3)]);
        expect(calls, ['/held'], reason: 'the handler never runs');
        expect(d.rejected, 1);
        release.complete();
        expect((await held).$1, 200);
      });
    }

    test('a retry-after set by rejectResponse is kept', () async {
      final release = Completer<void>();
      final d = HttpDispatcher(
        rootHandler: parking(release),
        concurrencyLimit: ConcurrencyLimit(
          maxInFlight: 1,
          maxQueued: 0,
          rejectResponse: (r, s) => Response(429, headers: {
            'Retry-After': ['9'],
          }),
        ),
      );
      server.listen(d.dispatch);
      final held = await occupy(d);

      final res = await send('/x');
      await res.drain<void>();
      expect(res.statusCode, 429);
      expect(res.headers['retry-after'], ['9']);
      release.complete();
      await held;
    });

    for (final async in [false, true]) {
      test(
          'rejectResponse that ${async ? 'fails its future' : 'throws'}: '
          'default refusal, reported, slots intact', () async {
        final release = Completer<void>();
        final errors = <Object>[];
        final d = HttpDispatcher(
          rootHandler: parking(release),
          onError: (e, _, __) => errors.add(e),
          concurrencyLimit: ConcurrencyLimit(
            maxInFlight: 1,
            maxQueued: 0,
            rejectResponse: async
                ? (r, s) async {
                    await Future<void>.delayed(Duration.zero);
                    throw StateError('async boom');
                  }
                : (r, s) => throw StateError('boom'),
          ),
        );
        server.listen(d.dispatch);
        final held = await occupy(d);

        final (status, body, retryAfter) = await get('/x');
        expect(status, 503);
        expect(retryAfter, '1');
        expect(body, '{"error":"Service Unavailable","code":503}');
        expect(errors, [isA<StateError>()]);
        expect(d.rejected, 1);
        expect(d.admitted, 1);

        release.complete();
        expect((await held).$1, 200);
        expect(await d.drain(const Duration(seconds: 2)), isTrue);
        expect(d.admitted, 0);
        expect((await get('/next')).$1, 200, reason: 'next one is admitted');
      });
    }

    test('a request past queueTimeout gets the rejectResponse too', () async {
      final release = Completer<void>();
      final d = HttpDispatcher(
        rootHandler: parking(release),
        concurrencyLimit: ConcurrencyLimit(
          maxInFlight: 1,
          maxQueued: 1,
          queueTimeout: const Duration(milliseconds: 30),
          rejectResponse: (r, s) => Response(503, body: 'late'),
          exempt: (r) => r.uri.path == '/ready',
        ),
      );
      server.listen(d.dispatch);
      final held = await occupy(d);

      final late = get('/late');
      await settle(d, queued: 1);
      expect((await get('/ready')).$1, 200, reason: 'exempt skips the queue');
      final (status, body, retryAfter) = await late;
      expect((status, body, retryAfter), (503, 'late', '1'));
      expect(d.rejected, 1);
      release.complete();
      expect((await held).$1, 200);
    });

    test('cleanup hooks registered by rejectResponse run after the write',
        () async {
      final release = Completer<void>();
      final events = <String>[];
      final d = HttpDispatcher(
        rootHandler: parking(release),
        concurrencyLimit: ConcurrencyLimit(
          maxInFlight: 1,
          maxQueued: 0,
          rejectResponse: (r, s) {
            r.addCleanupHook(() => events.add('hook'));
            return Response(503, body: 'busy');
          },
        ),
      );
      server.listen(d.dispatch);
      final held = await occupy(d);

      expect((await get('/x')).$2, 'busy');
      release.complete();
      await held;
      expect(await d.drain(const Duration(seconds: 2)), isTrue);
      expect(events, ['hook']);
    });

    test('exempt requests skip the limit; the others are refused', () async {
      final release = Completer<void>();
      final d = HttpDispatcher(
        rootHandler: parking(release),
        concurrencyLimit: ConcurrencyLimit(
          maxInFlight: 1,
          maxQueued: 0,
          exempt: (r) => r.uri.path == '/ready',
        ),
      );
      server.listen(d.dispatch);
      final held = await occupy(d);

      final ready = await get('/ready');
      expect(ready.$1, 200);
      expect(ready.$2, '/ready');
      expect((await get('/x')).$1, 503);
      expect(d.admitted, 1);
      expect(d.queued, 0);
      expect(d.rejected, 1);

      release.complete();
      await held;
      expect(await d.drain(const Duration(seconds: 2)), isTrue);
      expect(d.admitted, 0, reason: 'the exempt request never took a slot');
    });

    test('an exempt predicate that throws sends the request through the limit',
        () async {
      final release = Completer<void>();
      final errors = <Object>[];
      final d = HttpDispatcher(
        rootHandler: parking(release),
        onError: (e, _, __) => errors.add(e),
        concurrencyLimit: ConcurrencyLimit(
          maxInFlight: 1,
          maxQueued: 0,
          exempt: (r) =>
              r.uri.path == '/held' ? false : throw StateError('predicate'),
        ),
      );
      server.listen(d.dispatch);
      final held = await occupy(d);

      expect((await get('/x')).$1, 503);
      expect(errors, [isA<StateError>()]);
      expect(d.rejected, 1);
      release.complete();
      await held;
    });

    test('without a limit nothing is counted or refused', () async {
      final d = HttpDispatcher(rootHandler: (r) => Response.ok());
      server.listen(d.dispatch);
      final results = await Future.wait([for (var i = 0; i < 8; i++) get('/')]);
      expect(results.map((r) => r.$1), everyElement(200));
      expect(d.concurrencyLimit, isNull);
      expect(d.admitted, 0);
      expect(d.rejected, 0);
    });
  });
}
