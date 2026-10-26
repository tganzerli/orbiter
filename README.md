# orbiter

[![pub package](https://img.shields.io/pub/v/orbiter.svg)](https://pub.dev/packages/orbiter)
[![pub points](https://img.shields.io/pub/points/orbiter)](https://pub.dev/packages/orbiter/score)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**An HTTP backend framework for Dart designed to stay close to raw `dart:io`, with the routing, interceptors and
cleanup you would otherwise write by hand.**

On a simple endpoint, a large share of a Dart server's time can go to the framework rather than to your code:
wrapper objects, buffered bodies, zone lookups, a middleware chain rebuilt on every call. orbiter is designed
around removing that overhead. Responses stream straight to `dart:io`'s `HttpResponse`, the interceptor chain is
folded once at startup, routes are matched in a radix tree, and per-request state lives on the request itself
instead of in zones. What you get on top is the part every backend needs: typed request context, error boundaries,
safe defaults, and cleanup hooks that run only after the response is fully written, so a pooled database connection
always goes back.

It has no database dependency. Each database gets a small kit package that wires it in; for PostgreSQL that is
[`orbiter_postgres`](https://pub.dev/packages/orbiter_postgres), with one row-level-security transaction per
request in a single interceptor.

## Features

- **Streaming responses:** bodies go straight to `HttpResponse`, with no pre-buffering and few intermediate objects
  on the request path.
- **Pipeline folded at startup:** interceptors are composed once, when the handler is built, so a request pays no
  chain-assembly cost; any interceptor can short-circuit.
- **Radix router:** lookup by path segment, static routes before dynamic ones, parameters (`:id`), wildcards
  (`*path`), and correct `404` and `405` with the `Allow` header.
- **Typed request context without zones:** `request.context.set(value)` / `get<T>()`, stored on the request.
- **Guaranteed cleanup:** hooks run in reverse order after the response is written (streamed bodies included),
  also on uncaught errors and client disconnects.
- **Safe defaults:** a 1 MiB body limit, generic `500`s to the client with details only on the server, CORS that
  refuses `*` with credentials, graceful shutdown that drains in-flight requests; `securityHeaders()` and
  `requestLogger()` ready to add.

## Install

```sh
dart pub add orbiter
```

Experimental (pre-1.0).

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

[`example/main.dart`](example/main.dart) adds an interceptor of its own and a graceful shutdown.

## The family

| Package | Role |
|---|---|
| [`orbiter`](https://pub.dev/packages/orbiter) | This framework. |
| [`orbiter_postgres`](https://pub.dev/packages/orbiter_postgres) | PostgreSQL kit: one row-level-security transaction per request, prefix search. |
| [`slingshot_postgres`](https://pub.dev/packages/slingshot_postgres) | PostgreSQL driver over `libpq`, with a native connection pool. |
| [`slingshot`](https://pub.dev/packages/slingshot) | The contract every slingshot driver implements. |

An app depends on the framework and on the kit of each database it uses.

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

A runnable CRUD server wired to `slingshot_postgres` is the example of
[`orbiter_postgres`](https://pub.dev/packages/orbiter_postgres/example), because it is the package that depends on
both.

## Benchmarks and research

The project started as an MBA thesis in Software Engineering at the University of São Paulo (USP), whose
cross-language benchmark suite found that, on endpoints without database access, swapping the HTTP framework for a
raw `dart:io` server raised throughput by 55% to 60% with the same driver. orbiter was built from that finding. The
suite, the results and the evaluated code are public at
[tganzerli/dart_db_connector](https://github.com/tganzerli/dart_db_connector) (see
[`benchmarks/RESULTS.md`](https://github.com/tganzerli/dart_db_connector/blob/main/benchmarks/RESULTS.md)).
orbiter's own throughput measurements are not published there yet.

## License

MIT, see `LICENSE`.
