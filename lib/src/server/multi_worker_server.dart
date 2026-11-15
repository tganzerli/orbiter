import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'concurrency_limit.dart';
import 'http_dispatcher.dart';
import 'worker_isolate.dart';

/// Extra time [MultiWorkerServer.close] gives a worker beyond its drain timeout
/// (shutdown hook, isolate exit) before killing it.
const Duration _shutdownGrace = Duration(seconds: 5);

/// Thrown by [MultiWorkerServer.start] when a worker cannot start.
final class MultiWorkerStartException implements Exception {
  /// Creates the exception for worker [workerId].
  const MultiWorkerStartException(this.workerId, this.message, [this.cause]);

  /// Worker that failed.
  final int workerId;

  /// What failed.
  final String message;

  /// The failure inside the worker, with its stack trace, when there is one.
  final Object? cause;

  @override
  String toString() => 'MultiWorkerStartException: worker $workerId: $message'
      '${cause == null ? '' : ': $cause'}';
}

/// Reported to [MultiWorkerServer.start]'s `onError` when a worker stops without
/// finishing a requested shutdown: while serving, or while draining in
/// [MultiWorkerServer.close]. The worker is not restarted.
final class WorkerExitedException implements Exception {
  /// Creates the exception for worker [workerId].
  const WorkerExitedException(this.workerId, [this.cause]);

  /// Worker that exited.
  final int workerId;

  /// The uncaught error that ended the worker, when there is one.
  final RemoteError? cause;

  @override
  String toString() => 'WorkerExitedException: worker $workerId exited'
      '${cause == null ? '' : ': $cause'}';
}

/// HTTP server that runs one [BackendServer] per isolate on the same TCP port.
///
/// Each worker runs the [WorkerSetup] inside its own isolate, so the pool,
/// repositories and router it builds are its own. The isolate that calls [start]
/// only supervises: it does not serve requests.
final class MultiWorkerServer {
  MultiWorkerServer._(this._report);

  final ErrorReporter _report;
  final List<_Worker> _workers = [];
  late final int _port;
  late final InternetAddress _address;
  Future<void>? _closing;
  bool _started = false;

  /// Starts [workers] workers (default: [Platform.numberOfProcessors]) listening on
  /// [address] and [port].
  ///
  /// With [port] `0`, the first worker gets an ephemeral port from the OS and the
  /// others bind to it. [securityContext] runs inside each worker, because a
  /// [SecurityContext] cannot cross isolates. [maxBodySize], [backlog] and
  /// [concurrencyLimit] apply to each worker as in [BackendServer.bind]: the limit is
  /// per worker, as each worker has its own resources (a database pool, for instance).
  ///
  /// Resolves once every worker is listening. If any worker fails (setup throws, the
  /// bind fails, or [setup] captures an object that cannot cross isolates), the
  /// workers already started are shut down and this throws a
  /// [MultiWorkerStartException], or the [ArgumentError] of the spawn.
  ///
  /// [onError] (default: `stderr`) receives a [WorkerExitedException] when a worker
  /// dies after the start (while serving, or while draining in [close]), and a
  /// [TimeoutException] when [close] has to kill one.
  static Future<MultiWorkerServer> start({
    required WorkerSetup setup,
    int? workers,
    Object? address,
    required int port,
    SecurityContext Function()? securityContext,
    int? maxBodySize = defaultMaxBodySize,
    int backlog = 0,
    ErrorReporter? onError,
    ConcurrencyLimit? concurrencyLimit,
  }) async {
    final count = workers ?? Platform.numberOfProcessors;
    if (count < 1) {
      throw ArgumentError.value(workers, 'workers', 'must be at least 1');
    }
    final server = MultiWorkerServer._(onError ?? _defaultReporter);

    WorkerBoot boot(int id, int bindPort, SendPort supervisor) => WorkerBoot(
          setup: setup,
          context: WorkerContext(id: id, workerCount: count),
          address: address,
          port: bindPort,
          securityContext: securityContext,
          maxBodySize: maxBodySize,
          backlog: backlog,
          concurrencyLimit: concurrencyLimit,
          supervisor: supervisor,
        );

    try {
      final first = await server._spawn(0, (s) => boot(0, port, s));
      server._port = first.port;
      server._address = first.address;
      final rest = await Future.wait([
        for (var id = 1; id < count; id++)
          server
              ._spawn(id, (s) => boot(id, first.port, s))
              .then<Object?>((_) => null, onError: (Object e) => e),
      ]);
      final failure = rest.firstWhere((e) => e != null, orElse: () => null);
      if (failure != null) throw failure;
      // A worker that was up may have died while the others were starting.
      for (final worker in server._workers) {
        if (worker.exited.isCompleted) {
          throw MultiWorkerStartException(
            worker.id,
            'exited during start',
            worker.lastError,
          );
        }
      }
      // No await between the check above and this flag: an exit from here on
      // is reported to onError.
      server._started = true;
    } catch (_) {
      await server._shutdown(force: true, drainTimeout: Duration.zero);
      rethrow;
    }
    return server;
  }

