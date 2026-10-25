import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../pipeline/handler.dart';
import '../request/payload_too_large_exception.dart';
import '../request/request.dart';
import '../response/response.dart';

/// Signature of the global error handler (Error Boundary).
typedef ErrorHandler = FutureOr<Response> Function(
  Object error,
  StackTrace stackTrace,
  Request request,
);

/// Signature of the error reporter: receives every unhandled failure from the
/// handler and every failure while writing the response. [request] is `null`
/// only if the failure occurs before the [Request] exists.
typedef ErrorReporter = void Function(
  Object error,
  StackTrace stackTrace,
  Request? request,
);

/// How long to wait for a `Stream` body to finish after the response has ended.
const Duration _streamCancelGrace = Duration(seconds: 30);

/// Default request body limit: 1 MiB.
const int defaultMaxBodySize = 1024 * 1024;

/// HTTP dispatch engine that connects low-level requests from [HttpServer]
/// (`dart:io`) to the framework's functional pipeline.
///
/// Responsibilities:
/// - Lightweight mapping from [HttpRequest] to [Request], without buffering or
///   copying headers;
/// - Invoking the [ErrorHandler] (Error Boundary) on unhandled failures;
/// - Reporting every failure through [ErrorReporter];
/// - Writing headers and streaming data to the [HttpResponse], always ending
///   with `close()`, even when the write fails;
/// - Unconditionally running [Request.runCleanupHooks] **after** the response has
///   been fully written (including a `Stream` body).
final class HttpDispatcher {
  /// Root handler that receives the served requests.
  final Handler rootHandler;

  /// Customizable global Error Boundary.
  final ErrorHandler errorHandler;

  /// Error reporter. Default: one line on `stderr`.
  final ErrorReporter onError;

  /// Request body limit in bytes; `null` disables the limit.
  final int? maxBodySize;

  int _inFlight = 0;
  Completer<void>? _idle;

  /// Requests whose cycle (handler, write and cleanup hooks) has not finished yet.
  int get inFlight => _inFlight;

  /// Creates an instance of [HttpDispatcher].
  ///
  /// If [errorHandler] is not provided, [_defaultErrorHandler] is used, which emits
  /// `413` for [PayloadTooLargeException] and HTTP 500 as JSON without internal
  /// details for everything else.
  HttpDispatcher({
    required this.rootHandler,
    ErrorHandler? errorHandler,
    ErrorReporter? onError,
    this.maxBodySize = defaultMaxBodySize,
  })  : errorHandler = errorHandler ?? _defaultErrorHandler,
        onError = onError ?? _defaultReporter;

  /// Processes a single HTTP request emitted by the [HttpServer].
  Future<void> dispatch(HttpRequest ioRequest) async {
    _inFlight++;
    final request = Request.fromHttpRequest(ioRequest, maxBodySize: maxBodySize);

    try {
      Response response;
      try {
        final result = rootHandler(request);
        response = result is Future<Response> ? await result : result;
      } catch (error, stackTrace) {
        response = await _recover(error, stackTrace, request);
      }

      await _writeResponse(response, ioRequest.response, request);
    } finally {
      // Unconditional cleanup guarantee, after the response has been fully written.
      try {
        await request.runCleanupHooks(
          onError: (error, stackTrace) => _report(error, stackTrace, request),
        );
      } finally {
        if (--_inFlight == 0) _idle?.complete();
      }
    }
  }

  /// Waits for all in-flight requests to finish, hooks included.
  ///
  /// Returns `true` when the count reaches zero and `false` if [timeout] expires first.
  Future<bool> drain(Duration timeout) async {
    if (_inFlight == 0) return true;
    final idle = _idle ??= Completer<void>();
    try {
      await idle.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } finally {
      if (identical(_idle, idle) && idle.isCompleted) _idle = null;
    }
  }

  /// Reports [error] to the [ErrorReporter] without ever throwing.
  void report(Object error, StackTrace stackTrace) =>
      _report(error, stackTrace, null);

  Future<Response> _recover(
    Object error,
    StackTrace stackTrace,
    Request request,
  ) async {
    if (error is! PayloadTooLargeException) {
      _report(error, stackTrace, request);
    }
    try {
      return await errorHandler(error, stackTrace, request);
    } catch (handlerError, handlerStack) {
      // Absolute fallback in case the ErrorHandler itself throws
      _report(handlerError, handlerStack, request);
      return _fallbackErrorResponse;
    }
  }

  void _report(Object error, StackTrace stackTrace, Request? request) {
    try {
      onError(error, stackTrace, request);
    } catch (_) {
      // The reporter never breaks the dispatch.
    }
  }

