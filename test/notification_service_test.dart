import 'package:flutter_test/flutter_test.dart';
import 'package:arquisoft/notification_service.dart';
import 'dart:async';

void main() {
  group('NotificationService dedup', () {
    setUp(() {
      NotificationService.testing = true;
      NotificationService.testReset();
      NotificationService.dedupWindow = const Duration(minutes: 30);
    });

    test('Emite primera y suprime duplicado dentro de la ventana', () async {
      await NotificationService.showSimple(title: 'A', body: 'B', id: 123);
      await NotificationService.showSimple(title: 'A', body: 'B', id: 123);
      expect(NotificationService.testNotificationCalls(), 1);
      expect(NotificationService.testShownIdSequence().length, 2, reason: 'Debe registrar intento suprimido');
    });

    test('Permite nuevamente después de ventana', () async {
      await NotificationService.showSimple(title: 'A', body: 'B', id: 7);
      // Simular que pasó la ventana moviendo internamente los timestamps
      NotificationService.dedupWindow = const Duration(milliseconds: 1);
      await Future.delayed(const Duration(milliseconds: 2));
      await NotificationService.showSimple(title: 'A', body: 'B', id: 7);
      expect(NotificationService.testNotificationCalls(), 2);
    });

    test('IDs distintos no se deduplican', () async {
      await NotificationService.showSimple(title: 'A', body: 'B', id: 1);
      await NotificationService.showSimple(title: 'A', body: 'B', id: 2);
      expect(NotificationService.testNotificationCalls(), 2);
    });

    test('Persistencia básica de dedup (simulada)', () async {
      // Primera notificación
      await NotificationService.showSimple(title: 'X', body: 'Y', id: 999);
      // Simular "reinicio" sin limpiar _recentIds (omitimos testReset)
      // En modo testing no persiste, así que forzamos ventana corta y repetimos inmediatamente.
      await NotificationService.showSimple(title: 'X', body: 'Y', id: 999);
      expect(NotificationService.testNotificationCalls(), 1, reason: 'Debe seguir deduplicando en la misma sesión');
      // Esperar más allá de la ventana y reemitir
      NotificationService.dedupWindow = const Duration(milliseconds: 5);
      await Future.delayed(const Duration(milliseconds: 8));
      await NotificationService.showSimple(title: 'X', body: 'Y', id: 999);
      expect(NotificationService.testNotificationCalls(), 2, reason: 'Debe permitir tras ventana caducada');
    });
  });
}
