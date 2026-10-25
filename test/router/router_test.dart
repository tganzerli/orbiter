import 'dart:convert';
import 'dart:io';

import 'package:orbiter/orbiter.dart';
import 'package:test/test.dart';

void main() {
  group('Router Unit Tests', () {
    test('matches static routes at multiple levels and normalizes slashes', () async {
      final router = Router();

      router.get('/', (request) => Response.ok(body: 'root'));
      router.get('/health', (request) => Response.ok(body: 'health'));
      router.get('/api/v1/users', (request) => Response.ok(body: 'users'));

      // Test root
      final rootRes = await router(Request(
        method: 'GET',
        uri: Uri.parse('http://localhost/'),
      ));
      expect(rootRes.statusCode, equals(200));
      expect(rootRes.body, equals('root'));

      // Test /health with trailing slash
      final healthRes = await router(Request(
        method: 'GET',
        uri: Uri.parse('http://localhost/health/'),
      ));
      expect(healthRes.statusCode, equals(200));
      expect(healthRes.body, equals('health'));

      // Test multiple redundant slashes
      final usersRes = await router(Request(
        method: 'GET',
        uri: Uri.parse('http://localhost///api//v1///users'),
      ));
      expect(usersRes.statusCode, equals(200));
      expect(usersRes.body, equals('users'));
    });

    test('extracts single and multiple dynamic path parameters', () async {
      final router = Router();

      router.get('/users/:id', (request) {
        final id = request.pathParam('id');
        final allParams = request.pathParams;
        return Response.ok(body: 'user-$id-count-${allParams.length}');
      });

      router.get('/tenants/:tId/orders/:oId', (request) {
        final tId = request.pathParam('tId');
        final oId = request.pathParam('oId');
        return Response.ok(body: 'tenant:$tId,order:$oId');
      });

      // Single param
      final res1 = await router(Request(
        method: 'GET',
        uri: Uri.parse('http://localhost/users/42'),
      ));
      expect(res1.statusCode, equals(200));
      expect(res1.body, equals('user-42-count-1'));

      // Multi param
      final res2 = await router(Request(
        method: 'GET',
        uri: Uri.parse('http://localhost/tenants/acme/orders/999'),
      ));
      expect(res2.statusCode, equals(200));
      expect(res2.body, equals('tenant:acme,order:999'));

      // Non-existent param returns null on request.pathParam
      final res3 = await router(Request(
        method: 'GET',
        uri: Uri.parse('http://localhost/users/88'),
      ));
      expect(res3.statusCode, equals(200));
    });

    test('static routes take precedence over dynamic parameter routes', () async {
      final router = Router();

      router.get('/users/active', (request) => Response.ok(body: 'static-active'));
      router.get('/users/:id', (request) => Response.ok(body: 'param-${request.pathParam("id")}'));

      // Exact match to static child
      final activeRes = await router(Request(
        method: 'GET',
        uri: Uri.parse('http://localhost/users/active'),
      ));
      expect(activeRes.statusCode, equals(200));
      expect(activeRes.body, equals('static-active'));

      // Fallback to param child
      final paramRes = await router(Request(
        method: 'GET',
        uri: Uri.parse('http://localhost/users/12345'),
      ));
      expect(paramRes.statusCode, equals(200));
      expect(paramRes.body, equals('param-12345'));
    });

    test('matches wildcards and captures remaining segments', () async {
      final router = Router();

      router.get('/static/*filepath', (request) {
        final path = request.pathParam('filepath');
        return Response.ok(body: 'filepath:$path');
      });

      final res = await router(Request(
        method: 'GET',
        uri: Uri.parse('http://localhost/static/css/themes/dark.min.css'),
      ));
      expect(res.statusCode, equals(200));
      expect(res.body, equals('filepath:css/themes/dark.min.css'));
    });

    test('returns 405 Method Not Allowed with Allow header when route exists for other methods', () async {
      final router = Router();

      router.get('/items', (request) => Response.ok(body: 'get-items'));
      router.post('/items', (request) => Response.ok(body: 'post-items'));

      // PUT /items is not registered
      final putRes = await router(Request(
        method: 'PUT',
        uri: Uri.parse('http://localhost/items'),
      ));

      expect(putRes.statusCode, equals(405));
      expect(putRes.headers['allow'], equals(['GET, POST']));
      expect(putRes.body, equals('Method Not Allowed'));
    });

    test('supports .all() shorthand method registration', () async {
      final router = Router();

      router.all('/ping', (request) => Response.ok(body: 'pong-${request.method}'));

      for (final m in ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS']) {
        final res = await router(Request(
          method: m,
          uri: Uri.parse('http://localhost/ping'),
        ));
        expect(res.statusCode, equals(200));
        expect(res.body, equals('pong-$m'));
      }
    });

    test('returns 404 for unknown route, or delegates to notFoundHandler', () async {
      final router = Router();
      router.get('/known', (request) => Response.ok(body: 'ok'));

      // Default 404
      final default404 = await router(Request(
        method: 'GET',
        uri: Uri.parse('http://localhost/unknown'),
      ));
      expect(default404.statusCode, equals(404));
      expect(default404.body, equals('Not Found'));

      // Custom 404
      router.notFoundHandler = (request) => Response.notFound(
            body: jsonEncode({'error': 'custom-not-found'}),
            headers: {'content-type': ['application/json']},
          );

      final custom404 = await router(Request(
        method: 'GET',
        uri: Uri.parse('http://localhost/unknown'),
      ));
      expect(custom404.statusCode, equals(404));
      expect(custom404.headers['content-type'], equals(['application/json']));
      expect(custom404.body.toString(), contains('custom-not-found'));
    });
  });

  group('Router End-to-End Server Integration (Loopback TCP)', () {
    late BackendServer server;
    late HttpClient client;
    late int port;

    setUp(() async {
      client = HttpClient();

      final router = Router();
      router.get('/health', (request) => Response.ok(body: '{"status":"healthy"}', headers: {'content-type': ['application/json']}));
      router.post('/echo', (request) async {
        final bodyStr = await request.readAsString();
        return Response.ok(body: 'echoed:$bodyStr');
      });
      router.get('/users/:id', (request) {
        final id = request.pathParam('id');
        return Response.ok(body: 'user-$id');
      });
      router.get('/static/*file', (request) {
        final file = request.pathParam('file');
        return Response.ok(body: 'file:$file');
      });

      final app = Pipeline()
          .add(cors(origins: ['*']))
          .addHandler(router.handler);

      server = await BackendServer.bind(
        handler: app,
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      port = server.port;
    });

    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });

    test('routes real HTTP client requests through Pipeline and Trie Router', () async {
      // 1. GET /health
      final req1 = await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'));
      final res1 = await req1.close();
      expect(res1.statusCode, equals(200));
      expect(res1.headers.value('access-control-allow-origin'), equals('*'));
      final body1 = await utf8.decoder.bind(res1).join();
      expect(body1, equals('{"status":"healthy"}'));

      // 2. POST /echo with body
      final req2 = await client.postUrl(Uri.parse('http://127.0.0.1:$port/echo'));
      req2.write('hello-router');
      final res2 = await req2.close();
      expect(res2.statusCode, equals(200));
      final body2 = await utf8.decoder.bind(res2).join();
      expect(body2, equals('echoed:hello-router'));

      // 3. GET /users/777
      final req3 = await client.getUrl(Uri.parse('http://127.0.0.1:$port/users/777'));
      final res3 = await req3.close();
      expect(res3.statusCode, equals(200));
      final body3 = await utf8.decoder.bind(res3).join();
      expect(body3, equals('user-777'));

      // 4. GET /static/assets/img/logo.svg
      final req4 = await client.getUrl(Uri.parse('http://127.0.0.1:$port/static/assets/img/logo.svg'));
      final res4 = await req4.close();
      expect(res4.statusCode, equals(200));
      final body4 = await utf8.decoder.bind(res4).join();
      expect(body4, equals('file:assets/img/logo.svg'));

      // 5. 405 Method Not Allowed on POST /health
      final req5 = await client.postUrl(Uri.parse('http://127.0.0.1:$port/health'));
      final res5 = await req5.close();
      expect(res5.statusCode, equals(405));
      expect(res5.headers.value('allow'), equals('GET'));

      // 6. 404 on nonexistent route
      final req6 = await client.getUrl(Uri.parse('http://127.0.0.1:$port/nonexistent'));
      final res6 = await req6.close();
      expect(res6.statusCode, equals(404));
    });
  });

  group('Router regressions', () {
    Request get(String path, [String method = 'GET']) =>
        Request(method: method, uri: Uri.parse('http://localhost$path'));

    test('param names belong to the route, not to the shared tree node', () async {
      final router = Router()
        ..get('/users/:id', (r) => Response.ok(body: 'user:${r.pathParam('id')}'))
        ..get('/users/:userId/posts',
            (r) => Response.ok(body: 'posts:${r.pathParam('userId')}'))
        ..delete('/users/:key', (r) => Response.ok(body: 'del:${r.pathParam('key')}'));

      expect((await router(get('/users/5'))).body, 'user:5');
      expect((await router(get('/users/5'))).body, isNot(contains('null')));
      expect((await router(get('/users/7/posts'))).body, 'posts:7');
      expect((await router(get('/users/9', 'DELETE'))).body, 'del:9');
    });

    test('wildcard names belong to the route', () async {
      final router = Router()
        ..get('/files/*path', (r) => Response.ok(body: 'p:${r.pathParam('path')}'))
        ..post('/files/*rest', (r) => Response.ok(body: 'r:${r.pathParam('rest')}'));

      expect((await router(get('/files/a/b'))).body, 'p:a/b');
      expect((await router(get('/files/a/b', 'POST'))).body, 'r:a/b');
    });

    test('static routes expose no path params', () async {
      final router = Router()
        ..get('/health', (r) => Response.ok(body: '${r.pathParams.length}'));
      expect((await router(get('/health'))).body, '0');
    });

    test('percent-decodes captured values', () async {
      final router = Router()
        ..get('/enc/:name', (r) => Response.ok(body: r.pathParam('name')))
        ..get('/raw/*rest', (r) => Response.ok(body: r.pathParam('rest')));

      expect((await router(get('/enc/a%20b'))).body, 'a b');
      expect((await router(get('/enc/caf%C3%A9'))).body, 'café');
      expect((await router(get('/raw/x%2Fy/z'))).body, 'x/y/z');
    });

    test('a stray percent sign reaches the handler literally', () async {
      // Uri normalizes "%zz" to "%25zz" at parse time, so decoding cannot fail.
      final router = Router()..get('/enc/:name', (r) => Response.ok(body: r.pathParam('name')));
      final res = await router(get('/enc/%zz'));
      expect(res.statusCode, 200);
      expect(res.body, '%zz');
    });

    test('rejects duplicate param names and non-terminal wildcards at registration', () {
      final router = Router();
      expect(() => router.get('/a/:id/b/:id', (r) => Response.ok()), throwsArgumentError);
      expect(() => router.get('/a/*rest/b', (r) => Response.ok()), throwsArgumentError);
    });
  });
}
