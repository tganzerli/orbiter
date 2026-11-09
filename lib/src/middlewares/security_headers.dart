import '../pipeline/interceptor.dart';

/// Creates a middleware that injects recommended HTTP security headers into the
/// application's responses.
///
/// Protects against MIME sniffing and framing attacks (clickjacking).
///
/// `x-xss-protection` is sent as `0` by default: the browsers' legacy XSS filter has been
/// removed and, where it still exists, it introduces vulnerabilities (current OWASP
/// recommendation).
InterceptorFunction securityHeaders({
  String contentTypeOptions = 'nosniff',
  String frameOptions = 'DENY',
  String xssProtection = '0',
  String? strictTransportSecurity,
  String referrerPolicy = 'no-referrer',
}) {
  final headers = <String, List<String>>{
    'x-content-type-options': List.unmodifiable([contentTypeOptions]),
    'x-frame-options': List.unmodifiable([frameOptions]),
    'x-xss-protection': List.unmodifiable([xssProtection]),
    'referrer-policy': List.unmodifiable([referrerPolicy]),
  };

  if (strictTransportSecurity != null) {
    headers['strict-transport-security'] =
        List.unmodifiable([strictTransportSecurity]);
  }

  return (request, next) async {
    final response = await next(request);
    return response.withHeaders(headers);
  };
}
