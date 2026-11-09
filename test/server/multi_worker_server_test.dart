import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:orbiter/orbiter.dart';
import 'package:test/test.dart';

// Setups are built by top-level factories so each closure captures only what it
// names (a SendPort), never an unsendable local of the test body.

/// Answers every request with the worker id; `/slow` waits first, `/crash` on
/// worker 1 throws an uncaught error that ends that isolate.
WorkerApp _idApp(WorkerContext context, {SendPort? events}) => WorkerApp(
      handler: (request) async {
        switch (request.uri.path) {
          case '/slow':
            await Future<void>.delayed(const Duration(milliseconds: 300));
          case '/crash' when context.id == 1:
            scheduleMicrotask(() => throw StateError('boom'));
          case '/drain-crash':
            // Dies while the worker drains, after close() was called.
            Timer(const Duration(milliseconds: 200),
                () => throw StateError('boom while draining'));
            await Future<void>.delayed(const Duration(seconds: 1));
        }
        return Response.ok(body: '${context.id}');
      },
      onShutdown:
          events == null ? null : () => events.send('shutdown:${context.id}'),
    );

WorkerSetup _reportingSetup(SendPort events) => (context) {
      events.send('setup:${context.id}/${context.workerCount}');
      return _idApp(context, events: events);
    };

WorkerSetup _failingSetup(SendPort events, int failingId) => (context) {
      if (context.id == failingId) throw StateError('no database');
      return _idApp(context, events: events);
    };

WorkerApp _plainSetup(WorkerContext context) => _idApp(context);

/// Worker 0 comes up and dies shortly after; the others take longer to set up,
/// so it dies while they are still starting.
Future<WorkerApp> _diesDuringStartSetup(WorkerContext context) async {
  if (context.id == 0) {
    Timer(
        const Duration(milliseconds: 50), () => throw StateError('died early'));
  } else {
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return _idApp(context);
}

Future<(int, String)> _get(HttpClient client, int port,
    [String path = '/']) async {
  final request =
      await client.get(InternetAddress.loopbackIPv4.address, port, path);
  request.persistentConnection = false;
  final response = await request.close();
  return (response.statusCode, await response.transform(utf8.decoder).join());
}

/// Collects messages sent by the workers to the test isolate.
final class _Events {
  final ReceivePort port = ReceivePort();
  final List<String> received = [];
  _Events() {
    port.listen((message) => received.add(message as String));
  }
  SendPort get sendPort => port.sendPort;
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));
  void close() => port.close();
}

