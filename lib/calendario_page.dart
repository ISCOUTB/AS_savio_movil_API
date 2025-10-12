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

class CalendarioPage extends StatefulWidget {
  const CalendarioPage({Key? key}) : super(key: key);

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
            final titulo = tipo == 'assign' ? 'Nueva/actualizada tarea' : (tipo == 'quiz' ? 'Nuevo/actualizado quiz' : 'Actividad actualizada');
            final cuerpo = hora.isNotEmpty ? '$nombre • Cierra a las $hora' : nombre;
            await NotificationService.showSimple(title: titulo, body: cuerpo);
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

    Future<http.Response> _get(String query) async {
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
        final r1 = await _get(q1);
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
              final r2 = await _get(q2);
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

    Future<http.Response> _get(String query) async {
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
        final r = await _get(q);
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

    Future<http.Response> _get(String query) async {
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
        final r = await _get(q);
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
    final todaysKey = _keyFor(_selectedDay);
    final actividadesDelDia = _eventsByDay[todaysKey] ?? [];

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
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Card(
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(6.0),
                  child: TableCalendar<Map<String, dynamic>>(
              firstDay: DateTime.utc(2018, 1, 1),
              lastDay: DateTime.utc(2100, 12, 31),
              focusedDay: _focusedDay,
              startingDayOfWeek: StartingDayOfWeek.monday,
              calendarFormat: CalendarFormat.month,
              selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
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
                      titleTextStyle: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    calendarStyle: const CalendarStyle(
                      isTodayHighlighted: true,
                      todayDecoration: BoxDecoration(color: Color(0x332196F3), shape: BoxShape.circle),
                      selectedDecoration: BoxDecoration(color: Colors.deepPurple, shape: BoxShape.circle),
                    ),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.event_note, size: 20),
                const SizedBox(width: 8),
                Text('Actividades del ${_formatFechaCorta(_selectedDay)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _selectedDay = DateTime.now();
                      _focusedDay = _selectedDay;
                    });
                  },
                  icon: const Icon(Icons.today, size: 16),
                  label: const Text('Hoy'),
                  style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
                if (_loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  selected: _filtroTipos.contains('assign'),
                  label: const Text('Tareas'),
                  avatar: const Icon(Icons.assignment, size: 18),
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
                  label: const Text('Quices'),
                  avatar: const Icon(Icons.quiz, size: 18),
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
            child: _buildActivityList(actividadesDelDia.where((a) => _filtroTipos.contains(a['tipo'])).toList()),
          ),
        ],
      ),
    ),
  );
  }

  Widget _buildActivityList(List<Map<String, dynamic>> actividadesDelDia) {
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
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        itemCount: actividadesDelDia.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
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
          return Card(
            elevation: 0.5,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border(left: BorderSide(color: color, width: 4)),
              ),
              child: ListTile(
                isThreeLine: true,
                leading: CircleAvatar(
                  backgroundColor: color.withOpacity(0.12),
                  child: Icon(
                    act['tipo'] == 'assign' ? Icons.assignment : Icons.quiz,
                    color: color,
                  ),
                ),
                title: Text(act['nombre'] ?? ''),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${act['curso']} • $hora',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (cierre != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Icon(vencido ? Icons.lock_clock : Icons.schedule, size: 16, color: badgeColor),
                            Text(
                              vencido ? 'Cerrado a las $horaCierre' : 'Cierra a las $horaCierre',
                              style: TextStyle(
                                color: badgeColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (!vencido && restante.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: badgeColor.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'Faltan $restante',
                                  style: TextStyle(color: badgeColor, fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
                onTap: () => _openActividad(act),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        act['tipo'] == 'assign' ? 'Tarea' : 'Quiz',
                        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _formatFechaCorta(DateTime fecha) {
    try {
      return DateFormat('d MMM y', 'es').format(fecha);
    } catch (_) {
      return '${fecha.day.toString().padLeft(2, '0')}/${fecha.month.toString().padLeft(2, '0')}/${fecha.year}';
    }
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
}
