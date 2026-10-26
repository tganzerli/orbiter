import 'dart:convert';
import 'dart:typed_data';

/// Represents an HTTP response produced by the application or framework.
///
/// Designed to be lightweight and allocate minimal wrapper objects on the
/// hot response path.
class Response {
  /// The HTTP status code of the response (e.g. 200, 404, 500).
  final int statusCode;

  /// The response headers map, where each key maps to a list of header values.
  final Map<String, List<String>> headers;

  /// The raw response body. Can be [String], [Uint8List], [List<int>],
  /// JSON-serializable [Map]/[List], or `null`.
  final Object? body;

  /// Creates a response with [statusCode]; the named constructors cover the
  /// common statuses.
  const Response(
    this.statusCode, {
    this.headers = const <String, List<String>>{},
    this.body,
  });

  /// 200 OK with optional [body] and [headers].
  factory Response.ok({
    Object? body,
    Map<String, List<String>>? headers,
  }) =>
      Response(200, body: body, headers: headers ?? const {});

  /// 201 Created with optional [body] and [headers].
  factory Response.created({
    Object? body,
    Map<String, List<String>>? headers,
  }) =>
      Response(201, body: body, headers: headers ?? const {});

  /// Returns a JSON response with `application/json; charset=utf-8` content-type.
  factory Response.json(
    Object? data, {
    int statusCode = 200,
    Map<String, List<String>>? headers,
  }) {
    final merged = _mergeHeaders(headers, {
      'content-type': const ['application/json; charset=utf-8'],
    });
    return Response(
      statusCode,
      body: data is String ? data : jsonEncode(data),
      headers: merged,
    );
  }

  /// Returns a binary response with specified [contentType].
  factory Response.bytes(
    List<int> bytes, {
    int statusCode = 200,
    String contentType = 'application/octet-stream',
    Map<String, List<String>>? headers,
  }) {
    final merged = _mergeHeaders(headers, {
      'content-type': [contentType],
      'content-length': [bytes.length.toString()],
    });
    return Response(
      statusCode,
      body: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      headers: merged,
    );
  }

  /// 204 No Content.
  factory Response.noContent({
    Map<String, List<String>>? headers,
  }) =>
      Response(204, headers: headers ?? const {});

  /// 400 Bad Request.
  factory Response.badRequest({
    Object? body,
    Map<String, List<String>>? headers,
  }) =>
      Response(400, body: body, headers: headers ?? const {});

  /// 401 Unauthorized.
  factory Response.unauthorized({
    Object? body,
    Map<String, List<String>>? headers,
  }) =>
      Response(401, body: body, headers: headers ?? const {});

  /// 403 Forbidden.
  factory Response.forbidden({
    Object? body,
    Map<String, List<String>>? headers,
  }) =>
      Response(403, body: body, headers: headers ?? const {});

  /// 404 Not Found.
  factory Response.notFound({
    Object? body,
    Map<String, List<String>>? headers,
  }) =>
      Response(404, body: body, headers: headers ?? const {});

  /// 500 Internal Server Error.
  factory Response.internalServerError({
    String message = 'Internal Server Error',
    Map<String, List<String>>? headers,
  }) =>
      Response.json(
        {'error': message, 'code': 500},
        statusCode: 500,
        headers: headers,
      );

  /// Returns the first header value matching [name] (case-insensitive), or `null`.
  String? getHeader(String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower && entry.value.isNotEmpty) {
        return entry.value.first;
      }
    }
    return null;
  }

  /// Returns a new [Response] with an added or updated header [name].
  Response withHeader(String name, String value) {
    final newHeaders = Map<String, List<String>>.of(headers);
    newHeaders[name.toLowerCase()] = [value];
    return copyWith(headers: newHeaders);
  }

  /// Returns a new [Response] with added or updated headers from [newHeaders].
  ///
  /// The value lists of [newHeaders] are shared, not copied: pass lists that
  /// are not mutated afterwards (middlewares build them once, at setup).
  Response withHeaders(Map<String, List<String>> newHeaders) {
    final merged = Map<String, List<String>>.of(headers);
    for (final entry in newHeaders.entries) {
      merged[entry.key.toLowerCase()] = entry.value;
    }
    return copyWith(headers: merged);
  }

  /// Creates a copy of this response with updated properties.
  Response copyWith({
    int? statusCode,
    Map<String, List<String>>? headers,
    Object? body,
  }) {
    return Response(
      statusCode ?? this.statusCode,
      headers: headers ?? this.headers,
      body: body ?? this.body,
    );
  }

  static Map<String, List<String>> _mergeHeaders(
    Map<String, List<String>>? base,
    Map<String, List<String>> extra,
  ) {
    final result = <String, List<String>>{};
    if (base != null) {
      for (final entry in base.entries) {
        result[entry.key.toLowerCase()] = List<String>.of(entry.value);
      }
    }
    for (final entry in extra.entries) {
      result[entry.key.toLowerCase()] = List<String>.of(entry.value);
    }
    return result;
  }
}
