import 'package:orbiter/orbiter.dart';
import 'package:test/test.dart';

class UserAuth {
  final String userId;
  final String role;
  const UserAuth(this.userId, this.role);
}

class TenantId {
  final String value;
  const TenantId(this.value);
}

void main() {
  group('RequestContext', () {
    test('stores and retrieves values by concrete type', () {
      final context = RequestContext();
      context.set(const UserAuth('user_123', 'admin'));
      context.set(const TenantId('tenant_clinic_a'));

      expect(context.has<UserAuth>(), isTrue);
      expect(context.has<TenantId>(), isTrue);
      expect(context.has<String>(), isFalse);

      final auth = context.get<UserAuth>();
      expect(auth.userId, equals('user_123'));
      expect(auth.role, equals('admin'));

      final tenant = context.get<TenantId>();
      expect(tenant.value, equals('tenant_clinic_a'));
    });

    test('get throws StateError when type is not registered', () {
      final context = RequestContext();
      expect(() => context.get<UserAuth>(), throwsStateError);
    });

    test('getOrNull returns null when type is not found', () {
      final context = RequestContext();
      expect(context.getOrNull<UserAuth>(), isNull);
    });

    test('stores and retrieves values by custom key', () {
      final context = RequestContext();
      context.setKey('correlation_id', 'corr-abc-999');

      expect(context.hasKey('correlation_id'), isTrue);
      expect(context.getKeyOrNull<String>('correlation_id'), equals('corr-abc-999'));
      expect(context.getKeyOrNull<String>('unknown_key'), isNull);
    });

    test('remove and clear operate correctly', () {
      final context = RequestContext();
      context.set(const TenantId('t1'));
      context.setKey('flag', true);

      expect(context.length, equals(2));
      final removed = context.remove<TenantId>();
      expect(removed?.value, equals('t1'));
      expect(context.has<TenantId>(), isFalse);

      context.clear();
      expect(context.isEmpty, isTrue);
      expect(context.length, equals(0));
    });

    test('clone produces an independent shallow copy', () {
      final original = RequestContext();
      original.set(const TenantId('tenant_orig'));

      final cloned = original.clone();
      expect(cloned.get<TenantId>().value, equals('tenant_orig'));

      cloned.set(const TenantId('tenant_mutated'));
      expect(original.get<TenantId>().value, equals('tenant_orig'));
      expect(cloned.get<TenantId>().value, equals('tenant_mutated'));
    });

    test('a fresh context answers reads without entries', () {
      final context = RequestContext();
      expect(context.getOrNull<String>(), isNull);
      expect(context.getKeyOrNull<String>('k'), isNull);
      expect(context.has<String>(), isFalse);
      expect(context.hasKey('k'), isFalse);
      expect(context.remove<String>(), isNull);
      expect(context.removeKey('k'), isNull);
      expect(context.length, 0);
      expect(context.isEmpty, isTrue);
      expect(context.isNotEmpty, isFalse);
      context.clear();
      expect(context.clone().isEmpty, isTrue);
      expect(() => context.get<String>(), throwsStateError);
    });
  });
}
