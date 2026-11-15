import 'dart:async';
import 'dart:io';

import '../pipeline/handler.dart';
import 'concurrency_limit.dart';
import 'http_dispatcher.dart';

/// High-performance HTTP server built directly on the [HttpServer] of the `dart:io`
/// runtime.
///
/// Encapsulates the TCP listening lifecycle, allowing shared binding ([shared]) for
/// multi-isolate parallelism and graceful shutdown ([close]).
final class BackendServer {
  final HttpServer _server;
  final HttpDispatcher _dispatcher;

  BackendServer._(this._server, this._dispatcher);

  /// Starts the HTTP listener on the given address and port.
  ///
  /// Parameters:
  /// - [handler]: Root function that serves the requests.
  /// - [address]: Bind address (default: [InternetAddress.anyIPv4]).
  /// - [port]: TCP port to listen on (use `0` for an ephemeral port assigned by the OS).
  /// - [shared]: If `true`, allows multiple isolates to listen on the same TCP port.
  /// - [securityContext]: If provided, starts a secure HTTPS server via
  ///   [HttpServer.bindSecure].
  /// - [errorHandler]: Custom Error Boundary to catch unhandled failures.
  /// - [onError]: Reporter for unhandled errors and write failures (default: `stderr`).
  /// - [maxBodySize]: Request body limit in bytes (default 1 MiB; `null` disables it).
  /// - [backlog]: Size of the socket's pending connection queue.
  /// - [concurrencyLimit]: Admission control (requests at once, queue, 503 with
  ///   `Retry-After`); `null` (the default) admits every request.
  static Future<BackendServer> bind({
    required Handler handler,
    dynamic address,
    required int port,
    bool shared = false,
    SecurityContext? securityContext,
    ErrorHandler? errorHandler,
    ErrorReporter? onError,
    int? maxBodySize = defaultMaxBodySize,
    int backlog = 0,
    ConcurrencyLimit? concurrencyLimit,
  }) async {
    final targetAddress = address ?? InternetAddress.anyIPv4;

    final HttpServer server;
    if (securityContext != null) {
      server = await HttpServer.bindSecure(
        targetAddress,
        port,
        securityContext,
        shared: shared,
        backlog: backlog,
      );
    } else {
      server = await HttpServer.bind(
        targetAddress,
        port,
        shared: shared,
        backlog: backlog,
      );
    }

    final dispatcher = HttpDispatcher(
      rootHandler: handler,
      errorHandler: errorHandler,
      onError: onError,
      maxBodySize: maxBodySize,
      concurrencyLimit: concurrencyLimit,
    );

    final instance = BackendServer._(server, dispatcher);

    server.listen(
      instance._dispatcher.dispatch,
      // Error at the socket stream level; individual connections are handled by the
      // dispatcher.
      onError: instance._dispatcher.report,
      cancelOnError: false,
    );

    return instance;
  }

  /// Effective TCP port the server is listening on.
  int get port => _server.port;

  /// Network address of the server.
  InternetAddress get address => _server.address;

  /// Requests whose cycle (handler, write and cleanup hooks) has not finished yet.
  int get inFlight => _dispatcher.inFlight;

  /// Stops listening for the HTTP server and waits for in-flight requests.
  ///
  /// If [force] is `false` (default), waits for active connections to finish.
  /// If [force] is `true`, immediately closes all open connections; the handlers already
  /// started run to completion and their cleanup hooks still run.
  ///
  /// Resolves only after every in-progress `dispatch` has finished, hooks included (for
  /// example, returning the connection to the pool), so the caller can close the pool
  /// right after. If [drainTimeout] expires first, it reports a [TimeoutException] to
  /// `onError` and returns without throwing: a hung handler cannot be cancelled.
  Future<void> close({
    bool force = false,
    Duration drainTimeout = const Duration(seconds: 30),
  }) async {
    await _server.close(force: force);
    if (!await _dispatcher.drain(drainTimeout)) {
      _dispatcher.report(
        TimeoutException(
          '${_dispatcher.inFlight} request(s) still in flight',
          drainTimeout,
        ),
        StackTrace.current,
      );
    }
  }
}
