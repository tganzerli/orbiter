import '../pipeline/handler.dart';

/// Route registered for an HTTP method at a terminal node of the tree.
///
/// Parameter names belong to the route, not to the node: two paths with the same shape
/// (`/users/:id` and `/users/:userId/posts`) share nodes, but each one names its
/// parameters independently.
final class RouteEntry {
  /// Route handler.
  final Handler handler;

  /// Parameter names in the order they appear in the path; the wildcard, if any, is
  /// always the last one.
  final List<String> paramNames;

  const RouteEntry(this.handler, this.paramNames);
}

/// Result of a successful lookup in the Trie tree.
final class RouteMatch {
  /// The terminal node of the route, where the routes per method are registered.
  final TrieNode node;

  /// Captured values (parameters and wildcard) in path order, still percent-encoded.
  /// `null` when the route captures nothing.
  final List<String>? values;

  const RouteMatch(this.node, this.values);
}

/// Node of the Radix/Trie tree for high-performance HTTP routing.
///
/// Splits URL paths into segments delimited by `/`, favoring exact static routes before
/// evaluating dynamic parameters and wildcards.
final class TrieNode {
  /// Children associated with exact/literal text segments.
  final Map<String, TrieNode> staticChildren = <String, TrieNode>{};

  /// Child for a dynamic parameter segment (`:paramName`).
  TrieNode? paramChild;

  /// Child for a catch-all wildcard segment (`*wildcardName` or `*`).
  TrieNode? wildcardChild;

  /// Routes registered at this terminal node, indexed by HTTP method (uppercase).
  final Map<String, RouteEntry> routes = <String, RouteEntry>{};

  /// Inserts a route into the tree from its list of segments.
  ///
  /// Throws [ArgumentError] if a parameter name repeats within the same route or if the
  /// wildcard is not the last segment.
  void insert(List<String> segments, String method, Handler handler) {
    var current = this;
    final names = <String>[];

    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];

      if (segment.startsWith('*')) {
        if (i != segments.length - 1) {
          throw ArgumentError.value(
            segments.join('/'),
            'path',
            'wildcard must be the last segment',
          );
        }
        _addName(names, segment.length > 1 ? segment.substring(1) : 'wildcard',
            segments);
        current = current.wildcardChild ??= TrieNode();
      } else if (segment.startsWith(':')) {
        _addName(names, segment.substring(1), segments);
        current = current.paramChild ??= TrieNode();
      } else {
        current = current.staticChildren.putIfAbsent(segment, TrieNode.new);
      }
    }

    current.routes[method.toUpperCase()] =
        RouteEntry(handler, List<String>.unmodifiable(names));
  }

  static void _addName(List<String> names, String name, List<String> segments) {
    if (names.contains(name)) {
      throw ArgumentError.value(
        segments.join('/'),
        'path',
        'duplicate parameter name "$name"',
      );
    }
    names.add(name);
  }

  /// Searches for a path represented by [segments].
  ///
  /// Returns a [RouteMatch] with the node found and the captured values, or `null` if no
  /// node matches the path. Purely static routes do not allocate the list of values.
  RouteMatch? search(List<String> segments) => _search(segments, 0, null);

  RouteMatch? _search(List<String> segments, int index, List<String>? values) {
    if (index == segments.length) {
      return routes.isNotEmpty ? RouteMatch(this, values) : null;
    }

    final segment = segments[index];

    // 1. Priority: literal static nodes
    final staticChild = staticChildren[segment];
    if (staticChild != null) {
      final match = staticChild._search(segments, index + 1, values);
      if (match != null) return match;
    }

    // 2. Priority: nodes with a dynamic parameter (:param)
    final param = paramChild;
    if (param != null) {
      final captured = values ?? <String>[];
      captured.add(segment);
      final match = param._search(segments, index + 1, captured);
      if (match != null) return match;
      captured.removeLast();
    }

    // 3. Priority: the wildcard node (*path)
    final wildcard = wildcardChild;
    if (wildcard != null && wildcard.routes.isNotEmpty) {
      return RouteMatch(
        wildcard,
        (values ?? <String>[])..add(segments.sublist(index).join('/')),
      );
    }

    return null;
  }
}
