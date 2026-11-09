// One orbiter server per CPU core, all on the same port.
//
// Run with `dart run example/multi_worker.dart`, then repeat
//   curl localhost:8080/whoami
// and the answering worker changes. Ctrl+C stops every worker.
import 'dart:io';

import 'package:orbiter/orbiter.dart';

/// Runs inside each worker's isolate: everything built here (router, pool,
/// repositories) belongs to that worker alone.
WorkerApp buildWorker(WorkerContext worker) {
  final router = Router()
    ..get('/whoami', (request) => Response.json({'worker': worker.id}));

  return WorkerApp(
    handler: Pipeline().add(securityHeaders()).addHandler(router.handler),
    // Close what this worker opened, e.g. its connection pool.
    onShutdown: () => print('worker ${worker.id} stopped'),
  );
}

Future<void> main() async {
  final server = await MultiWorkerServer.start(
    setup: buildWorker,
    address: InternetAddress.loopbackIPv4,
    port: int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080,
  );
  print('${server.workerCount} workers on http://localhost:${server.port}');

  await ProcessSignal.sigint.watch().first;
  await server.close();
}
