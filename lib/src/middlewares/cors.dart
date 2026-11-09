import '../pipeline/interceptor.dart';
import '../response/response.dart';

/// Creates a CORS (Cross-Origin Resource Sharing) middleware.
///
/// - `origins` containing `'*'`: responds with `Access-Control-Allow-Origin: *`
///   on every response (incompatible with [allowCredentials]; the combination throws
///   [ArgumentError]).
/// - Explicit list: reflects the request's `Origin` when it is in the list and appends
///   `Vary: Origin`; an origin outside the list gets no CORS header.
/// - A preflight is an `OPTIONS` with both `Origin` **and** `Access-Control-Request-Method`:
///   it responds 204 without calling the handler. Any other `OPTIONS` follows the pipeline.
InterceptorFunction cors({
  List<String> origins = const ['*'],
  List<String> methods = const [
    'GET',
    'POST',
    'PUT',
    'DELETE',
    'PATCH',
    'OPTIONS',
    'HEAD',
  ],
  List<String> headers = const [
    'Origin',
    'Content-Type',
    'Accept',
    'Authorization',
    'X-Requested-With',
  ],
  List<String>? exposeHeaders,
  bool allowCredentials = false,
  int? maxAge = 86400,
}) {
  final anyOrigin = origins.contains('*');
  if (anyOrigin && allowCredentials) {
    throw ArgumentError(
      'cors: origin "*" cannot be combined with allowCredentials; '
      'list the allowed origins explicitly.',
    );
  }
  final allowed = Set<String>.unmodifiable(origins);

  // Fixed headers, built once at setup.
  final common = <String, List<String>>{
    if (exposeHeaders != null && exposeHeaders.isNotEmpty)
      'access-control-expose-headers':
          List.unmodifiable([exposeHeaders.join(', ')]),
    if (allowCredentials) 'access-control-allow-credentials': const ['true'],
  };
  final preflightOnly = <String, List<String>>{
    'access-control-allow-methods': List.unmodifiable([methods.join(', ')]),
    'access-control-allow-headers': List.unmodifiable([headers.join(', ')]),
    if (maxAge != null)
      'access-control-max-age': List.unmodifiable([maxAge.toString()]),
  };
  // With '*' the response is identical for any origin: ready-made maps at setup, without
  // Origin or Vary.
  final wildcardSimple = Map<String, List<String>>.unmodifiable({
    ...common,
    'access-control-allow-origin': const ['*'],
  });
  final wildcardPreflight = Map<String, List<String>>.unmodifiable({
    ...wildcardSimple,
    ...preflightOnly,
  });

  // Explicit list: reflects the accepted origin; `null` when it is not accepted.
  Map<String, List<String>>? reflected(String? origin,
      {required bool preflight}) {
    if (origin == null || !allowed.contains(origin)) return null;
    return {
      ...common,
      'access-control-allow-origin': [origin],
      if (preflight) ...preflightOnly,
    };
  }

  return (request, next) async {
    final origin = request.getHeader('origin');
    final isPreflight = origin != null &&
        request.method.toUpperCase() == 'OPTIONS' &&
        request.getHeader('access-control-request-method') != null;

    if (anyOrigin) {
      if (isPreflight) return Response.noContent(headers: wildcardPreflight);
      return (await next(request)).withHeaders(wildcardSimple);
    }

    if (isPreflight) {
      return Response.noContent(
        headers:
            _withVary(reflected(origin, preflight: true) ?? const {}, null),
      );
    }

    final response = await next(request);
    // The response varies with the Origin, including when it is not accepted.
    return response.withHeaders(_withVary(
      reflected(origin, preflight: false) ?? const {},
      response.getHeader('vary'),
    ));
  };
}

Map<String, List<String>> _withVary(
  Map<String, List<String>> headers,
  String? existingVary,
) {
  final vary = existingVary == null || existingVary.isEmpty
      ? 'Origin'
      : existingVary.toLowerCase().contains('origin')
          ? existingVary
          : '$existingVary, Origin';
  return {
    ...headers,
    'vary': [vary]
  };
}
