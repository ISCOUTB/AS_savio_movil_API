import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/intl.dart';
import 'main.dart';
import 'moodle_token_service.dart';
import 'savio_webview_page.dart';
import 'notification_service.dart';

// Urgency helper for badges and sorting
class _Urgency {
  final int rank;
  final String? label;
  final Color color;
  const _Urgency(this.rank, this.label, this.color);
}

class CalendarioPage extends StatefulWidget {
  const CalendarioPage({super.key});

  @override
  State<CalendarioPage> createState() => _CalendarioPageState();
}

class _CalendarioPageState extends State<CalendarioPage> {
  bool _loading = true;
  String? _error;
  // Estado y estructura para calendario
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  Map<String, List<Map<String, dynamic>>> _eventsByDay = {};
  final Set<String> _filtroTipos = {'assign', 'quiz'}; // filtros activos
  Timer? _pollTimer; // actualización periódica
  Map<String, int> _lastIndex = {}; // key -> timestamp de cierre (o inicio)
  // Cache de estado de entrega por actividad (clave construida con _makeKey)
  final Map<String, String> _estadoEntregaCache = {}; // valores: 'entregado' | 'pendiente' | 'na'
  final Set<String> _estadoEnCarga = {}; // para evitar llamadas duplicadas
  // Nuevo: búsqueda, filtro por curso y vista
  // Eliminado campo de búsqueda: solo se conserva filtro por curso y tipos
  int _cursoFiltro = -1; // -1 = todos
  Map<int, String> _cursosDisponibles = {}; // courseId -> nombre

  String _keyFor(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _rebuildEventsIndex(List<Map<String, dynamic>> actividades) {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final a in actividades) {
      final DateTime fecha = a['fechaInicio'] as DateTime;
      final k = _keyFor(fecha);
      (map[k] ??= []).add(a);
    }
    _eventsByDay = map;
  }

  Color _tipoColor(String? tipo) {
    switch (tipo) {
      case 'assign':
        return Colors.blue;
      case 'quiz':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  @override
  void initState() {
    super.initState();
    _fetchActividades();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      await _refreshAndNotify();
    });
  }

  Future<void> _refreshAndNotify() async {
    try {
      final previous = Map<String, int>.from(_lastIndex);
      final actividades = await _cargarActividadesLista();
      actividades.sort((a, b) => a['fechaInicio'].compareTo(b['fechaInicio']));
      _rebuildEventsIndex(actividades);
      _cursosDisponibles = {
        for (final a in actividades)
          if (a['courseid'] is int) (a['courseid'] as int): (a['curso'] ?? 'Curso') as String
      };
      final nuevoIndex = _indexActivities(actividades);
      final cambios = _diffActivities(previous, nuevoIndex);
      _lastIndex = nuevoIndex;
      if (cambios.isNotEmpty) {
        // Notificar hasta 5 cambios por ciclo para evitar spam
        final toNotify = cambios.take(5);
        for (final k in toNotify) {
          final act = actividades.firstWhere(
            (a) => _makeKey(a) == k,
            orElse: () => {},
          );
          if (act.isNotEmpty) {
            final nombre = (act['nombre'] ?? 'Actividad').toString();
            final tipo = (act['tipo'] ?? '').toString();
            final cierre = (act['fechaCierre'] as DateTime?) ?? (act['fechaInicio'] as DateTime?);
            final hora = cierre != null ? DateFormat('HH:mm').format(cierre) : '';
            final curso = (act['curso'] ?? 'Curso').toString();
            final titulo = tipo == 'assign'
                ? '[$curso] Tarea actualizada'
                : (tipo == 'quiz' ? '[$curso] Quiz actualizado' : '[$curso] Actividad actualizada');
            final cuerpo = hora.isNotEmpty ? '$nombre • Cierra a las $hora' : nombre;

            // Construir URL para deep link
            String? url = (act['url'] is String && (act['url'] as String).isNotEmpty) ? act['url'] as String : null;
            final int? cmid = act['cmid'] is num ? (act['cmid'] as num).toInt() : int.tryParse('${act['cmid'] ?? ''}');
            final int? courseId = act['courseid'] is num ? (act['courseid'] as num).toInt() : int.tryParse('${act['courseid'] ?? ''}');
            if (url == null) {
              if (cmid != null && cmid > 0) {
                final base = 'https://savio.utb.edu.co';
                if (tipo == 'assign') url = '$base/mod/assign/view.php?id=$cmid';
                if (tipo == 'quiz') url = '$base/mod/quiz/view.php?id=$cmid';
              } else if (courseId != null && courseId > 0) {
                url = 'https://savio.utb.edu.co/course/view.php?id=$courseId';
              }
            }
            final payload = json.encode({
              'url': url ?? 'https://savio.utb.edu.co/my',
              'title': nombre,
            });
            await NotificationService.showSimple(
              title: titulo,
              body: cuerpo,
              id: k.hashCode & 0x7FFFFFFF,
              payload: payload,
            );
          }
        }
      }
      if (mounted) setState(() {});
    } catch (_) {
      // Silencioso: no mostrar errores en polling
    }
  }