  /// Effective TCP port shared by all workers.
  int get port => _port;

  /// Network address the workers listen on.
  InternetAddress get address => _address;

  /// Number of workers started.
  int get workerCount => _workers.length;

  /// Stops every worker and waits for them.
  ///
  /// Each worker closes its [BackendServer] with [force] and [drainTimeout] (same
  /// semantics as [BackendServer.close]) and then runs its `onShutdown` hook. A
  /// worker that has not finished [drainTimeout] plus 5 seconds later is killed and
  /// reported to `onError`. Calling it again returns the same future.
  Future<void> close({
    bool force = false,
    Duration drainTimeout = const Duration(seconds: 30),
  }) =>
      _closing ??= _shutdown(force: force, drainTimeout: drainTimeout);

  Future<WorkerReady> _spawn(
    int id,
    WorkerBoot Function(SendPort supervisor) boot,
  ) async {
    final inbox = ReceivePort('orbiter-worker-$id');
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        workerMain,
        boot(inbox.sendPort),
        onExit: inbox.sendPort,
        onError: inbox.sendPort,
        debugName: 'orbiter-worker-$id',
      );
    } catch (_) {
      inbox.close();
      rethrow;
    }
    final worker = _Worker(id, isolate, inbox);
    _workers.add(worker);
    inbox.listen((message) => _onMessage(worker, message));
    return worker.ready.future;
  }

  void _onMessage(_Worker worker, Object? message) {
    switch (message) {
      case WorkerReady():
        worker.commands = message.commands;
        worker.ready.complete(message);
      case WorkerFailed():
        worker.ready.completeError(
          MultiWorkerStartException(
            worker.id,
            'setup or bind failed',
            RemoteError(message.error, message.stackTrace),
          ),
        );
      case WorkerDone():
        worker.done = true;
      case [final Object? error, final Object? stack]:
        // Uncaught error; the isolate exits next (errors are fatal).
        worker.lastError = RemoteError('$error', '$stack');
      case null:
        // onExit notification.
        worker.inbox.close();
        if (!worker.ready.isCompleted) {
          worker.ready.completeError(
            MultiWorkerStartException(
              worker.id,
              'exited before listening',
              worker.lastError,
            ),
          );
        } else if (_started && !worker.done) {
          // Died while serving or while draining. Before start() resolves, a
          // dead worker fails the start instead (see start()).
          _report(
            WorkerExitedException(worker.id, worker.lastError),
            StackTrace.current,
            null,
          );
        }
        worker.exited.complete();
    }
  }

  Future<void> _shutdown({
    required bool force,
    required Duration drainTimeout,
  }) async {
    final command = WorkerShutdown(force, drainTimeout);
    for (final worker in _workers) {
      if (!worker.exited.isCompleted) worker.commands?.send(command);
    }
    await Future.wait([
      for (final worker in _workers)
        worker.exited.future.timeout(
          drainTimeout + _shutdownGrace,
          onTimeout: () {
            worker.isolate.kill(priority: Isolate.immediate);
            worker.inbox.close();
            _report(
              TimeoutException(
                'worker ${worker.id} did not shut down; killed',
                drainTimeout + _shutdownGrace,
              ),
              StackTrace.current,
              null,
            );
          },
        ),
    ]);
  }

  static void _defaultReporter(
    Object error,
    StackTrace stackTrace,
    Object? request,
  ) {
    stderr.writeln('[orbiter] $error');
  }
}

final class _Worker {
  _Worker(this.id, this.isolate, this.inbox);

  final int id;
  final Isolate isolate;
  final ReceivePort inbox;
  final Completer<WorkerReady> ready = Completer();
  final Completer<void> exited = Completer();
  SendPort? commands;
  RemoteError? lastError;
  bool done = false;
}
