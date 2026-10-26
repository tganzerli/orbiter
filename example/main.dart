// A small orbiter server: routes with path parameters, the built-in
// interceptors, one interceptor of your own, and a graceful shutdown.
//
// Run with `dart run example/main.dart`, then:
//   curl localhost:8080/health
//   curl localhost:8080/users/42
//   curl -H 'x-api-key: demo' localhost:8080/me
import 'dart:async';
import 'dart:io';

import 'package:orbiter/orbiter.dart';

/// Typed request-context value set by [requireApiKey].
final class ApiKey {
  const ApiKey(this.value);
  final String value;
}

/// Rejects requests without an `x-api-key` header and stores the key in the
/// request context for the handlers further down.
FutureOr<Response> requireApiKey(Request request, NextFunction next) {
  final key = request.getHeader('x-api-key');
  if (key == null) return Response.unauthorized();
  request.context.set(ApiKey(key));
  return next(request);
}

Future<void> main() async {
  final router = Router()
    ..get('/health', (request) => Response.json({'status': 'ok'}))
    ..get('/users/:id', (request) {
      final id = request.pathParam('id');
      return Response.json({'id': id});
    });

  // A second pipeline guards only the routes that need the key.
  final guarded = Pipeline().add(requireApiKey).addHandler(
        (request) =>
            Response.json({'key': request.context.get<ApiKey>().value}),
      );
  router.get('/me', guarded);

  final app = Pipeline()
      .add(securityHeaders())
      .add(requestLogger())
      .addHandler(router.handler);

  final server = await BackendServer.bind(
    handler: app,
    address: InternetAddress.loopbackIPv4,
    port: int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080,
  );
  print('Listening on http://localhost:${server.port}');

  // Stop accepting connections and let in-flight requests finish.
  await ProcessSignal.sigint.watch().first;
  await server.close();
}
