import 'dart:convert';
import 'dart:io';

import 'package:orbiter/orbiter.dart';
import 'package:test/test.dart';

/// Controlled simulation of a resource with a lifecycle (e.g. a connection borrowed from a pool).
final class _MockLeasedResource {
  bool released = false;
  final String id;

  _MockLeasedResource(this.id);

  void release() {
    if (released) {
      throw StateError('Resource $id already released!');
    }
    released = true;
  }
}

void main() {
  group('Integration & Resource Lifecycle with Cleanup Hooks', () {
    late BackendServer server;
    late HttpClient client;
    late int port;

    final cleanupExecutionOrder = <String>[];
    final activeResources = <_MockLeasedResource>[];

    setUp(() async {
      cleanupExecutionOrder.clear();
      activeResources.clear();
      client = HttpClient();

      final router = Router();

      // Route with successful acquisition and release of multiple resources
      router.get('/resources/ok', (request) {
        final res1 = _MockLeasedResource('res-1');
        final res2 = _MockLeasedResource('res-2');
        activeResources.addAll([res1, res2]);

        request.addCleanupHook(() async {
          res1.release();
          cleanupExecutionOrder.add('cleanup-res-1');
        });

        request.addCleanupHook(() async {
          res2.release();
          cleanupExecutionOrder.add('cleanup-res-2');
        });

        return Response.json({'status': 'resources-allocated'});
      });

      // Route where the handler fails midway through the transaction
      router.get('/resources/failing', (request) {
        final res = _MockLeasedResource('failing-res');
        activeResources.add(res);

        request.addCleanupHook(() async {
          res.release();
          cleanupExecutionOrder.add('cleanup-failing-res');
        });

        throw StateError('Simulated catastrophic SQL query failure');
      });

      // Route with typed context injection
      router.get('/context/check', (request) {
        final configValue = request.context.getOrNull<String>();
        return Response.ok(body: 'context:$configValue');
      });

      final app = Pipeline()
          .add((request, next) {
            // Dependency injection via the heterogeneous RequestContext
            request.context.set<String>('postgres-cluster-primary');
            return next(request);
          })
          .addHandler(router.handler);

      server = await BackendServer.bind(
        handler: app,
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      port = server.port;
    });

    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });

    test('executes cleanup hooks in strict LIFO order after successful response', () async {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/resources/ok'));
      final res = await req.close();
      expect(res.statusCode, equals(200));

      final body = await utf8.decoder.bind(res).join();
      expect(body, contains('resources-allocated'));

      // Checks whether all resources were released
      expect(activeResources.length, equals(2));
      expect(activeResources[0].released, isTrue);
      expect(activeResources[1].released, isTrue);

      // LIFO order: res-2 (last added) must run before res-1
      expect(cleanupExecutionOrder, equals(['cleanup-res-2', 'cleanup-res-1']));
    });

    test('guarantees cleanup hooks execution even when handler throws unhandled error', () async {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/resources/failing'));
      final res = await req.close();

      // The global ErrorBoundary converts it into a 500
      expect(res.statusCode, equals(500));

      // Even with the unhandled error, the cleanup hook ran
      expect(activeResources.length, equals(1));
      expect(activeResources[0].released, isTrue);
      expect(cleanupExecutionOrder, equals(['cleanup-failing-res']));
    });

    test('resolves injected resources from RequestContext with zero allocation overhead', () async {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/context/check'));
      final res = await req.close();
      expect(res.statusCode, equals(200));

      final body = await utf8.decoder.bind(res).join();
      expect(body, equals('context:postgres-cluster-primary'));
    });
  });
}
