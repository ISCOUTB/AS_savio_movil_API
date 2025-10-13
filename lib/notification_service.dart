import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static void Function(String payload)? _onSelect;

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
  }) async {
    const android = AndroidNotificationDetails(
      'updates',
      'Actualizaciones',
      channelDescription: 'Notificaciones de cambios en actividades',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: android);
    await _plugin.show(id, title, body, details, payload: payload);
  }

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
