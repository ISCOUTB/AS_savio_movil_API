import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'package:http/io_client.dart';
import 'package:flutter/foundation.dart';
import 'notification_service.dart';
import 'moodle_token_service.dart';
import 'course_filters.dart';
import 'main.dart';

class FileChangeService {
  static Timer? _timer;
  static Map<String, int> _lastIndex = {}; // key: resource|courseid|cmid -> lastModified
  static bool _running = false;
  static const String taskName = 'savio_file_check';

  static void start({Duration interval = const Duration(minutes: 5)}) {
    if (_running) return;
    _running = true;
    _timer?.cancel();
    // Cargar índice persistido (si existe) para evitar duplicados entre isolates
    _loadPersistedIndex();
    // Hacer un chequeo inicial al minuto para no golpear al inicio
    _timer = Timer.periodic(interval, (_) async {
      try {
        await _checkFiles();
      } catch (_) {}
    });
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  static Future<void> checkNow() async {
    await _checkFiles();
  }

  static Future<void> _checkFiles() async {
    // Obtener token válido
    String? token = await _getValidToken();
    if (token == null) return;
    const base = 'https://savio.utb.edu.co/webservice/rest/server.php';

    // Cliente HTTP local: en debug permite certificado del host savio.utb.edu.co
    http.Client client = http.Client();
    if (kDebugMode) {
      try { client.close(); } catch (_) {}
      final ioHttp = HttpClient()
        ..badCertificateCallback = (X509Certificate cert, String host, int port) {
          return host == 'savio.utb.edu.co';
        };
      client = IOClient(ioHttp);
    }

    // 1) site info -> userid
    final siteInfoUrl = '$base?wstoken=$token&wsfunction=core_webservice_get_site_info&moodlewsrestformat=json';
  final rSite = await client.get(Uri.parse(siteInfoUrl));
    if (rSite.statusCode != 200) return;
    final dSite = json.decode(rSite.body);
    if (dSite is Map && (dSite['exception'] != null || dSite['error'] != null)) return;
    final int userId = (dSite['userid'] as num?)?.toInt() ?? 0;
    if (userId == 0) return;

    // 2) cursos del usuario
    final cursosUrl = '$base?wstoken=$token&wsfunction=core_enrol_get_users_courses&moodlewsrestformat=json&userid=$userId';
  final rCursos = await client.get(Uri.parse(cursosUrl));
    if (rCursos.statusCode != 200) return;
    final dCursos = json.decode(rCursos.body);
    final List cursos = (dCursos is List)
        ? dCursos
        : (dCursos is Map && dCursos['courses'] is List)
            ? dCursos['courses'] as List
            : const [];
    final nombresPorId = <int, String>{};
    final ids = <int>[];
    // Filtrar cursos vigentes para evitar notificaciones de semestres antiguos
    for (final c in cursos.whereType<Map>().where((m) => CourseFilters.isCurrentCourse(m))) {
      try {
        final id = (c['id'] as num?)?.toInt() ?? 0;
        if (id > 0) {
          ids.add(id);
          nombresPorId[id] = (c['fullname'] ?? 'Curso').toString();
        }
      } catch (_) {}
    }
    if (ids.isEmpty) return;

    // 3) obtener contenidos por curso y extraer recursos (mod_resource)
    final nuevoIndex = <String, int>{};
    int notifications = 0;
    for (final part in _chunk(ids, 8)) { // limitar concurrencia
      for (final cid in part) {
        try {
          final q = '$base?wstoken=$token&wsfunction=core_course_get_contents&moodlewsrestformat=json&courseid=$cid';
          final r = await client.get(Uri.parse(q));
          if (r.statusCode != 200) continue;
          final data = json.decode(r.body);
          if (data is! List) continue;
          for (final sec in data) {
            final mods = (sec is Map) ? (sec['modules'] as List? ?? const []) : const [];
            for (final m in mods) {
              if (m is! Map) continue;
              final modname = (m['modname'] ?? '').toString();
              if (modname != 'resource') continue; // Solo archivos de curso
              final cmid = (m['id'] is num) ? (m['id'] as num).toInt() : int.tryParse('${m['id'] ?? ''}') ?? 0;
              if (cmid == 0) continue;
              final moduleModified = (m['timemodified'] is num) ? (m['timemodified'] as num).toInt() : 0;
              final contents = (m['contents'] as List?) ?? const [];
              int filesModified = 0;
              for (final f in contents) {
                if (f is Map) {
                  final tm = (f['timemodified'] is num) ? (f['timemodified'] as num).toInt() : 0;
                  if (tm > filesModified) filesModified = tm;
                }
              }
              final lastMod = (filesModified > 0) ? filesModified : moduleModified;
              final key = 'resource|$cid|$cmid';
              nuevoIndex[key] = lastMod;
            }
          }
        } catch (_) {}
      }
    }

    // 4) Diffs: nuevos, editados, eliminados
    final prev = _lastIndex;
    final cursosPorKey = <String, int>{};
    for (final cid in ids) {
      cursosPorKey['$cid'] = cid; // marcador
    }

    // Nuevos y editados
    for (final entry in nuevoIndex.entries) {
      if (notifications >= 5) break;
      final key = entry.key;
      final newMod = entry.value;
      if (!prev.containsKey(key)) {
        // Nuevo archivo
        final parts = key.split('|');
        final cid = int.tryParse(parts[1]) ?? 0;
        final courseName = nombresPorId[cid] ?? 'Curso';
        final cmid = int.tryParse(parts[2]) ?? 0;
        final url = 'https://savio.utb.edu.co/mod/resource/view.php?id=$cmid';
        await NotificationService.showSimple(
          title: '[${_shorten(courseName, 32)}] Nuevo material',
          body: 'Se ha subido un archivo nuevo',
          id: key.hashCode & 0x7FFFFFFF,
          payload: json.encode({'url': url, 'title': 'Material del curso'}),
        );
        notifications++;
      } else if (prev[key] != newMod) {
        // Editado/actualizado
        final parts = key.split('|');
        final cid = int.tryParse(parts[1]) ?? 0;
        final courseName = nombresPorId[cid] ?? 'Curso';
        final cmid = int.tryParse(parts[2]) ?? 0;
        final url = 'https://savio.utb.edu.co/mod/resource/view.php?id=$cmid';
        await NotificationService.showSimple(
          title: '[${_shorten(courseName, 32)}] Material actualizado',
          body: 'Se ha modificado un archivo existente',
          id: key.hashCode & 0x7FFFFFFF,
          payload: json.encode({'url': url, 'title': 'Material del curso'}),
        );
        notifications++;
      }
    }
    // Eliminados
    for (final key in prev.keys) {
      if (notifications >= 5) break;
      if (!nuevoIndex.containsKey(key)) {
        final parts = key.split('|');
        final cid = int.tryParse(parts[1]) ?? 0;
        final courseName = nombresPorId[cid] ?? 'Curso';
        await NotificationService.showSimple(
          title: '[${_shorten(courseName, 32)}] Material eliminado',
          body: 'Un archivo ya no está disponible',
          id: key.hashCode & 0x7FFFFFFF,
        );
        notifications++;
      }
    }

    _lastIndex = nuevoIndex;
    // Persistir el índice para compartir estado con el isolate de background
    try {
      await _savePersistedIndex(_lastIndex);
    } catch (_) {}

    try {
      client.close();
    } catch (_) {}
  }

  static const String _prefsKey = 'file_change_index_v1';

  static Future<void> _savePersistedIndex(Map<String, int> idx) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_prefsKey, json.encode(idx));
    } catch (_) {}
  }

  static Future<void> _loadPersistedIndex() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final s = sp.getString(_prefsKey);
      if (s != null && s.isNotEmpty) {
        final m = json.decode(s) as Map<String, dynamic>;
        _lastIndex = m.map((k, v) => MapEntry(k, (v is num) ? v.toInt() : int.tryParse('$v') ?? 0));
      }
    } catch (_) {}
  }

  static List<List<T>> _chunk<T>(List<T> list, int size) {
    final chunks = <List<T>>[];
    for (var i = 0; i < list.length; i += size) {
      chunks.add(list.sublist(i, i + size > list.length ? list.length : i + size));
    }
    return chunks;
  }

  static Future<String?> _getValidToken() async {
    String? token = UserSession.accessToken;
    if (token == null || token == 'webview-session') {
      final cookie = UserSession.moodleCookie;
      if (cookie == null) return null;
      try {
        final t = await fetchMoodleMobileToken(cookie);
        if (t != null) {
          UserSession.accessToken = t;
          token = t;
        }
      } catch (_) {
        return null;
      }
    }
    return token;
  }

  static String _shorten(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max - 1)}…';
  }
}