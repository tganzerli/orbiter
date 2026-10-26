/// Thrown when the request body exceeds the configured limit (`maxBodySize`). The
/// default Error Boundary converts it into `413 Payload Too Large`.
final class PayloadTooLargeException implements Exception {
  /// Limit in bytes that was exceeded.
  final int limit;

  /// Creates the exception for a body larger than [limit] bytes.
  const PayloadTooLargeException(this.limit);

  @override
  String toString() => 'PayloadTooLargeException: request body exceeds $limit bytes';
}