  /// Writes status, headers and body to the [HttpResponse].
  ///
  /// Two phases. Headers: if a value is rejected by `dart:io` (e.g. `\r\n`), nothing
  /// has been sent yet; the applied names are removed and the 500 fallback response
  /// is sent. Body: if the write fails midway, `close()` ends the connection. No
  /// path leaves the response without an attempted `close()`.
  Future<void> _writeResponse(
    Response response,
    HttpResponse ioResponse,
    Request request,
  ) async {
    if (!_applyHead(response, ioResponse, request)) {
      response = _fallbackErrorResponse;
      _applyHead(response, ioResponse, request);
    }

    try {
      final body = response.body;
      if (body != null) {
        if (body is List<int>) {
          ioResponse.add(body);
        } else if (body is String) {
          ioResponse.write(body);
        } else if (body is Stream<List<int>>) {
          await _writeStream(body, ioResponse, request);
        } else if (body is Map || body is List) {
          ioResponse.headers.contentType ??= ContentType.json;
          ioResponse.write(jsonEncode(body));
        } else {
          // Fallback for any other type, serialized via toString
          ioResponse.write(body.toString());
        }
      }
    } catch (error, stackTrace) {
      // A client disconnect (SocketException/HttpException) is routine; anything else is a failure.
      if (error is! SocketException && error is! HttpException) {
        _report(error, stackTrace, request);
      }
    }

    try {
      await ioResponse.close();
    } catch (_) {
      // Socket already closed by the remote client; nothing else to do.
    }
  }

  /// Writes [body] and returns only when the source has actually finished.
  ///
  /// `HttpResponse.addStream` cancels the source when the client goes away but **does
  /// not wait** for the cancellation to finish: a generator in the middle of a step
  /// (for example, a database query) keeps running after the cleanup hooks have
  /// returned the connection to the pool, and then uses a connection that already
  /// belongs to another request. Here the source is wrapped so the dispatcher knows
  /// when the generator has finished (the `yield*` propagates the cancellation and
  /// the `finally` only runs after the source has finished its current step).
  /// Waiting is bounded by [_streamCancelGrace]; if it expires, the dispatcher
  /// reports it and moves on, so a generator that never finishes does not hold the
  /// request forever.
  Future<void> _writeStream(
    Stream<List<int>> body,
    HttpResponse ioResponse,
    Request request,
  ) async {
    var started = false;
    final finished = Completer<void>();
    Stream<List<int>> tracked() async* {
      started = true;
      try {
        yield* body;
      } finally {
        finished.complete();
      }
    }

    try {
      await ioResponse.addStream(tracked());
    } finally {
      if (started) {
        await finished.future.timeout(_streamCancelGrace, onTimeout: () {
          _report(
            TimeoutException(
              'stream body did not finish after the response ended',
              _streamCancelGrace,
            ),
            StackTrace.current,
            request,
          );
        });
      }
    }
  }

  /// Applies status and headers. Returns `false` (after reporting the error and
  /// removing the headers already applied) if `dart:io` rejects any of them.
  bool _applyHead(Response response, HttpResponse ioResponse, Request request) {
    final applied = <String>[];
    try {
      ioResponse.statusCode = response.statusCode;
      for (final entry in response.headers.entries) {
        applied.add(entry.key);
        ioResponse.headers.set(entry.key, entry.value);
      }
      return true;
    } catch (error, stackTrace) {
      _report(error, stackTrace, request);
      for (final name in applied) {
        try {
          ioResponse.headers.removeAll(name);
        } catch (_) {}
      }
      return false;
    }
  }

  /// Default Error Boundary: 413 for a body above the limit; JSON 500 without leaking
  /// internal details otherwise.
  static Response _defaultErrorHandler(
    Object error,
    StackTrace stackTrace,
    Request request,
  ) {
    if (error is PayloadTooLargeException) return _payloadTooLarge;
    return Response.internalServerError(
      message: 'Internal Server Error',
    );
  }

  static void _defaultReporter(
    Object error,
    StackTrace stackTrace,
    Request? request,
  ) {
    final where = request == null ? '' : ' ${request.method} ${request.uri.path}';
    stderr.writeln('[orbiter] unhandled error$where: $error');
  }

  static final Response _payloadTooLarge = Response(
    413,
    headers: const <String, List<String>>{
      'content-type': ['application/json; charset=utf-8'],
    },
    body: utf8.encode('{"error":"Payload Too Large","code":413}'),
  );

  /// Pre-allocated static safe fallback response.
  static final Response _fallbackErrorResponse = Response(
    500,
    headers: const <String, List<String>>{
      'content-type': ['application/json; charset=utf-8'],
    },
    body: utf8.encode('{"error":"Internal Server Error","code":500}'),
  );
}
