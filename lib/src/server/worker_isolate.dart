import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../pipeline/handler.dart';
import 'backend_server.dart';
import 'concurrency_limit.dart';
import 'http_dispatcher.dart';

/// Identity of a worker, passed to its [WorkerSetup].
final class WorkerContext {
  /// Creates the context of worker [id] out of [workerCount].
  const WorkerContext({required this.id, required this.workerCount});

  /// Index of this worker, from `0` to `workerCount - 1`.
  final int id;

  /// Total number of workers the server was started with.
  final int workerCount;
}

/// What one worker serves, built by a [WorkerSetup] inside the worker's isolate.
final class WorkerApp {
  /// Creates the application of one worker.
  const WorkerApp({
    required this.handler,
    this.onShutdown,
    this.errorHandler,
    this.onError,
  });

  /// Root handler of this worker.
  final Handler handler;

  /// Runs once when the worker stops, after its in-flight requests drained; the place
  /// to close what the setup opened (for example, the connection pool).
  final FutureOr<void> Function()? onShutdown;

  /// Error Boundary of this worker (see [BackendServer.bind]).
  final ErrorHandler? errorHandler;

  /// Reporter of this worker's unhandled errors (default: `stderr`). Also receives
  /// errors thrown by [onShutdown].
  final ErrorReporter? onError;
}

/// Builds one worker's application. It runs inside the worker's isolate, so whatever
/// it creates (pool, repositories, router) belongs to that worker alone.
///
/// The function itself is sent to the isolate: a closure that captures an object that
/// cannot cross isolates (an open pool, a `ReceivePort`, a `SecurityContext`) makes
/// the start fail.
typedef WorkerSetup = FutureOr<WorkerApp> Function(WorkerContext context);

/// Start-up parameters sent to a worker isolate.
final class WorkerBoot {
  const WorkerBoot({
    required this.setup,
    required this.context,
    required this.address,
    required this.port,
    required this.securityContext,
    required this.maxBodySize,
    required this.backlog,
    this.concurrencyLimit,
    required this.supervisor,
  });

  final WorkerSetup setup;
  final WorkerContext context;
  final Object? address;
  final int port;
  final SecurityContext Function()? securityContext;
  final int? maxBodySize;
  final int backlog;
  final ConcurrencyLimit? concurrencyLimit;
  final SendPort supervisor;
}

/// Worker → supervisor: listening; [commands] accepts a [WorkerShutdown].
final class WorkerReady {
  const WorkerReady(this.commands, this.port, this.address);
  final SendPort commands;
  final int port;
  final InternetAddress address;
}

/// Worker → supervisor: setup or bind failed; the isolate is exiting.
final class WorkerFailed {
  const WorkerFailed(this.error, this.stackTrace);
  final String error;
  final String stackTrace;
}

/// Worker → supervisor: drained and shut down; the isolate is exiting.
final class WorkerDone {
  const WorkerDone();
}

/// Supervisor → worker: stop serving.
final class WorkerShutdown {
  const WorkerShutdown(this.force, this.drainTimeout);
  final bool force;
  final Duration drainTimeout;
}

/// Entry point of a worker isolate.
Future<void> workerMain(WorkerBoot boot) async {
  final commands = ReceivePort();
  WorkerApp? app;
  final BackendServer server;
  try {
    app = await boot.setup(boot.context);
    server = await BackendServer.bind(
      handler: app.handler,
      address: boot.address,
      port: boot.port,
      shared: true,
      securityContext: boot.securityContext?.call(),
      errorHandler: app.errorHandler,
      onError: app.onError,
      maxBodySize: boot.maxBodySize,
      backlog: boot.backlog,
      concurrencyLimit: boot.concurrencyLimit,
    );
  } catch (error, stackTrace) {
    commands.close();
    // The setup may have opened resources before the bind failed.
    if (app != null) await _runShutdownHook(app);
    Isolate.exit(
      boot.supervisor,
      WorkerFailed(error.toString(), stackTrace.toString()),
    );
  }

  boot.supervisor
      .send(WorkerReady(commands.sendPort, server.port, server.address));

  final command = await commands.first as WorkerShutdown;
  try {
    await server.close(
      force: command.force,
      drainTimeout: command.drainTimeout,
    );
  } catch (error, stackTrace) {
    _reportFromWorker(app, error, stackTrace);
  }
  // Runs even if the close failed: the hook releases what the setup opened.
  await _runShutdownHook(app);
  // Exits even if user code left timers or ports open.
  Isolate.exit(boot.supervisor, const WorkerDone());
}

Future<void> _runShutdownHook(WorkerApp app) async {
  final hook = app.onShutdown;
  if (hook == null) return;
  try {
    await hook();
  } catch (error, stackTrace) {
    _reportFromWorker(app, error, stackTrace);
  }
}

void _reportFromWorker(WorkerApp app, Object error, StackTrace stackTrace) {
  final report = app.onError;
  if (report != null) {
    report(error, stackTrace, null);
  } else {
    stderr.writeln('[orbiter] worker shutdown failed: $error');
  }
}
