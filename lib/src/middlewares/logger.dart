import '../pipeline/interceptor.dart';

/// Signature of the logging callback.
typedef LogWriter = void Function(String message);

/// Creates a telemetry and logging middleware for HTTP requests.
///
/// Measures the processing latency of each request using a [Stopwatch] and emits a
/// formatted message containing the method, URI path, HTTP status and duration.
///
/// If [logFn] is omitted, the messages are emitted via `print`.
InterceptorFunction requestLogger({LogWriter? logFn}) {
  final write = logFn ?? print;

  return (request, next) async {
    final stopwatch = Stopwatch()..start();

    try {
      final response = await next(request);
      stopwatch.stop();

      final durationMs = stopwatch.elapsedMilliseconds;
      write(
          '[HTTP] ${request.method} ${request.uri.path} -> ${response.statusCode} (${durationMs}ms)');

      return response;
    } catch (error) {
      stopwatch.stop();

      final durationMs = stopwatch.elapsedMilliseconds;
      write(
          '[HTTP] ${request.method} ${request.uri.path} -> ERROR: $error (${durationMs}ms)');

      rethrow;
    }
  };
}