void main() {
  late HttpClient client;
  final servers = <MultiWorkerServer>[];

  setUp(() => client = HttpClient());
  tearDown(() async {
    client.close(force: true);
    for (final server in servers) {
      await server.close(force: true, drainTimeout: Duration.zero);
    }
    servers.clear();
  });

  Future<MultiWorkerServer> start(
    WorkerSetup setup, {
    int workers = 3,
    ErrorReporter? onError,
  }) async {
    final server = await MultiWorkerServer.start(
      setup: setup,
      workers: workers,
      address: InternetAddress.loopbackIPv4,
      port: 0,
      onError: onError,
    );
    servers.add(server);
    return server;
  }

  test('workers share one ephemeral port and split the connections', () async {
    final server = await start(_plainSetup);
    expect(server.port, greaterThan(0));
    expect(server.workerCount, 3);

    final results = await Future.wait([
      for (var i = 0; i < 200; i++) _get(client, server.port),
    ]);
    expect(results.map((r) => r.$1), everyElement(200));
    final ids = results.map((r) => r.$2).toSet();
    expect(ids, everyElement(isIn(['0', '1', '2'])));
    expect(ids.length, greaterThanOrEqualTo(2));
  });

  test('setup runs once per worker, inside it, with its own id', () async {
    final events = _Events();
    addTearDown(events.close);
    await start(_reportingSetup(events.sendPort));
    await events.settle();
    expect(events.received,
        unorderedEquals(['setup:0/3', 'setup:1/3', 'setup:2/3']));
  });

  test(
      'close runs every shutdown hook before resolving, then the port is closed',
      () async {
    final events = _Events();
    addTearDown(events.close);
    final reports = <Object>[];
    final server = await start(
      _reportingSetup(events.sendPort),
      onError: (error, _, __) => reports.add(error),
    );
    final port = server.port;

    await server.close();
    // The hooks ran before close() resolved; their messages travel on another
    // port, so give them time to arrive.
    await events.settle();
    expect(
      events.received.where((e) => e.startsWith('shutdown:')),
      unorderedEquals(['shutdown:0', 'shutdown:1', 'shutdown:2']),
    );
    await expectLater(_get(client, port), throwsA(isA<SocketException>()));
    expect(identical(server.close(), server.close()), isTrue);
    expect(reports, isEmpty, reason: 'a requested shutdown is not an error');
  });

  test('close drains a request already in flight', () async {
    final server = await start(_plainSetup, workers: 2);
    final slow = _get(client, server.port, '/slow');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await server.close();
    final (status, _) = await slow;
    expect(status, 200);
  });

  test('a failing setup fails start and shuts down the workers already up',
      () async {
    final events = _Events();
    addTearDown(events.close);
    await expectLater(
      MultiWorkerServer.start(
        setup: _failingSetup(events.sendPort, 1),
        workers: 3,
        address: InternetAddress.loopbackIPv4,
        port: 0,
      ),
      throwsA(
        isA<MultiWorkerStartException>()
            .having((e) => e.workerId, 'workerId', 1)
            .having((e) => '${e.cause}', 'cause', contains('no database')),
      ),
    );
    await events.settle();
    expect(events.received, containsAll(['shutdown:0', 'shutdown:2']));
  });

  test('a failure in the first worker fails start', () async {
    final events = _Events();
    addTearDown(events.close);
    await expectLater(
      MultiWorkerServer.start(
        setup: _failingSetup(events.sendPort, 0),
        workers: 2,
        address: InternetAddress.loopbackIPv4,
        port: 0,
      ),
      throwsA(isA<MultiWorkerStartException>()
          .having((e) => e.workerId, 'workerId', 0)),
    );
  });

  test('a worker that dies while the others start fails start', () async {
    final reports = <Object>[];
    await expectLater(
      MultiWorkerServer.start(
        setup: _diesDuringStartSetup,
        workers: 2,
        address: InternetAddress.loopbackIPv4,
        port: 0,
        onError: (error, _, __) => reports.add(error),
      ),
      throwsA(
        isA<MultiWorkerStartException>()
            .having((e) => e.workerId, 'workerId', 0)
            .having((e) => '${e.cause}', 'cause', contains('died early')),
      ),
    );
    expect(reports, isEmpty, reason: 'a failed start is thrown, not reported');
  });

  test('a setup that captures an unsendable object fails start', () async {
    final unsendable = ReceivePort();
    addTearDown(unsendable.close);
    await expectLater(
      MultiWorkerServer.start(
        setup: (context) {
          unsendable.hashCode;
          return _idApp(context);
        },
        workers: 2,
        address: InternetAddress.loopbackIPv4,
        port: 0,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a worker that dies is reported and the others keep serving', () async {
    final reports = <Object>[];
    final reported = Completer<void>();
    final server = await start(
      _plainSetup,
      workers: 2,
      onError: (error, _, __) {
        reports.add(error);
        if (!reported.isCompleted) reported.complete();
      },
    );

    // Connections land on any worker; only worker 1 crashes. The connection open
    // on the worker that dies is never answered, so the crash requests are not
    // awaited.
    while (!reported.isCompleted) {
      unawaited(
        _get(client, server.port, '/crash')
            .timeout(const Duration(seconds: 1))
            .then<void>((_) {}, onError: (_) {}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await reported.future.timeout(const Duration(seconds: 5));

    final results = await Future.wait([
      for (var i = 0; i < 20; i++) _get(client, server.port),
    ]);
    expect(results.map((r) => r.$1), everyElement(200));
    expect(results.map((r) => r.$2), everyElement('0'));
    expect(reports, [
      isA<WorkerExitedException>()
          .having((e) => e.workerId, 'workerId', 1)
          .having((e) => '${e.cause}', 'cause', contains('boom')),
    ]);
  });

  test('a worker that dies while draining is reported', () async {
    final reports = <Object>[];
    final server = await start(
      _plainSetup,
      workers: 1,
      onError: (error, _, __) => reports.add(error),
    );
    unawaited(
      _get(client, server.port, '/drain-crash').then<void>(
        (_) {},
        onError: (_) {},
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await server.close().timeout(const Duration(seconds: 5));
    expect(reports, [
      isA<WorkerExitedException>()
          .having((e) => e.workerId, 'workerId', 0)
          .having((e) => '${e.cause}', 'cause', contains('while draining')),
    ]);
  });

  test('workers below 1 is rejected', () {
    expect(
      () => MultiWorkerServer.start(setup: _plainSetup, workers: 0, port: 0),
      throwsArgumentError,
    );
  });
}
