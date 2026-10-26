import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.io) 'dart:io';
import 'dart:typed_data';

import '../context/request_context.dart';
import 'payload_too_large_exception.dart';

/// Represents an incoming HTTP request in `orbiter`.
///
/// Provides type-safe request metadata, route parameters, context storage,
/// body reading utilities, and guaranteed cleanup hook registration.
class Request {
  /// The HTTP method (e.g. 'GET', 'POST', 'PUT', 'DELETE').
  final String method;

  /// The requested URI.
  final Uri uri;

  /// Dynamic path parameters extracted by the router (e.g. `{'id': '123'}`).
  final Map<String, String> pathParameters;

  /// The underlying stream of body bytes.
  final Stream<List<int>> _bodyStream;

  /// Underlying `dart:io` [HttpRequest], if running in a native server context.
  final HttpRequest? rawRequest;

  /// Maximum number of body bytes [readAsBytes] accepts; `null` means unlimited.
  final int? maxBodySize;

  // Headers, context and the hook list are created on demand: the hot path of a simple
  // route does not pay for them.
  final HttpHeaders? _ioHeaders;
  Map<String, List<String>>? _headers;
  RequestContext? _context;
  List<FutureOr<void> Function()>? _cleanupHooks;

  Uint8List? _cachedBodyBytes;

  /// Creates a request. The server builds one per incoming `HttpRequest`;
  /// tests build them directly, with an optional [bodyStream].
  Request({
    required this.method,
    required this.uri,
    Map<String, List<String>> headers = const <String, List<String>>{},
    RequestContext? context,
    this.pathParameters = const <String, String>{},
    Stream<List<int>>? bodyStream,
    this.rawRequest,
    this.maxBodySize,
  })  : _headers = headers,
        _ioHeaders = null,
        _context = context,
        _bodyStream = bodyStream ?? const Stream.empty();

  Request._io(HttpRequest raw, this.maxBodySize)
      : method = raw.method,
        uri = raw.uri,
        pathParameters = const <String, String>{},
        rawRequest = raw,
        _ioHeaders = raw.headers,
        _bodyStream = raw;

  /// Creates a [Request] wrapping a native `dart:io` [HttpRequest].
  ///
  /// Uses [HttpRequest.uri] (the request target as sent), not
  /// [HttpRequest.requestedUri], whose host comes from the client-controlled
  /// `Host` header. Headers are not copied until [headers] is first read.
  factory Request.fromHttpRequest(HttpRequest rawRequest, {int? maxBodySize}) =>
      Request._io(rawRequest, maxBodySize);

  /// The incoming HTTP headers, keyed by lower-case name.
  Map<String, List<String>> get headers {
    final cached = _headers;
    if (cached != null) return cached;
    final map = <String, List<String>>{};
    _ioHeaders!.forEach((name, values) {
      map[name] = values;
    });
    return _headers = map;
  }

  /// The typed request-scoped context (zero-overhead alternative to [Zone]).
  RequestContext get context => _context ??= RequestContext();

  /// Returns the first value of header [name] (case-insensitive), or `null`.
  String? getHeader(String name) {
    final io = _ioHeaders;
    final values = io != null ? io[name] : headers[name.toLowerCase()];
    return values == null || values.isEmpty ? null : values.first;
  }

  /// Registers a cleanup hook to be executed upon request completion.
  ///
  /// Guarantees that resources (e.g. database connections borrowed from
  /// the pool or session state like `SET LOCAL app.current_tenant_id`)
  /// are released even if an unhandled error or client disconnect occurs.
  void addCleanupHook(FutureOr<void> Function() hook) {
    (_cleanupHooks ??= <FutureOr<void> Function()>[]).add(hook);
  }

  /// Executes all registered cleanup hooks in LIFO (reverse) order.
  ///
  /// An error thrown by one hook never prevents the remaining hooks from
  /// running. It is passed to [onError] when given, and dropped otherwise.
  Future<void> runCleanupHooks({
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    final hooks = _cleanupHooks;
    if (hooks == null || hooks.isEmpty) return;
    final reversed = hooks.reversed.toList();
    hooks.clear();

    for (final hook in reversed) {
      try {
        await hook();
      } catch (error, stackTrace) {
        // A failing hook must not stop the release of the others.
        if (onError != null) onError(error, stackTrace);
      }
    }
  }

  /// Reads the entire request body as raw bytes.
  ///
  /// Throws [PayloadTooLargeException] when the body exceeds [maxBodySize]:
  /// up front if `Content-Length` already declares more, otherwise as soon as
  /// the bytes read cross the limit.
  Future<Uint8List> readAsBytes() async {
    if (_cachedBodyBytes != null) {
      return _cachedBodyBytes!;
    }

    final limit = maxBodySize;
    if (limit != null && _declaredContentLength() > limit) {
      throw PayloadTooLargeException(limit);
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in _bodyStream) {
      if (limit != null && builder.length + chunk.length > limit) {
        throw PayloadTooLargeException(limit);
      }
      builder.add(chunk);
    }
    _cachedBodyBytes = builder.takeBytes();
    return _cachedBodyBytes!;
  }

  int _declaredContentLength() {
    final io = _ioHeaders;
    if (io != null) return io.contentLength;
    return int.tryParse(getHeader('content-length') ?? '') ?? -1;
  }

  /// Reads the request body as a string with the specified [encoding].
  Future<String> readAsString({Encoding encoding = utf8}) async {
    final bytes = await readAsBytes();
    return encoding.decode(bytes);
  }

  /// Reads and parses the request body as JSON.
  Future<Object?> readAsJson() async {
    final text = await readAsString();
    if (text.trim().isEmpty) return null;
    return jsonDecode(text);
  }
}
