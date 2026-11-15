import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

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

  /// Creates a limit. [maxQueued] defaults to [maxInFlight].
  ///
  /// Throws [ArgumentError] when [maxInFlight] is not positive, [maxQueued]
  /// is negative, or a duration is negative.
  ConcurrencyLimit({
    required this.maxInFlight,
    int? maxQueued,
    this.queueTimeout = const Duration(milliseconds: 250),
    this.retryAfter = const Duration(seconds: 1),
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