  Future<void> _fetchActividades() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final actividades = await _cargarActividadesLista();
      actividades.sort((a, b) => a['fechaInicio'].compareTo(b['fechaInicio']));
      setState(() {
        _rebuildEventsIndex(actividades);
        _cursosDisponibles = {
          for (final a in actividades)
            if (a['courseid'] is int) (a['courseid'] as int): (a['curso'] ?? 'Curso') as String
        };
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // Carga actividades completas (sin tocar estado), con token refresh y lote
  Future<List<Map<String, dynamic>>> _cargarActividadesLista() async {
    // Obtener token real de Moodle si es necesario
    String? token = UserSession.accessToken;
    final cookie = UserSession.moodleCookie;
    Future<String?> refreshToken() async {
      if (cookie == null) throw 'No hay cookie de sesión.';
      final t = await fetchMoodleMobileToken(cookie);
      if (t == null) throw 'No se pudo obtener el token de Moodle.';
      UserSession.accessToken = t;
      return t;
    }
    if (token == null || token == 'webview-session') {
      token = await refreshToken();
    }
    final url = 'https://savio.utb.edu.co/webservice/rest/server.php';
    // 1) site info -> userid
    final siteInfoUrl = '$url?wstoken=$token&wsfunction=core_webservice_get_site_info&moodlewsrestformat=json';
    final responseSiteInfo = await http.get(Uri.parse(siteInfoUrl));
    if (responseSiteInfo.statusCode != 200) throw 'Error al obtener site info';
    var decodedSite = json.decode(responseSiteInfo.body);
    if (decodedSite is Map && (decodedSite.containsKey('exception') || decodedSite.containsKey('error'))) {
      token = await refreshToken();
      final retrySiteInfoUrl = '$url?wstoken=$token&wsfunction=core_webservice_get_site_info&moodlewsrestformat=json';
      final retrySiteInfo = await http.get(Uri.parse(retrySiteInfoUrl));
      if (retrySiteInfo.statusCode != 200) throw 'Error al obtener site info';
      decodedSite = json.decode(retrySiteInfo.body);
      if (decodedSite is Map && (decodedSite.containsKey('exception') || decodedSite.containsKey('error'))) {
        throw 'Error de Moodle: ${decodedSite['message'] ?? decodedSite['error'] ?? decodedSite.toString()}';
      }
    }
    if (decodedSite['userid'] == null) throw 'No se pudo determinar el usuario.';
    final int userId = (decodedSite['userid'] as num).toInt();

    // 2) cursos por userid
    final cursosUrl = '$url?wstoken=$token&wsfunction=core_enrol_get_users_courses&moodlewsrestformat=json&userid=$userId';
    var responseCursos = await http.get(Uri.parse(cursosUrl));
    if (responseCursos.statusCode == 200) {
      final dc = json.decode(responseCursos.body);
      if (dc is Map && (dc.containsKey('exception') || dc.containsKey('error'))) {
        if ((dc['error'] ?? '').toString().contains('invalidtoken') || (dc['message'] ?? '').toString().contains('token')) {
          token = await refreshToken();
          final retryUrl = '$url?wstoken=$token&wsfunction=core_enrol_get_users_courses&moodlewsrestformat=json&userid=$userId';
          responseCursos = await http.get(Uri.parse(retryUrl));
        }
      }
    }
    if (responseCursos.statusCode != 200) throw 'Error al obtener cursos';
    final decodedCursos = json.decode(responseCursos.body);
    if (decodedCursos is Map && (decodedCursos.containsKey('exception') || decodedCursos.containsKey('error'))) {
      throw 'Error de Moodle: ${decodedCursos['message'] ?? decodedCursos['error'] ?? decodedCursos.toString()}';
    }
    List cursos;
    if (decodedCursos is List) {
      cursos = decodedCursos;
    } else if (decodedCursos is Map && decodedCursos.containsKey('courses')) {
      cursos = decodedCursos['courses'] as List;
    } else {
      throw 'Respuesta inesperada al obtener cursos: ${decodedCursos.toString()}';
    }
    // Lote de eventos
    final ids = <int>[];
    final nombresPorId = <int, String>{};
    for (var curso in cursos) {
      final cid = (curso['id'] as num).toInt();
      ids.add(cid);
      nombresPorId[cid] = (curso['fullname'] ?? '').toString();
    }
    final actividades = await _fetchActividadesPorLotes(token!, ids, nombresPorId);
    return actividades;
  }

  Map<String, int> _indexActivities(List<Map<String, dynamic>> acts) {
    final map = <String, int>{};
    for (final a in acts) {
      final k = _makeKey(a);
      final cierre = (a['fechaCierre'] as DateTime?) ?? (a['fechaInicio'] as DateTime?);
      map[k] = (cierre?.millisecondsSinceEpoch ?? (a['fechaInicio'] as DateTime).millisecondsSinceEpoch);
    }
    return map;
  }

  Iterable<String> _diffActivities(Map<String, int> oldIdx, Map<String, int> newIdx) {
    final changes = <String>{};
    for (final k in newIdx.keys) {
      if (!oldIdx.containsKey(k)) {
        changes.add(k); // nueva
      } else if (oldIdx[k] != newIdx[k]) {
        changes.add(k); // modificada
      }
    }
    return changes;
  }

  String _makeKey(Map<String, dynamic> a) {
    final tipo = (a['tipo'] ?? '').toString();
    final cid = a['courseid']?.toString() ?? '';
    final id = (a['cmid']?.toString() ?? a['instance']?.toString() ?? a['nombre']?.toString() ?? '');
    return '$tipo|$cid|$id';
  }

  // Obtiene actividades (eventos de calendario y, si faltan, fallbacks) por lotes para los cursos indicados
  Future<List<Map<String, dynamic>>> _fetchActividadesPorLotes(
    String token,
    List<int> courseIds,
    Map<int, String> nombresPorId,
  ) async {
    // 1) Intentar obtener eventos de calendario para todos los cursos por lotes
    final eventos = await _batchCalendarEvents(token, courseIds);

    // Mapear eventos a actividades filtrando tipos relevantes
    final actividades = <Map<String, dynamic>>[];
    final cursosConEventos = <int>{};
    for (final e in eventos) {
      try {
        if (e is Map && (e['modulename'] == 'assign' || e['modulename'] == 'quiz')) {
          final ts = (e['timestart'] is String)
              ? int.tryParse(e['timestart']) ?? 0
              : (e['timestart'] as num?)?.toInt() ?? 0;
          int cid = 0;
          final rawCid = e['courseid'] ?? e['course'];
          if (rawCid is num) {
            cid = rawCid.toInt();
          } else if (rawCid is String) {
            cid = int.tryParse(rawCid) ?? 0;
          }
          if (ts > 0 && cid != 0) {
            cursosConEventos.add(cid);
            actividades.add({
              'curso': nombresPorId[cid] ?? 'Curso',
              'nombre': e['name'],
              'fechaInicio': DateTime.fromMillisecondsSinceEpoch(ts * 1000),
              'fechaCierre': DateTime.fromMillisecondsSinceEpoch(ts * 1000),
              'tipo': e['modulename'],
              'courseid': cid,
              'instance': (e['instance'] is num) ? (e['instance'] as num).toInt() : (e['instance'] is String ? int.tryParse(e['instance']) : null),
              'url': (e['url'] ?? '') as String,
            });
          }
        }
      } catch (_) {}
    }

    // 2) Si hay cursos sin eventos del calendario, completar con fallbacks (assign/quizzes) en lote
    final faltantes = courseIds.where((id) => !cursosConEventos.contains(id)).toList();
    if (faltantes.isNotEmpty) {
      final asignacionesFut = _batchAssignments(token, faltantes);
      final quizzesFut = _batchQuizzes(token, faltantes);
      final resultados = await Future.wait([asignacionesFut, quizzesFut]);
      final asignaciones = resultados[0];
      final quizzes = resultados[1];

      for (final a in asignaciones) {
        try {
          int cid = 0;
          final rawCid = a['courseid'] ?? a['course'];
          if (rawCid is num) {
            cid = rawCid.toInt();
          } else if (rawCid is String) {
            cid = int.tryParse(rawCid) ?? 0;
          }
          final dd = (a['duedate'] as num?)?.toInt() ?? 0;
          if (cid != 0 && dd > 0) {
            actividades.add({
              'curso': nombresPorId[cid] ?? 'Curso',
              'nombre': a['name'],
              'fechaInicio': DateTime.fromMillisecondsSinceEpoch(dd * 1000),
              'fechaCierre': DateTime.fromMillisecondsSinceEpoch(dd * 1000),
              'tipo': 'assign',
              'courseid': cid,
              'cmid': (a['cmid'] is num) ? (a['cmid'] as num).toInt() : (a['cmid'] is String ? int.tryParse(a['cmid']) : null),
              'instance': (a['id'] is num) ? (a['id'] as num).toInt() : (a['id'] is String ? int.tryParse(a['id']) : null),
            });
          }
        } catch (_) {}
      }
      for (final q in quizzes) {
        try {
          int cid = 0;
          final rawCid = q['courseid'] ?? q['course'];
          if (rawCid is num) {
            cid = rawCid.toInt();
          } else if (rawCid is String) {
            cid = int.tryParse(rawCid) ?? 0;
          }
          final tc = (q['timeclose'] as num?)?.toInt() ?? 0;
          if (cid != 0 && tc > 0) {
            actividades.add({
              'curso': nombresPorId[cid] ?? 'Curso',
              'nombre': q['name'],
              'fechaInicio': DateTime.fromMillisecondsSinceEpoch(tc * 1000),
              'fechaCierre': DateTime.fromMillisecondsSinceEpoch(tc * 1000),
              'tipo': 'quiz',
              'courseid': cid,
              'cmid': (q['cmid'] is num) ? (q['cmid'] as num).toInt() : (q['cmid'] is String ? int.tryParse(q['cmid']) : null),
              'instance': (q['id'] is num) ? (q['id'] as num).toInt() : (q['id'] is String ? int.tryParse(q['id']) : null),
            });
          }
        } catch (_) {}
      }
    }

    return actividades;
  }

  // Helper: divide una lista en trozos para evitar URLs demasiado largas
  List<List<T>> _chunk<T>(List<T> list, int size) {
    final chunks = <List<T>>[];
    for (var i = 0; i < list.length; i += size) {
      chunks.add(list.sublist(i, i + size > list.length ? list.length : i + size));
    }
    return chunks;
  }

  Future<List<dynamic>> _batchCalendarEvents(String token, List<int> courseIds) async {
    const base = 'https://savio.utb.edu.co/webservice/rest/server.php';
    final resultados = <dynamic>[];

    Future<http.Response> doGet(String query) async {
      final full = '$base?$query';
      debugPrint('GET: $full');
      return await http.get(Uri.parse(full));
    }

    // Probar por lotes usando events[courseids][i]; si falla por parámetro inválido, reintentar con courseids[i]
    for (final part in _chunk(courseIds, 20)) {
      final idsQueryEvents = part
          .asMap()
          .entries
          .map((e) => 'events%5Bcourseids%5D%5B${e.key}%5D=${e.value}')
          .join('&');
      final q1 = 'wstoken=$token&wsfunction=core_calendar_get_calendar_events&moodlewsrestformat=json&$idsQueryEvents&options%5Bignorehidden%5D=1&options%5Buserevents%5D=0&options%5Bsiteevents%5D=0';
      try {
        final r1 = await doGet(q1);
        if (r1.statusCode == 200) {
          final d1 = json.decode(r1.body);
          if (d1 is Map && (d1.containsKey('exception') || d1.containsKey('error'))) {
            final msg = (d1['message'] ?? d1['error'] ?? '').toString().toLowerCase();
            if (msg.contains('invalid parameter')) {
              // Reintentar con courseids[i]
              final idsQueryPlain = part
                  .asMap()
                  .entries
                  .map((e) => 'courseids%5B${e.key}%5D=${e.value}')
                  .join('&');
              final q2 = 'wstoken=$token&wsfunction=core_calendar_get_calendar_events&moodlewsrestformat=json&$idsQueryPlain&options%5Bignorehidden%5D=1&options%5Buserevents%5D=0&options%5Bsiteevents%5D=0';
              final r2 = await doGet(q2);
              if (r2.statusCode == 200) {
                final d2 = json.decode(r2.body);
                if (d2 is Map && !(d2.containsKey('exception') || d2.containsKey('error'))) {
                  resultados.addAll((d2['events'] ?? []) as List);
                }
              }
            } else {
              // Otro error: ignorar este lote
            }
          } else {
            resultados.addAll((d1['events'] ?? []) as List);
          }
        }
      } catch (_) {}
    }
    return resultados;
  }

  Future<List<dynamic>> _batchAssignments(String token, List<int> courseIds) async {
    const base = 'https://savio.utb.edu.co/webservice/rest/server.php';
    final resultados = <dynamic>[];

    Future<http.Response> doGet(String query) async {
      final full = '$base?$query';
      debugPrint('GET: $full');
      return await http.get(Uri.parse(full));
    }

    for (final part in _chunk(courseIds, 20)) {
      final idsQuery = part
          .asMap()
          .entries
          .map((e) => 'courseids%5B${e.key}%5D=${e.value}')
          .join('&');
      final q = 'wstoken=$token&wsfunction=mod_assign_get_assignments&moodlewsrestformat=json&$idsQuery';
      try {
        final r = await doGet(q);
        if (r.statusCode == 200) {
          final d = json.decode(r.body);
          final courses = (d['courses'] ?? []) as List;
          for (final c in courses) {
            final assigns = (c['assignments'] ?? []) as List;
            final cid = (c['id'] as num?)?.toInt() ?? (c['courseid'] as num?)?.toInt() ?? 0;
            for (final a in assigns) {
              // Enriquecer con courseid para homogenizar
              a['courseid'] = a['courseid'] ?? cid;
              resultados.add(a);
            }
          }
        }
      } catch (_) {}
    }
    return resultados;
  }

  Future<List<dynamic>> _batchQuizzes(String token, List<int> courseIds) async {
    const base = 'https://savio.utb.edu.co/webservice/rest/server.php';
    final resultados = <dynamic>[];

    Future<http.Response> doGet(String query) async {
      final full = '$base?$query';
      debugPrint('GET: $full');
      return await http.get(Uri.parse(full));
    }

    for (final part in _chunk(courseIds, 20)) {
      final idsQuery = part
          .asMap()
          .entries
          .map((e) => 'courseids%5B${e.key}%5D=${e.value}')
          .join('&');
      final q = 'wstoken=$token&wsfunction=mod_quiz_get_quizzes_by_courses&moodlewsrestformat=json&$idsQuery';
      try {
        final r = await doGet(q);
        if (r.statusCode == 200) {
          final d = json.decode(r.body);
          final quizzes = (d['quizzes'] ?? []) as List;
          for (final q in quizzes) {
            resultados.add(q);
          }
        }
      } catch (_) {}
    }
    return resultados;
  }


  @override
  Widget build(BuildContext context) {
  final DateTime baseDia = _selectedDay;
  final actividadesBase = (_eventsByDay[_keyFor(baseDia)] ?? const <Map<String, dynamic>>[]);
    final actividadesFiltradas = _filtrarYOrdenar(actividadesBase);

  final bottomInset = MediaQuery.of(context).viewInsets.bottom;
  final collapseCalendar = bottomInset > 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Calendario de Actividades')),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF4F1FF), Color(0xFFFFFFFF)],
          ),
        ),
        child: Column(
          children: [
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 180),
              crossFadeState: collapseCalendar ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              firstChild: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Card(
                  elevation: 1,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: TableCalendar<Map<String, dynamic>>(
                      firstDay: DateTime.utc(2018, 1, 1),
                      lastDay: DateTime.utc(2100, 12, 31),
                      focusedDay: _focusedDay,
                      locale: 'es',
                      startingDayOfWeek: StartingDayOfWeek.monday,
                      calendarFormat: CalendarFormat.month,
                      rowHeight: 36,
                      daysOfWeekHeight: 18,
                      selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                      daysOfWeekStyle: DaysOfWeekStyle(
                        weekendStyle: TextStyle(color: Colors.redAccent.withValues(alpha: 0.7), fontWeight: FontWeight.w600, fontSize: 11),
                        weekdayStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
                        dowTextFormatter: (date, locale) {
                          final txt = DateFormat.E(locale).format(date);
                          return txt.substring(0, 1).toUpperCase();
                        },
                      ),
                      eventLoader: (day) => (_eventsByDay[_keyFor(day)] ?? []),
                      onDaySelected: (selectedDay, focusedDay) {
                        setState(() {
                          _selectedDay = selectedDay;
                          _focusedDay = focusedDay;
                        });
                      },
                      onPageChanged: (focusedDay) => _focusedDay = focusedDay,
                      headerStyle: const HeaderStyle(
                        formatButtonVisible: false,
                        titleCentered: true,
                        leftChevronIcon: Icon(Icons.chevron_left_rounded),
                        rightChevronIcon: Icon(Icons.chevron_right_rounded),
                        titleTextStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                      calendarStyle: const CalendarStyle(
                        isTodayHighlighted: true,
                        todayDecoration: BoxDecoration(
                          color: Color(0x1F7C4DFF),
                          shape: BoxShape.circle,
                        ),
                        todayTextStyle: TextStyle(color: Color(0xFF5B2EE5), fontWeight: FontWeight.w800),
                        selectedDecoration: BoxDecoration(color: Color(0xFF5B2EE5), shape: BoxShape.circle),
                        selectedTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                        outsideDaysVisible: true,
                      ),
                      calendarBuilders: CalendarBuilders<Map<String, dynamic>>(
                        selectedBuilder: (context, date, _) => _buildDayCircle(date, const Color(0xFF5B2EE5), Colors.white),
                        todayBuilder: (context, date, _) => _buildDayCircle(date, const Color(0x1F7C4DFF), const Color(0xFF5B2EE5), filled: false),
                        markerBuilder: (context, date, events) => _buildMarkers(events),
                      ),
                    ),
                  ),
                ),
              ),
              secondChild: const SizedBox.shrink(),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.event_note, size: 18),
                    const SizedBox(width: 6),
                    const Text('Actividades', style: TextStyle(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    if (_loading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Divider(height: 12),
          ),
          // Búsqueda y filtros
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.black12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        isDense: true,
                        value: _cursoFiltro,
                        onChanged: (v) => setState(() => _cursoFiltro = v ?? -1),
                        items: [
                          const DropdownMenuItem(value: -1, child: Text('Todos los cursos')),
                          ..._cursosDisponibles.entries
                              .map((e) => DropdownMenuItem<int>(value: e.key, child: Text(_shorten(e.value, 26)))),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  selected: _filtroTipos.contains('assign'),
                  label: Text('Tareas', style: TextStyle(color: _tipoColor('assign'), fontSize: 12, fontWeight: FontWeight.w700)),
                  avatar: Icon(Icons.assignment, size: 16, color: _tipoColor('assign')),
                  backgroundColor: _tipoColor('assign').withValues(alpha: 0.10),
                  selectedColor: _tipoColor('assign').withValues(alpha: 0.18),
                  side: BorderSide(color: _tipoColor('assign').withValues(alpha: 0.45)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (v) => setState(() {
                    if (v) {
                      _filtroTipos.add('assign');
                    } else {
                      _filtroTipos.remove('assign');
                    }
                  }),
                ),
                ChoiceChip(
                  selected: _filtroTipos.contains('quiz'),
                  label: Text('Quices', style: TextStyle(color: _tipoColor('quiz'), fontSize: 12, fontWeight: FontWeight.w700)),
                  avatar: Icon(Icons.quiz, size: 16, color: _tipoColor('quiz')),
                  backgroundColor: _tipoColor('quiz').withValues(alpha: 0.10),
                  selectedColor: _tipoColor('quiz').withValues(alpha: 0.18),
                  side: BorderSide(color: _tipoColor('quiz').withValues(alpha: 0.45)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (v) => setState(() {
                    if (v) {
                      _filtroTipos.add('quiz');
                    } else {
                      _filtroTipos.remove('quiz');
                    }
                  }),
                ),
              ],
            ),
          ),
          Expanded(
            child: _buildActivityList(actividadesFiltradas),
          ),
        ],
      ),
    ),
  );
  }

  Widget _buildActivityList(List<Map<String, dynamic>> actividadesDelDia) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 12),
              Text('Error: $_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _fetchActividades,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (actividadesDelDia.isEmpty) {
      return const Center(child: Text('No hay actividades para este día.'));
    }
    return RefreshIndicator(
      onRefresh: _fetchActividades,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(8, 4, 8, 8 + bottomInset),
        itemCount: actividadesDelDia.length,
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (context, i) {
          final act = actividadesDelDia[i];
          final Color color = _tipoColor(act['tipo']);
          final String hora = DateFormat('HH:mm').format(act['fechaInicio'] as DateTime);
          final DateTime? cierre = act['fechaCierre'] as DateTime?;
          final now = DateTime.now();
          final bool vencido = cierre != null && cierre.isBefore(now);
          final String horaCierre = cierre != null ? DateFormat('HH:mm').format(cierre) : hora;
          final String restante = cierre != null
              ? _formatDuracion(cierre.difference(now))
              : '';
          final Color badgeColor = vencido ? Colors.red : (cierre != null ? Colors.green : color);
          final _Urgency u = _urgencyInfo(cierre);

          // Asegurar la carga del estado de entrega (lazy)
          final String key = _makeKey(act);
          _ensureEstadoEntrega(act, key);
          final String? estado = _estadoEntregaCache[key]; // 'entregado' | 'pendiente' | 'na' | null
          final bool entregado = estado == 'entregado';
          final bool esEvaluable = (act['tipo'] == 'assign' || act['tipo'] == 'quiz');
          final Color estadoColor = entregado
              ? Colors.green
              : (vencido ? Colors.red : Colors.amber[800]!);
          return Card(
            elevation: 0.25,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border(left: BorderSide(color: color, width: 3)),
              ),
              child: ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                leading: SizedBox(
                  width: 32,
                  child: Container(
                    height: 28,
                    width: 28,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      act['tipo'] == 'assign' ? Icons.assignment : Icons.quiz,
                      color: color,
                      size: 16,
                    ),
                  ),
                ),
                title: Text(
                  act['nombre'] ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${act['curso']} • $hora',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.black.withValues(alpha: 0.6)),
                    ),
                    if (cierre != null) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (u.label != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: u.color.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: u.color.withValues(alpha: 0.45)),
                              ),
                              child: Text(
                                u.label!,
                                style: TextStyle(color: u.color, fontSize: 11, fontWeight: FontWeight.w700),
                              ),
                            ),
                          if (esEvaluable)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  entregado
                                      ? Icons.check_circle
                                      : (vencido ? Icons.assignment_late : Icons.hourglass_empty),
                                  size: 13,
                                  color: estadoColor,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  entregado
                                      ? 'Entregado'
                                      : (estado == null && _estadoEnCarga.contains(key)
                                          ? 'Verificando…'
                                          : 'Pendiente'),
                                  style: TextStyle(color: estadoColor, fontSize: 11, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(vencido ? Icons.lock_clock : Icons.schedule, size: 13, color: badgeColor),
                              const SizedBox(width: 4),
                              Text(
                                vencido ? 'Cerrado $horaCierre' : 'Cierra $horaCierre',
                                style: TextStyle(color: badgeColor, fontSize: 11, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                          if (!vencido && restante.isNotEmpty)
                            Text(
                              'Faltan $restante',
                              style: TextStyle(color: badgeColor.withValues(alpha: 0.9), fontSize: 11, fontWeight: FontWeight.w500),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
                onTap: () => _openActividad(act),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    act['tipo'] == 'assign' ? 'Tarea' : 'Quiz',
                    style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ====== Calendar custom builders ======
  Widget _buildDayCircle(DateTime date, Color bg, Color fg, {bool filled = true}) {
    final String text = DateFormat('d', 'es').format(date);
    return Center(
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: filled ? bg : Colors.transparent,
          shape: BoxShape.circle,
          border: filled ? null : Border.all(color: fg, width: 1.5),
        ),
        alignment: Alignment.center,
        child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 12)),
      ),
    );
  }

  Widget? _buildMarkers(List<dynamic> events) {
    if (events.isEmpty) return null;
    // Mostrar hasta 4 puntitos de color según tipo
    final dots = events.take(4).map((e) {
      final tipo = (e is Map) ? (e['tipo']?.toString() ?? '') : '';
      final c = _tipoColor(tipo);
      return Container(
        width: 6,
        height: 6,
        margin: const EdgeInsets.symmetric(horizontal: 1.5),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.85), shape: BoxShape.circle),
      );
    }).toList();
    return Positioned(
      bottom: 3,
      left: 0,
      right: 0,
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: dots),
    );
  }

  String _formatDuracion(Duration d) {
    if (d.isNegative) {
      final pos = Duration(seconds: -d.inSeconds);
      return _formatDuracion(pos);
    }
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    final seconds = d.inSeconds.remainder(60);
    if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    }
    return '${seconds}s';
  }

  // ====== Filtrado, orden y utilidades de vista ======

  List<Map<String, dynamic>> _filtrarYOrdenar(List<Map<String, dynamic>> base) {
  const q = '';
    final out = base.where((a) {
      final matchTipo = _filtroTipos.contains(a['tipo']);
      final matchCurso = _cursoFiltro == -1 || (a['courseid'] is int && a['courseid'] == _cursoFiltro);
      final matchSearch = q.isEmpty ||
          (a['nombre']?.toString().toLowerCase().contains(q) == true) ||
          (a['curso']?.toString().toLowerCase().contains(q) == true);
      return matchTipo && matchCurso && matchSearch;
    }).toList();

    out.sort((a, b) {
      final ar = _urgencyRankFor(a);
      final br = _urgencyRankFor(b);
      if (ar != br) return ar.compareTo(br);
      final DateTime ad = (a['fechaCierre'] as DateTime?) ?? (a['fechaInicio'] as DateTime);
      final DateTime bd = (b['fechaCierre'] as DateTime?) ?? (b['fechaInicio'] as DateTime);
      return ad.compareTo(bd);
    });
    return out;
  }

  int _urgencyRankFor(Map<String, dynamic> act) {
    final now = DateTime.now();
    final cierre = (act['fechaCierre'] as DateTime?) ?? (act['fechaInicio'] as DateTime?);
    int baseRank = 99; // por defecto lejos
    if (cierre != null) {
      if (cierre.isBefore(now)) {
        baseRank = 0; // atrasada
      } else if (_isSameDay(cierre, now)) {
        baseRank = 1; // vence hoy
      } else if (cierre.difference(now) <= const Duration(hours: 24)) {
        baseRank = 2; // en 24h
      } else {
        baseRank = 3; // posterior
      }
    }
    // Si ya está entregada, bájala en prioridad (suma offset)
    final key = _makeKey(act);
    final delivered = _estadoEntregaCache[key] == 'entregado';
    if (delivered) baseRank += 10;
    return baseRank;
  }

  bool _isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  _Urgency _urgencyInfo(DateTime? cierre) {
    final now = DateTime.now();
    if (cierre == null) return const _Urgency(99, null, Colors.grey);
    if (cierre.isBefore(now)) return const _Urgency(0, 'Atrasada', Colors.red);
    if (_isSameDay(cierre, now)) return const _Urgency(1, 'Vence hoy', Colors.deepOrange);
    if (cierre.difference(now) <= const Duration(hours: 24)) {
      return const _Urgency(2, 'En 24h', Colors.amber);
    }
    return const _Urgency(3, null, Colors.grey);
  }

  

  String _shorten(String s, int max) {
    if (s.length <= max) return s;
  return '${s.substring(0, max - 1)}…';
  }

  

  void _openActividad(Map<String, dynamic> act) {
    final String base = 'https://savio.utb.edu.co';
    String? url = (act['url'] is String && (act['url'] as String).isNotEmpty) ? act['url'] as String : null;
    final String tipo = (act['tipo'] ?? '').toString();
    final int? cmid = act['cmid'] is int ? act['cmid'] as int : (act['cmid'] is num ? (act['cmid'] as num).toInt() : null);
    final int? courseId = act['courseid'] is int ? act['courseid'] as int : (act['courseid'] is num ? (act['courseid'] as num).toInt() : null);
    final int? instance = act['instance'] is int ? act['instance'] as int : (act['instance'] is num ? (act['instance'] as num).toInt() : null);

    // Normalizar URL relativa
    if (url != null && url.startsWith('/')) {
      url = '$base$url';
    }

    // Si no hay URL, construir por cmid cuando sea posible
    if (url == null && cmid != null) {
      if (tipo == 'assign') {
        url = '$base/mod/assign/view.php?id=$cmid';
      } else if (tipo == 'quiz') {
        url = '$base/mod/quiz/view.php?id=$cmid';
      }
    }

    // Si aún no tenemos URL y contamos con courseId+instance, resolvemos velozmente el cmid vía core_course_get_contents
    if (url == null && courseId != null && instance != null && tipo.isNotEmpty) {
      _openResolviendoModulo(courseId, tipo, instance, act['nombre']?.toString() ?? 'Actividad');
      return;
    }

    // Fallback: ir a la página del curso
    url ??= (courseId != null && courseId > 0)
        ? '$base/course/view.php?id=$courseId'
        : '$base/my';

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SavioWebViewPage(
          initialUrl: url,
          title: act['nombre']?.toString(),
        ),
      ),
    );
  }

  Future<void> _openResolviendoModulo(int courseId, String tipo, int instance, String titulo) async {
    // Mostrar loader mientras resolvemos el cmid/url exacto
    _showLoadingDialog('Abriendo actividad...');
    try {
      final url = await _resolverUrlModulo(courseId, tipo, instance);
      if (!mounted) return;
      Navigator.of(context).pop(); // cerrar loader
      final destino = url ?? 'https://savio.utb.edu.co/course/view.php?id=$courseId';
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SavioWebViewPage(initialUrl: destino, title: titulo),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pop();
      // Fallback a curso
      final destino = 'https://savio.utb.edu.co/course/view.php?id=$courseId';
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SavioWebViewPage(initialUrl: destino, title: titulo),
        ),
      );
    }
  }

  Future<String?> _resolverUrlModulo(int courseId, String tipo, int instance) async {
    // Asegurar token
    String? token = UserSession.accessToken;
    if (token == null || token == 'webview-session') {
      final cookie = UserSession.moodleCookie;
      if (cookie != null) {
        final t = await fetchMoodleMobileToken(cookie);
        if (t != null) {
          UserSession.accessToken = t;
          token = t;
        }
      }
    }
    if (token == null) return null;

    final base = 'https://savio.utb.edu.co/webservice/rest/server.php';
    final q = 'wstoken=$token&wsfunction=core_course_get_contents&moodlewsrestformat=json&courseid=$courseId';
    final uri = Uri.parse('$base?$q');
    final r = await http.get(uri);
    if (r.statusCode != 200) return null;
    final d = json.decode(r.body);
    if (d is Map && (d['exception'] != null || d['error'] != null)) return null;
    if (d is! List) return null;
    // Recorrer secciones y módulos para encontrar coincidencia por modname/instance
    for (final sec in d) {
      final mods = (sec is Map) ? (sec['modules'] as List? ?? const []) : const [];
      for (final m in mods) {
        if (m is Map) {
          final modname = (m['modname'] ?? '').toString();
          final inst = (m['instance'] is num) ? (m['instance'] as num).toInt() : int.tryParse('${m['instance'] ?? ''}') ?? -1;
          if (modname == tipo && inst == instance) {
            // Preferir URL del módulo si viene; si no, armar por cmid
            String? url = (m['url'] is String && (m['url'] as String).isNotEmpty) ? m['url'] as String : null;
            final cmid = (m['id'] is num) ? (m['id'] as num).toInt() : int.tryParse('${m['id'] ?? ''}') ?? 0;
            if (url == null && cmid > 0) {
              final baseHost = 'https://savio.utb.edu.co';
              if (tipo == 'assign') url = '$baseHost/mod/assign/view.php?id=$cmid';
              if (tipo == 'quiz') url = '$baseHost/mod/quiz/view.php?id=$cmid';
            }
            return url;
          }
        }
      }
    }
    return null;
  }

  void _showLoadingDialog(String msg) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 4),
              const CircularProgressIndicator(strokeWidth: 2.2),
              const SizedBox(width: 16),
              Flexible(child: Text(msg)),
            ],
          ),
        ),
      ),
    );
  }

  // ====== Estados de entrega (lazy) ======
  Future<void> _ensureEstadoEntrega(Map<String, dynamic> act, String key) async {
    if (_estadoEntregaCache.containsKey(key)) return;
    if (_estadoEnCarga.contains(key)) return;
    if (!(act['tipo'] == 'assign' || act['tipo'] == 'quiz')) return;
    final int? instance = act['instance'] is num
        ? (act['instance'] as num).toInt()
        : int.tryParse('${act['instance'] ?? ''}');
    if (instance == null) return;
    _estadoEnCarga.add(key);
    // Disparar en microtask para no bloquear el build
    scheduleMicrotask(() async {
      try {
        final token = await _getValidToken();
        if (token == null) return;
        bool delivered = false;
        if (act['tipo'] == 'assign') {
          delivered = await _isAssignmentSubmitted(token, instance);
        } else if (act['tipo'] == 'quiz') {
          delivered = await _isQuizFinished(token, instance);
        }
        _estadoEntregaCache[key] = delivered ? 'entregado' : 'pendiente';
      } catch (_) {
        // Si falla, marcar como pendiente por defecto para no bloquear UX
        _estadoEntregaCache[key] = 'pendiente';
      } finally {
        _estadoEnCarga.remove(key);
        if (mounted) setState(() {});
      }
    });
  }

  Future<String?> _getValidToken() async {
    String? token = UserSession.accessToken;
    if (token == null || token == 'webview-session') {
      final cookie = UserSession.moodleCookie;
      if (cookie == null) return null;
      final t = await fetchMoodleMobileToken(cookie);
      if (t != null) {
        UserSession.accessToken = t;
        token = t;
      }
    }
    return token;
  }

  Future<bool> _isAssignmentSubmitted(String token, int assignId) async {
    const base = 'https://savio.utb.edu.co/webservice/rest/server.php';
    final q = 'wstoken=$token&wsfunction=mod_assign_get_submission_status&moodlewsrestformat=json&assignid=$assignId';
    try {
      final r = await http.get(Uri.parse('$base?$q'));
      if (r.statusCode != 200) return false;
      final d = json.decode(r.body);
      if (d is Map && (d['exception'] != null || d['error'] != null)) return false;
      final lastAttempt = (d is Map) ? (d['lastattempt'] as Map?) : null;
      final submission = lastAttempt != null ? (lastAttempt['submission'] as Map?) : null;
      final status = (submission?['status'] ?? '').toString();
      // Estados posibles: 'new', 'reopened', 'submitted'...
      return status == 'submitted';
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isQuizFinished(String token, int quizId) async {
    const base = 'https://savio.utb.edu.co/webservice/rest/server.php';
    final q = 'wstoken=$token&wsfunction=mod_quiz_get_user_attempts&moodlewsrestformat=json&quizid=$quizId&status=all';
    try {
      final r = await http.get(Uri.parse('$base?$q'));
      if (r.statusCode != 200) return false;
      final d = json.decode(r.body);
      if (d is Map && (d['exception'] != null || d['error'] != null)) return false;
      final attempts = (d['attempts'] as List?) ?? const [];
      for (final a in attempts) {
        if (a is Map) {
          final state = (a['state'] ?? '').toString().toLowerCase();
          if (state == 'finished') return true; // intento enviado/finalizado
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
