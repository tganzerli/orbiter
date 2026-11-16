import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import '../request/request.dart';
import '../response/response.dart';

/// Builds the response for a request refused by a [ConcurrencyLimit].
///
/// [retryAfterSeconds] is [ConcurrencyLimit.retryAfterSeconds]; when the
/// returned response has no `retry-after` header, the server adds one with
/// that value.
typedef RejectResponseBuilder = FutureOr<Response> Function(
  Request request,
  int retryAfterSeconds,
);

/// Decides whether a request bypasses a [ConcurrencyLimit].
typedef ExemptPredicate = bool Function(Request request);

/// Admission control for a server: how many requests run at once, how many
/// may wait for a slot, and for how long.
///
/// A request holds its slot for its whole cycle: the handler, the writing of
/// the response and the request's cleanup hooks, which is where resources
/// such as a database transaction are released. When every slot is taken, a
/// request waits in a first-come queue for at most [queueTimeout]; when the
/// queue is full too, or the wait times out, it gets `503 Service
/// Unavailable` with a `Retry-After` header, and its handler never runs.
///
/// There is no per-request timeout: a running handler cannot be cancelled,
/// so bound the time where the work happens (for example the database's
/// `statement_timeout` and the pool's acquire timeout).
///
/// ```dart
/// final server = await BackendServer.bind(
///   handler: app,
///   port: 8080,
///   concurrencyLimit: ConcurrencyLimit(maxInFlight: 32),
/// );
/// ```
///
/// [rejectResponse] lets the application build the refusal from the request,
/// for example to add the CORS headers a browser needs to see the `503`, and
/// [exempt] lets cheap probes such as `/ready` skip the limit.
///
/// With `MultiWorkerServer`, the limit is sent to every worker isolate, so
/// [rejectResponse] and [exempt] must be top-level or static functions, or
/// closures that capture only values that can be sent between isolates;
/// otherwise the server fails to start.
final class ConcurrencyLimit {
  /// Requests admitted at the same time. Must be positive.
  final int maxInFlight;

  /// Requests that may wait for a slot. `0` disables the queue: a request
  /// that finds every slot taken is refused at once.
  final int maxQueued;

  /// How long a request may wait in the queue before it is refused.
  final Duration queueTimeout;

  /// Value of the `Retry-After` header on a refusal, sent in whole seconds,
  /// rounded up.
  final Duration retryAfter;

  /// Builds the response for a refused request; `null` (the default) sends
  /// `503` with a JSON body and `Retry-After`.
  ///
  /// The response is written like a handler's (any body type). A missing
  /// `retry-after` header is added. If the builder throws or its future
  /// fails, the error goes to the server's error reporter and the default
  /// refusal is sent; a header value that `dart:io` rejects turns it into a
  /// `500`, as for a handler. Cleanup hooks registered on the request run
  /// after the response is written. The handler still never runs, and a
  /// refused request holds no slot while its response is built.
  ///
  /// It runs for every refusal, that is, under overload, with no limit or
  /// timeout of its own: keep it cheap and make sure its future completes.
  ///
  /// Under `MultiWorkerServer` it must be sendable between isolates: see the
  /// class documentation.
  final RejectResponseBuilder? rejectResponse;

  /// Requests for which this returns `true` skip the limit: they take no
  /// slot, never queue and are never refused. `null` (the default) exempts
  /// nothing.
  ///
  /// Meant for cheap probes such as a readiness check: whatever is exempt
  /// has no limit at all. If the predicate throws, the error goes to the
  /// server's error reporter and the request goes through the limit.
  ///
  /// Under `MultiWorkerServer` it must be sendable between isolates: see the
  /// class documentation.
  final ExemptPredicate? exempt;

  /// Creates a limit. [maxQueued] defaults to [maxInFlight].
  ///
  /// Throws [ArgumentError] when [maxInFlight] is not positive, [maxQueued]
  /// is negative, or a duration is negative.
  ConcurrencyLimit({
    required this.maxInFlight,
    int? maxQueued,
    this.queueTimeout = const Duration(milliseconds: 250),
    this.retryAfter = const Duration(seconds: 1),
    this.rejectResponse,
    this.exempt,
  }) : maxQueued = maxQueued ?? maxInFlight {
    if (maxInFlight <= 0) {
      throw ArgumentError.value(maxInFlight, 'maxInFlight', 'must be positive');
    }
    if (this.maxQueued < 0) {
      throw ArgumentError.value(maxQueued, 'maxQueued', 'must not be negative');
    }
    if (queueTimeout.isNegative) {
      throw ArgumentError.value(
          queueTimeout, 'queueTimeout', 'must not be negative');
    }
    if (retryAfter.isNegative) {
      throw ArgumentError.value(
          retryAfter, 'retryAfter', 'must not be negative');
    }
  }

  /// `Retry-After` in whole seconds, rounded up.
  int get retryAfterSeconds =>
      (retryAfter.inMicroseconds + Duration.microsecondsPerSecond - 1) ~/
      Duration.microsecondsPerSecond;
}

/// The slots of a [ConcurrencyLimit]: admits, queues or refuses.
@internal
final class AdmissionGate {
  final ConcurrencyLimit limit;
  final Queue<_Waiter> _queue = Queue<_Waiter>();
  int _active = 0;
  int _rejected = 0;

  AdmissionGate(this.limit);

  /// Requests holding a slot.
  int get active => _active;

  /// Requests waiting for a slot.
  int get queued => _queue.length;

  /// Requests refused since the gate was created.
  int get rejected => _rejected;

  /// Completes with `true` once the caller holds a slot, which it must give
  /// back with [release], or with `false` when it is refused.
  FutureOr<bool> acquire() {
    if (_active < limit.maxInFlight) {
      _active++;
      return true;
    }
    if (_queue.length >= limit.maxQueued) {
      _rejected++;
      return false;
    }
    final waiter = _Waiter();
    _queue.add(waiter);
    waiter.timer = Timer(limit.queueTimeout, () {
      if (_queue.remove(waiter)) {
        _rejected++;
        waiter.completer.complete(false);
      }
    });
    return waiter.completer.future;
  }

  /// Gives a slot back. With requests waiting, the slot passes straight to
  /// the oldest one, so a newcomer cannot take it in between.
  void release() {
    if (_queue.isEmpty) {
      _active--;
      return;
    }
    final next = _queue.removeFirst();
    next.timer.cancel();
    next.completer.complete(true);
  }
}

final class _Waiter {
  final Completer<bool> completer = Completer<bool>();
  late final Timer timer;
}
