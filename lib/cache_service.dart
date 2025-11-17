import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Servicio de caché ligero basado en SharedPreferences.
/// - Guarda cadenas/JSON junto a un timestamp para validar caducidad.
/// - Pensado para respuestas pequeñas/medianas (listas y mapas compactos).
class CacheService {
  /// Guarda cualquier estructura JSON (Map/List/valor primitivo) bajo `key`.
  /// `value` debe ser serializable a JSON. Si contiene DateTime, conviene
  /// convertirlo previamente (p.ej., a milisegundos) desde el llamador.
  static Future<void> setJson(String key, Object value) async {
    final sp = await SharedPreferences.getInstance();
    final encoded = json.encode(value);
    await sp.setString(key, encoded);
    await sp.setInt(_tsKey(key), DateTime.now().millisecondsSinceEpoch);
  }

  /// Obtiene y decodifica JSON (Map/List) si existe y no está expirado.
  /// Si `maxAge` es null, no se verifica caducidad.
  static Future<dynamic> getJson(String key, {Duration? maxAge}) async {
    final sp = await SharedPreferences.getInstance();
    final s = sp.getString(key);
    if (s == null) return null;
    if (maxAge != null) {
      final ts = sp.getInt(_tsKey(key));
      if (ts == null) return null;
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (age > maxAge.inMilliseconds) return null;
    }
    try {
      return json.decode(s);
    } catch (_) {
      return null;
    }
  }

  /// Obtiene JSON ignorando caducidad (útil para modo offline/fallback).
  static Future<dynamic> getJsonStale(String key) async {
    final sp = await SharedPreferences.getInstance();
    final s = sp.getString(key);
    if (s == null) return null;
    try {
      return json.decode(s);
    } catch (_) {
      return null;
    }
  }

  static Future<void> setString(String key, String value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(key, value);
    await sp.setInt(_tsKey(key), DateTime.now().millisecondsSinceEpoch);
  }

  static Future<String?> getString(String key, {Duration? maxAge}) async {
    final sp = await SharedPreferences.getInstance();
    final v = sp.getString(key);
    if (v == null) return null;
    if (maxAge != null) {
      final ts = sp.getInt(_tsKey(key));
      if (ts == null) return null;
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (age > maxAge.inMilliseconds) return null;
    }
    return v;
  }

  static Future<void> remove(String key) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(key);
    await sp.remove(_tsKey(key));
  }

  static String _tsKey(String key) => '${key}__ts';
}
