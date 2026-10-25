import 'package:orbiter/orbiter.dart';
import 'package:test/test.dart';

void main() {
  group('Middlewares', () {
    group('cors', () {
      test('short-circuits preflight OPTIONS request with 204 and CORS headers', () async {
        var handlerCalled = false;

        final pipeline = Pipeline().add(
          cors(
            origins: ['https://app.example.com'],
            methods: ['GET', 'POST'],
            headers: ['Content-Type', 'Authorization'],
            allowCredentials: true,
            maxAge: 3600,
          ),
        );

        final handler = pipeline.addHandler((request) {
          handlerCalled = true;
          return Response.ok(body: 'should-not-run');
        });

        final request = Request(
          uri: Uri.parse('http://localhost/api/resource'),
          method: 'OPTIONS',
          headers: {
            'origin': ['https://app.example.com'],
            'access-control-request-method': ['POST'],
          },
        );

        final response = await handler(request);

        expect(response.statusCode, 204);
        expect(handlerCalled, isFalse);
        expect(response.getHeader('access-control-allow-origin'), 'https://app.example.com');
        expect(response.getHeader('access-control-allow-methods'), 'GET, POST');
        expect(response.getHeader('access-control-allow-headers'), 'Content-Type, Authorization');
        expect(response.getHeader('access-control-allow-credentials'), 'true');
        expect(response.getHeader('access-control-max-age'), '3600');
      });

      test('appends CORS headers to regular requests', () async {
        final pipeline = Pipeline().add(
          cors(origins: ['https://client.app']),
        );

        final handler = pipeline.addHandler((request) {
          return Response.ok(body: 'data');
        });

        final request = Request(
          uri: Uri.parse('http://localhost/api/data'),
          method: 'GET',
          headers: {
            'origin': ['https://client.app'],
          },
        );

        final response = await handler(request);

        expect(response.statusCode, 200);
        expect(response.body, 'data');
        expect(response.getHeader('access-control-allow-origin'), 'https://client.app');
      });

      Request withOrigin(String method, String? origin, {bool preflight = false}) => Request(
            uri: Uri.parse('http://localhost/api'),
            method: method,
            headers: {
              if (origin != null) 'origin': [origin],
              if (preflight) 'access-control-request-method': ['POST'],
            },
          );

      test('reflects a single allowed origin among several and adds Vary', () async {
        final handler = Pipeline()
            .add(cors(origins: ['https://a.com', 'https://b.com']))
            .addHandler((request) => Response.ok(body: 'data'));

        final response = await handler(withOrigin('GET', 'https://b.com'));

        expect(response.headers['access-control-allow-origin'], ['https://b.com']);
        expect(response.getHeader('vary'), contains('Origin'));
      });

      test('emits no CORS headers for an origin outside the list', () async {
        final handler = Pipeline()
            .add(cors(origins: ['https://a.com']))
            .addHandler((request) => Response.ok(body: 'data'));

        final response = await handler(withOrigin('GET', 'https://evil.com'));

        expect(response.statusCode, 200);
        expect(response.getHeader('access-control-allow-origin'), isNull);
      });

      test('wildcard origin answers with *', () async {
        final handler = Pipeline()
            .add(cors())
            .addHandler((request) => Response.ok(body: 'data'));

        final response = await handler(withOrigin('GET', 'https://any.com'));

        expect(response.headers['access-control-allow-origin'], ['*']);
      });

      test('rejects wildcard origin combined with credentials', () {
        expect(() => cors(allowCredentials: true), throwsArgumentError);
      });

      test('non-preflight OPTIONS reaches the handler', () async {
        var handlerCalled = false;
        final handler = Pipeline().add(cors()).addHandler((request) {
          handlerCalled = true;
          return Response.ok(body: 'options-handler');
        });

        final response = await handler(withOrigin('OPTIONS', null));

        expect(handlerCalled, isTrue);
        expect(response.body, 'options-handler');
      });
    });

    group('requestLogger', () {
      test('measures request latency and logs status line', () async {
        final logs = <String>[];

        final pipeline = Pipeline().add(
          requestLogger(logFn: logs.add),
        );

        final handler = pipeline.addHandler((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return Response.ok(body: 'pong');
        });

        final request = Request(
          uri: Uri.parse('http://localhost/ping'),
          method: 'GET',
        );

        final response = await handler(request);

        expect(response.statusCode, 200);
        expect(logs, hasLength(1));
        expect(logs.first, contains('[HTTP] GET /ping -> 200'));
        expect(logs.first, contains('ms)'));
      });

      test('logs error and rethrows when downstream throws', () async {
        final logs = <String>[];

        final pipeline = Pipeline().add(
          requestLogger(logFn: logs.add),
        );

        final handler = pipeline.addHandler((request) {
          throw StateError('Simulated crash');
        });

        final request = Request(
          uri: Uri.parse('http://localhost/crash'),
          method: 'POST',
        );

        expect(() => handler(request), throwsA(isA<StateError>()));
        expect(logs, hasLength(1));
        expect(logs.first, contains('[HTTP] POST /crash -> ERROR: Bad state: Simulated crash'));
      });
    });

    group('securityHeaders', () {
      test('injects default security headers on downstream response', () async {
        final pipeline = Pipeline().add(securityHeaders());

        final handler = pipeline.addHandler((request) {
          return Response.ok(body: 'protected-page');
        });

        final request = Request(
          uri: Uri.parse('http://localhost/dashboard'),
          method: 'GET',
        );

        final response = await handler(request);

        expect(response.statusCode, 200);
        expect(response.getHeader('x-content-type-options'), 'nosniff');
        expect(response.getHeader('x-frame-options'), 'DENY');
        expect(response.getHeader('x-xss-protection'), '0');
        expect(response.getHeader('referrer-policy'), 'no-referrer');
      });
    });
  });
}
