import 'dart:async';

import 'package:orbiter/orbiter.dart';
import 'package:test/test.dart';

final class _AuthenticatedUser {
  final String id;
  final String role;

  const _AuthenticatedUser(this.id, this.role);
}

final class _CustomHeaderInterceptor implements Interceptor {
  final String headerName;
  final String headerValue;

  _CustomHeaderInterceptor(this.headerName, this.headerValue);

  @override
  FutureOr<Response> intercept(Request request, NextFunction next) async {
    final response = await next(request);
    return response.withHeader(headerName, headerValue);
  }
}

void main() {
  group('Pipeline & Interceptor Chaining', () {
    test('executes interceptors in FIFO order on request and LIFO order on response', () async {
      final executionTrace = <String>[];

      final pipeline = Pipeline()
          .add((request, next) async {
            executionTrace.add('interceptor-1-enter');
            final response = await next(request);
            executionTrace.add('interceptor-1-exit');
            return response;
          })
          .add((request, next) async {
            executionTrace.add('interceptor-2-enter');
            final response = await next(request);
            executionTrace.add('interceptor-2-exit');
            return response;
          })
          .add((request, next) async {
            executionTrace.add('interceptor-3-enter');
            final response = await next(request);
            executionTrace.add('interceptor-3-exit');
            return response;
          });

      final handler = pipeline.addHandler((request) async {
        executionTrace.add('root-handler');
        return Response.ok(body: 'done');
      });

      final request = Request(
        uri: Uri.parse('http://localhost/test'),
        method: 'GET',
      );

      final response = await handler(request);

      expect(response.statusCode, 200);
      expect(executionTrace, [
        'interceptor-1-enter',
        'interceptor-2-enter',
        'interceptor-3-enter',
        'root-handler',
        'interceptor-3-exit',
        'interceptor-2-exit',
        'interceptor-1-exit',
      ]);
    });

    test('supports short-circuit preventing downstream interceptors and root handler', () async {
      var downstreamExecuted = false;
      var rootExecuted = false;

      final pipeline = Pipeline()
          .add((request, next) async {
            // Interceptor 1: passes through
            return next(request);
          })
          .add((request, next) async {
            // Interceptor 2: short-circuits with 401
            return Response.unauthorized(body: 'unauthorized');
          })
          .add((request, next) async {
            // Interceptor 3: must not be executed
            downstreamExecuted = true;
            return next(request);
          });

      final handler = pipeline.addHandler((request) {
        rootExecuted = true;
        return Response.ok(body: 'never-reached');
      });

      final request = Request(
        uri: Uri.parse('http://localhost/protected'),
        method: 'GET',
      );

      final response = await handler(request);

      expect(response.statusCode, 401);
      expect(response.body, 'unauthorized');
      expect(downstreamExecuted, isFalse);
      expect(rootExecuted, isFalse);
    });

    test('propagates typed RequestContext across upstream and downstream handlers', () async {
      final pipeline = Pipeline().add((request, next) async {
        // Simulates an authentication middleware injecting an identity into the RequestContext
        request.context.set(const _AuthenticatedUser('user-uuid-99', 'admin'));
        return next(request);
      });

      final handler = pipeline.addHandler((request) {
        // Handler consumes the strongly typed identity without Zone
        expect(request.context.has<_AuthenticatedUser>(), isTrue);
        final user = request.context.get<_AuthenticatedUser>();

        return Response.ok(
          body: 'Hello, ${user.id} (${user.role})',
        );
      });

      final request = Request(
        uri: Uri.parse('http://localhost/profile'),
        method: 'GET',
      );

      final response = await handler(request);

      expect(response.statusCode, 200);
      expect(response.body, 'Hello, user-uuid-99 (admin)');
    });

    test('supports class-based Interceptor via addInterceptor', () async {
      final pipeline = Pipeline().addInterceptor(
        _CustomHeaderInterceptor('x-applied-by', 'class-interceptor'),
      );

      final handler = pipeline.addHandler((request) {
        return Response.ok(body: 'content');
      });

      final request = Request(
        uri: Uri.parse('http://localhost/api'),
        method: 'GET',
      );

      final response = await handler(request);

      expect(response.statusCode, 200);
      expect(response.getHeader('x-applied-by'), 'class-interceptor');
    });
  });
}
