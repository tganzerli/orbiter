# orbiter

High-throughput, low-allocation HTTP backend framework for Dart.

## Overview

`orbiter` is an HTTP transport and execution framework designed to avoid unnecessary
garbage-collector pressure and to stay close to the throughput of raw `dart:io`.

It has no database dependency. Each database gets one kit, a separate package that holds the pieces for using the
framework together with that database's connector:
[`orbiter_postgres`](https://github.com/tganzerli/orbiter_postgres) is the PostgreSQL
kit over [`slingshot_postgres`](https://github.com/tganzerli/slingshot_postgres), with a per-request
row-level-security transaction (`rlsTransaction`) and a prefix search builder (`prefixTsQuery`). An app depends on
the framework and on the kit of each database it uses (several are fine).

Experimental (pre-1.0). Install from pub.dev:

```sh
dart pub add orbiter
```

## Core Architecture Principles

1. **High Throughput & Low Allocation (P1/P2)**: Direct streaming to native `HttpResponse` without pre-buffering; minimal intermediate objects in the request critical path.
2. **Type-Safe RequestContext without Zone (P3)**: Heterogeneous O(1) typed storage directly on the `Request` instance, avoiding the asynchronous performance tax of Dart `ZoneValues`.
3. **Composable Pre-Folded Pipeline (P4)**: Interceptors chained and statically folded at server startup with zero per-request allocation overhead and short-circuit support.
4. **Radix/Trie High Performance Router (P5)**: O(k) URL segment lookup with static route precedence, dynamic parameters (`:id`), wildcards (`*path`), 405 Method Not Allowed (`Allow` header) and 404 Not Found.
5. **Guaranteed Lifecycle Cleanup (P6)**: LIFO execution of cleanup hooks (`request.addCleanupHook`) in a `try/finally` that closes only **after the response is fully written** (streamed bodies included), so connections borrowed from pools are released deterministically, also upon uncaught errors or client TCP disconnects.
6. **Decoupled Architecture (P7)**: Database-agnostic web transport; database access lives in the app or in a database kit.

## Quickstart

```dart
import 'dart:io';
import 'package:orbiter/orbiter.dart';

void main() async {
  final router = Router();

  router.get('/health', (request) => Response.json({'status': 'ok'}));
  router.get('/users/:id', (request) {
    final id = request.pathParam('id');
    return Response.ok(body: 'User: $id');
  });

  final app = Pipeline()
      .add(securityHeaders())
      .add(requestLogger())
      .addHandler(router.handler);

  final server = await BackendServer.bind(
    handler: app,
    address: InternetAddress.anyIPv4,
    port: 8080,
  );

  print('Server listening on http://localhost:${server.port}');
}
```

## Writing an interceptor

An interceptor receives the request and `next`, the rest of the pipeline. It either returns a `Response` itself,
which ends the request there, or calls `next(request)` and may inspect or replace what comes back. Interceptors run
in the order they were added to the `Pipeline`, and the chain is folded once, when `addHandler` is called.

The plain form is a function with the `InterceptorFunction` signature:

```dart
FutureOr<Response> requireApiKey(Request request, NextFunction next) {
  final key = request.getHeader('x-api-key');
  if (key == null) return Response.unauthorized();
  request.context.set(ApiKey(key)); // typed, one value per type
  return next(request);
}

// In a handler further down:
final key = request.context.get<ApiKey>(); // getOrNull<ApiKey>() when it may be absent
```

When the interceptor holds configuration or state, implement `Interceptor` and add its `intercept` method:

```dart
final class Timing implements Interceptor {
  Timing(this.slowThreshold);
  final Duration slowThreshold;

  @override
  Future<Response> intercept(Request request, NextFunction next) async {
    final watch = Stopwatch()..start();
    final response = await next(request);
    if (watch.elapsed > slowThreshold) print('slow: ${request.uri.path}');
    return response;
  }
}

final app = Pipeline()
    .add(requireApiKey)
    .add(Timing(const Duration(milliseconds: 200)).intercept)
    .addHandler(router.handler);
```

`request.context` is created on first use and lives as long as the request; `setKey` / `getKeyOrNull` store values
under an explicit key when two values share a type. To release a resource after the response is fully written,
register `request.addCleanupHook` instead of relying on code after `next`, which runs before a streamed body ends.

## Errors and logging

Two hooks on `BackendServer.bind` handle failures, and they do different jobs:

* **`errorHandler`** turns an unhandled error into the response the client gets. The default answers `413` for
  `PayloadTooLargeException` and a generic `500` for anything else. A custom handler **replaces** the default, so
  it has to answer the `413` case itself.
* **`onError`** reports the failure on the server side and returns nothing. It receives every unhandled handler
  error (except `PayloadTooLargeException`) and every failure while writing the response, including the ones that
  happen after the client already has the status line. The default writes one line to `stderr`.

```dart
final server = await BackendServer.bind(
  handler: app,
  port: 8080,
  errorHandler: (error, stackTrace, request) => switch (error) {
    PayloadTooLargeException() => Response(413),
    NotFoundError() => Response.notFound(),
    _ => Response.internalServerError(),
  },
  onError: (error, stackTrace, request) =>
      log.severe('${request?.uri.path}', error, stackTrace),
);
```

If the `errorHandler` itself throws, the error goes to `onError` and the client gets a plain `500`.

`requestLogger()` writes one line per request (method, path, status, duration) with `print`; pass `logFn` to send
it somewhere else, e.g. `requestLogger(logFn: log.info)`.

## Safety Defaults

* **Body limit:** `request.readAsBytes()` / `readAsString()` / `readAsJson()` reject bodies above
  `maxBodySize` (default 1 MiB) with `PayloadTooLargeException`, answered as `413`. Configure it in
  `BackendServer.bind(maxBodySize: ...)`; `null` disables the limit.
* **Error reporting:** unhandled handler errors and response-write failures go to `onError`
  (default: one line on `stderr`). The client only sees a generic `500`.
* **Response writing:** an invalid header value (e.g. containing `\r\n`) yields a `500` instead
  of a hanging connection.
* **CORS:** `cors()` with `'*'` answers `Access-Control-Allow-Origin: *` and cannot be combined with
  `allowCredentials`. With an explicit list, the request `Origin` is reflected when allowed (plus
  `Vary: Origin`); other origins get no CORS headers. Only `OPTIONS` requests carrying `Origin` and
  `Access-Control-Request-Method` are treated as preflight.
* **Path parameters** are percent-decoded before reaching the handler.

## Example with PostgreSQL

A runnable CRUD server wired to `slingshot_postgres` lives in the
[`orbiter_postgres`](https://github.com/tganzerli/orbiter_postgres) repository
(`example/postgres_crud_server.dart`), because it is the package that depends on both.

## License

MIT, see `LICENSE`.
