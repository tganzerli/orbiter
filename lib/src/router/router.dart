import 'dart:async';

import '../pipeline/handler.dart';
import '../request/request.dart';
import '../response/response.dart';
import 'path_parameters.dart';
import 'trie_node.dart';

/// High-performance HTTP router based on a Radix/Trie tree.
///
/// Offers O(k) lookup complexity, proportional to the length of the URI path, with
/// support for static routes, dynamic parameters (`:id`), wildcards (`*path`), and
/// automatic 405 Method Not Allowed and 404 Not Found responses.
///
/// Implements the functional [Handler] contract via the [call] method, integrating
/// directly with `BackendServer` and `Pipeline` instances.
final class Router {
  final TrieNode _root = TrieNode();

  /// Custom handler executed when no route is found.
  Handler? notFoundHandler;

  /// Creates a new instance of [Router].
  Router({this.notFoundHandler});

  /// Registers a route for a specific HTTP method [method] and path [path].
  void add(String method, String path, Handler handler) {
    final segments = _splitPath(path);
    _root.insert(segments, method, handler);
  }

  /// Registers an HTTP GET route.
  void get(String path, Handler handler) => add('GET', path, handler);

  /// Registers an HTTP POST route.
  void post(String path, Handler handler) => add('POST', path, handler);

  /// Registers an HTTP PUT route.
  void put(String path, Handler handler) => add('PUT', path, handler);

  /// Registers an HTTP DELETE route.
  void delete(String path, Handler handler) => add('DELETE', path, handler);

  /// Registers an HTTP PATCH route.
  void patch(String path, Handler handler) => add('PATCH', path, handler);

  /// Registers an HTTP HEAD route.
  void head(String path, Handler handler) => add('HEAD', path, handler);

  /// Registers an HTTP OPTIONS route.
  void options(String path, Handler handler) => add('OPTIONS', path, handler);

  /// Registers the same [handler] for the main HTTP methods (GET, POST, PUT, DELETE, PATCH,
  /// HEAD, OPTIONS).
  void all(String path, Handler handler) {
    const methods = [
      'GET',
      'POST',
      'PUT',
      'DELETE',
      'PATCH',
      'HEAD',
      'OPTIONS'
    ];
    for (final method in methods) {
      add(method, path, handler);
    }
  }

  /// Processes the request and dispatches it to the matching handler.
  ///
  /// Synchronous by design: returns the handler's [FutureOr] without wrapping it in another
  /// [Future], and 404/405 are returned as an immediate [Response].
  FutureOr<Response> call(Request request) {
    final segments = _splitPath(request.uri.path);
    final match = _root.search(segments);

    if (match == null) {
      final notFound = notFoundHandler;
      return notFound != null ? notFound(request) : _defaultNotFound(request);
    }

    final routes = match.node.routes;
    final method = request.method;
    final route = routes[method] ?? routes[method.toUpperCase()];

    if (route == null) {
      // The path exists in the tree, but the method does not match -> 405 Method Not Allowed
      final allowed = routes.keys.toList()..sort();
      return Response(
        405,
        headers: <String, List<String>>{
          'allow': [allowed.join(', ')],
        },
        body: 'Method Not Allowed',
      );
    }

    final values = match.values;
    if (values != null) {
      final params = <String, String>{};
      final names = route.paramNames;
      for (var i = 0; i < names.length; i++) {
        // `Uri` normalizes the path on construction (`%zz` becomes `%25zz`), so decoding a
        // value coming from `request.uri` does not fail.
        final raw = values[i];
        params[names[i]] = raw.contains('%') ? Uri.decodeComponent(raw) : raw;
      }
      // Injects the path parameters into the typed RequestContext
      request.context.set(PathParameters(params));
    }

    return route.handler(request);
  }

  /// Returns the router as a default [Handler] closure.
  Handler get handler => call;

  /// Splits the path into normalized segments, ignoring empty slashes.
  static List<String> _splitPath(String path) {
    if (path.isEmpty || path == '/') {
      return const <String>[];
    }

    final segments = <String>[];
    for (final part in path.split('/')) {
      if (part.isNotEmpty) {
        segments.add(part);
      }
    }
    return segments;
  }

  /// Default 404 response of the router.
  static Response _defaultNotFound(Request request) {
    return Response.notFound(
      body: 'Not Found',
      headers: const <String, List<String>>{
        'content-type': ['text/plain; charset=utf-8'],
      },
    );
  }
}
