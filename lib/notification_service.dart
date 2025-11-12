import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static void Function(String payload)? _onSelect;
  // Registro de IDs ya enviados recientemente para evitar duplicados (spam)
  static final Map<int, DateTime> _recentIds = {};
  // Ventana de tiempo para deduplicación
  static Duration dedupWindow = const Duration(minutes: 45);
  // Modo de prueba: cuando está activo no se llama al plugin real, sólo se contabilizan intentos
  static bool testing = false;
  static int _debugShowCount = 0;
  static final List<int> _debugShownIds = [];

  static Future<void> init({void Function(String payload)? onSelect}) async {
    if (_initialized) return;
    _onSelect = onSelect;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    final initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          final cb = _onSelect;
          if (cb != null) cb(payload);
        }
      },
    );
    _initialized = true;
  }

  static Future<void> showSimple({
    required String title,
    required String body,
    int id = 0,
    String? payload,
    bool dedup = true,
  }) async {
    const android = AndroidNotificationDetails(
      'updates',
      'Actualizaciones',
      channelDescription: 'Notificaciones de cambios en actividades',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: android);
    // Si dedup es true y el id ya fue mostrado dentro del intervalo, no repetir
    if (dedup && id != 0) {
      final now = DateTime.now();
      final last = _recentIds[id];
      if (last != null && now.difference(last) < dedupWindow) {
        // En modo prueba registramos intento suprimido para poder verificar
        if (testing) {
          _debugShownIds.add(id); // se agrega igual para analizar secuencia
        }
        return; // suprimir duplicado
      }
      _recentIds[id] = now;
      // Limpiar IDs antiguos para no crecer indefinidamente
      _recentIds.removeWhere((_, ts) => now.difference(ts) > dedupWindow * 2);
    }
    if (testing) {
      _debugShowCount++;
      _debugShownIds.add(id);
      return;
    }
    await _plugin.show(id, title, body, details, payload: payload);
  }

  // Métodos auxiliares de prueba
  static void testReset() {
    _recentIds.clear();
    _debugShowCount = 0;
    _debugShownIds.clear();
  }

  static int testNotificationCalls() => _debugShowCount;
  static List<int> testShownIdSequence() => List.unmodifiable(_debugShownIds);

  static Future<void> requestPermissionsIfNeeded() async {
    // On Android 13+ (Tiramisu) notifications require runtime permission.
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }

  static Future<bool> areNotificationsAllowed() async {
    // Try local_notifications API first
    final impl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (impl != null) {
      final allowed = await impl.areNotificationsEnabled();
      if (allowed != null) return allowed;
    }
    // Fallback to permission_handler (Android 13+ exposes runtime permission)
    final status = await Permission.notification.status;
    return status.isGranted || status.isLimited;
  }

  static Future<void> openAppSettingsPage() async {
    await openAppSettings();
  }

  static Future<String?> getLaunchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp == true) {
      return details!.notificationResponse?.payload;
    }
    return null;
  }
}
