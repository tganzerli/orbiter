import '../request/request.dart';

/// Immutable container for the dynamic route parameters captured by the [Router].
///
/// Stored inside the heterogeneous [RequestContext] of the [Request] (without using Zone).
final class PathParameters {
  /// Key-value map with the parameters extracted from the URL path.
  final Map<String, String> values;

  /// Creates an instance of [PathParameters].
  const PathParameters([this.values = const <String, String>{}]);

  /// Returns the value of parameter [name], or `null` if it does not exist.
  String? operator [](String name) => values[name];

  /// Checks whether parameter [name] was captured.
  bool containsKey(String name) => values.containsKey(name);

  @override
  String toString() => values.toString();
}

/// Ergonomic extension on [Request] for direct access to the route parameters.
extension RequestPathParamsExtension on Request {
  /// Returns the map of dynamic route parameters captured (e.g. `:id`).
  ///
  /// Returns an empty immutable map if the route is static.
  Map<String, String> get pathParams =>
      context.getOrNull<PathParameters>()?.values ?? const <String, String>{};

  /// Returns the value of route parameter [name], or `null` if not found.
  String? pathParam(String name) => context.getOrNull<PathParameters>()?[name];
}
