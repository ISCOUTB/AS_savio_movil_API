import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'main.dart';
import 'savio_webview_page.dart';
import 'moodle_token_service.dart';

class ActividadesCalificacionesPage extends StatefulWidget {
  const ActividadesCalificacionesPage({super.key});

  @override
  State<ActividadesCalificacionesPage> createState() => _ActividadesCalificacionesPageState();
}

class _ActividadesCalificacionesPageState extends State<ActividadesCalificacionesPage> {
  http.Client _client = http.Client();
  bool _loading = true; // carga inicial de cursos
  String? _error;
  List<Map<String, dynamic>> _courses = [];
  final Map<int, List<Map<String, dynamic>>> _courseActivities = {}; // actividades por curso (lazy)
  final Map<int, bool> _courseLoading = {}; // estado de carga por curso
  int? _userId; // cache user id
  String? _token; // cache token

  @override
  void initState() {
    super.initState();
    // Inicializar cliente HTTP respetando la opción de certificados inválidos.
    if (AppConfig.allowInvalidCerts) {
      final ioHttp = HttpClient()
        ..badCertificateCallback = (X509Certificate cert, String host, int port) => host == 'savio.utb.edu.co';
      _client = IOClient(ioHttp);
    } else {
      _client = http.Client();
    }
    _initSessionAndCourses();
  }

  @override
  void dispose() {
    try { _client.close(); } catch (_) {}
    super.dispose();
  }

  Future<void> _initSessionAndCourses() async {
    setState(() { _loading = true; _error = null; });
    try {
      _token = await _ensureToken();
      if (_token == null) throw 'No se pudo obtener token de Moodle.';
      _userId = await _fetchUserId(_token!);
      final courses = await _fetchCourses(_token!, _userId!);
      setState(() { _courses = courses; _loading = false; });
    } catch (e) {
      debugPrint('Actividades: fallo initSession: $e');
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _refreshAll() async {
    // refresca cursos y limpia actividades cacheadas
    _courseActivities.clear();
    _courseLoading.clear();
    await _initSessionAndCourses();
  }

  Future<String?> _ensureToken() async {
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

  Future<int> _fetchUserId(String token) async {
    final base = 'https://savio.utb.edu.co/webservice/rest/server.php';
    final q = '$base?wstoken=$token&wsfunction=core_webservice_get_site_info&moodlewsrestformat=json';
    final r = await _client.get(Uri.parse(q));
    if (r.statusCode != 200) throw 'Error al obtener site info';
    final d = json.decode(r.body);
    if (d is Map && (d['exception'] != null || d['error'] != null)) throw 'Error de Moodle: ${d['error'] ?? d['message'] ?? d.toString()}';
    return (d['userid'] as num).toInt();
  }

  Future<List<Map<String, dynamic>>> _fetchCourses(String token, int userId) async {
    final base = 'https://savio.utb.edu.co/webservice/rest/server.php';
    final q = '$base?wstoken=$token&wsfunction=core_enrol_get_users_courses&moodlewsrestformat=json&userid=$userId';
    final r = await _client.get(Uri.parse(q));
    if (r.statusCode != 200) throw 'Error al obtener cursos';
    final d = json.decode(r.body);
    if (d is Map && (d['exception'] != null || d['error'] != null)) throw 'Error de Moodle: ${d['error'] ?? d['message'] ?? d.toString()}';
    if (d is List) {
      return List<Map<String, dynamic>>.from(d.map((e) => Map<String, dynamic>.from(e as Map)));
    }
    return [];
  }

  Future<List<Map<String, dynamic>>> _fetchActivitiesForCourse(String token, int courseId) async {
    final List<Map<String, dynamic>> out = [];
    // Intentar obtener todos los grade items del curso para evitar múltiples llamadas por actividad
    Map<int, Map<String, dynamic>> gradeItemsAssign = {}; // key: instance id
    Map<int, Map<String, dynamic>> gradeItemsQuiz = {};
    try {
      final gradeItems = await _fetchCourseGradeItems(token, courseId, _userId);
      for (final gi in gradeItems) {
        final module = (gi['itemmodule'] ?? '').toString();
        final instance = gi['iteminstance'];
        final iid = _toInt(instance, -1);
        if (iid > -1) {
          if (module == 'assign') gradeItemsAssign[iid] = gi;
          if (module == 'quiz') gradeItemsQuiz[iid] = gi;
        }
      }
    } catch (e, st) {
      debugPrint('fetchCourseGradeItems failed: $e');
      debugPrint('$st');
    }
    // 1) Intentar obtener asignaciones
    try {
      final assigns = await _getAssignments(token, courseId);
      for (final a in assigns) {
        final id = _toInt(a['id']);
        // Moodle para assign usa 'cmid'; en otros contextos podría venir como 'coursemodule'.
        final cmid = (a['cmid'] is num)
            ? (a['cmid'] as num).toInt()
            : (a['coursemodule'] is num)
                ? (a['coursemodule'] as num).toInt()
                : null;
        Map<String, String>? gradeInfo;
        // Intentar extraer de gradeItems primero
        final gi = gradeItemsAssign[id];
        if (gi != null) {
          final obtained = _extractDouble(gi['grade_raw']) ?? _extractDouble(gi['grade']);
          final maxG = _extractDouble(gi['grademax']) ?? 100.0;
          if (obtained != null && maxG > 0) {
            final scaled = (obtained / maxG) * 5.0;
            gradeInfo = {
              'display': '${scaled.clamp(0,5).toStringAsFixed(2)}/5',
              'raw': obtained.toStringAsFixed(2),
            };
          }
        }
        // Fallback si no se obtuvo
        gradeInfo ??= await _fetchAssignmentGradeInfo(token, id);
        out.add({
          'tipo': 'assign',
          'name': a['name'] ?? a['nombre'] ?? '',
          'duedate': (a['duedate'] is num) ? DateTime.fromMillisecondsSinceEpoch((a['duedate'] as num).toInt() * 1000) : null,
          'gradeDisplay': gradeInfo?['display'],
          'gradeRaw': gradeInfo?['raw'],
          'id': id,
          'cmid': cmid,
        });
      }
    } catch (e, st) {
      debugPrint('getAssignments failed: $e');
      debugPrint('$st');
    }

    // 2) Intentar quizzes
    try {
      final quizzes = await _getQuizzes(token, courseId);
      for (final q in quizzes) {
        final id = _toInt(q['id']);
        // En quizzes el campo suele ser 'coursemodule'; algunos plugins podrían exponer 'cmid'.
        final cmid = (q['cmid'] is num)
            ? (q['cmid'] as num).toInt()
            : (q['coursemodule'] is num)
                ? (q['coursemodule'] as num).toInt()
                : null;
        final double? maxQuiz = _extractDouble(q['sumgrades']);
        Map<String, String>? gradeInfo;
        final gi = gradeItemsQuiz[id];
        if (gi != null) {
          final obtained = _extractDouble(gi['grade_raw']) ?? _extractDouble(gi['grade']);
          final maxG = _extractDouble(gi['grademax']) ?? maxQuiz ?? 100.0;
          if (obtained != null && maxG > 0) {
            final scaled = (obtained / maxG) * 5.0;
            gradeInfo = {
              'display': '${scaled.clamp(0,5).toStringAsFixed(2)}/5',
              'raw': obtained.toStringAsFixed(2),
            };
          }
        }
        gradeInfo ??= await _fetchQuizGradeInfo(token, id, maxQuiz);
        out.add({
          'tipo': 'quiz',
          'name': q['name'] ?? '',
          'duedate': (q['timeclose'] is num) ? DateTime.fromMillisecondsSinceEpoch((q['timeclose'] as num).toInt() * 1000) : null,
          'gradeDisplay': gradeInfo?['display'],
          'gradeRaw': gradeInfo?['raw'],
          'id': id,
          'cmid': cmid,
        });
      }
    } catch (e, st) {
      debugPrint('getQuizzes failed: $e');
      debugPrint('$st');
    }

    // Ordenar por duedate
    out.sort((a, b) {
      final da = a['duedate'] as DateTime?;
      final db = b['duedate'] as DateTime?;
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    });
    return out;
  }

  Future<List<dynamic>> _fetchCourseGradeItems(String token, int courseId, int? userId) async {
    if (userId == null) return [];
    try {
      final base = 'https://savio.utb.edu.co/webservice/rest/server.php';
      final q = '$base?wstoken=$token&wsfunction=gradereport_user_get_grade_items&moodlewsrestformat=json&courseid=$courseId&userid=$userId';
      final r = await _client.get(Uri.parse(q));
      if (r.statusCode != 200) return [];
      final d = json.decode(r.body);
      if (d is Map && d.containsKey('gradeitems')) {
        final gi = d['gradeitems'];
        if (gi is List) return gi;
      }
      // Algunos formatos: {usergrades:[{gradeitems:[...] }]}
      if (d is Map && d['usergrades'] is List) {
        final ug = d['usergrades'] as List;
        if (ug.isNotEmpty && ug[0] is Map) {
          final g = (ug[0] as Map)['gradeitems'];
          if (g is List) return g;
        }
      }
    } catch (e, st) {
      debugPrint('fetchCourseGradeItems error: $e');
      debugPrint('$st');
    }
    return [];
  }

  Future<List<dynamic>> _getAssignments(String token, int courseId) async {
    final base = 'https://savio.utb.edu.co/webservice/rest/server.php';
    final q = '$base?wstoken=$token&wsfunction=mod_assign_get_assignments&moodlewsrestformat=json&courseids%5B0%5D=$courseId';
    final r = await _client.get(Uri.parse(q));
    if (r.statusCode != 200) return [];
    final d = json.decode(r.body);
    if (d is Map && d.containsKey('courses')) {
      final courses = (d['courses'] as List? ?? []);
      if (courses.isNotEmpty) {
        final assigns = (courses[0]['assignments'] as List? ?? []);
        return assigns;
      }
    }
    return [];
  }

  Future<List<dynamic>> _getQuizzes(String token, int courseId) async {
    final base = 'https://savio.utb.edu.co/webservice/rest/server.php';
    final q = '$base?wstoken=$token&wsfunction=mod_quiz_get_quizzes_by_courses&moodlewsrestformat=json&courseids%5B0%5D=$courseId';
    final r = await _client.get(Uri.parse(q));
    if (r.statusCode != 200) return [];
    final d = json.decode(r.body);
    if (d is Map && d.containsKey('quizzes')) {
      return (d['quizzes'] as List? ?? []);
    }
    return [];
  }

  // Nueva extracción y normalización: devuelve nota escalada a /5 y nota cruda.
  Future<Map<String, String>?> _fetchAssignmentGradeInfo(String token, int assignId) async {
    try {
      final base = 'https://savio.utb.edu.co/webservice/rest/server.php';
      final q = '$base?wstoken=$token&wsfunction=mod_assign_get_submission_status&moodlewsrestformat=json&assignid=$assignId';
      final r = await _client.get(Uri.parse(q));
      if (r.statusCode != 200) return null;
      final d = json.decode(r.body);
      if (d is Map && (d['exception'] != null || d['error'] != null)) return null;
      final last = d['lastattempt'] as Map?;
      double? obtained;
      double? maxGrade;
      if (last != null) {
        final raw = last['grade'] ?? last['attempt']?['grade'] ?? last['gradeformatted'];
        if (raw != null) {
          obtained = _extractFirstNumber(raw.toString());
          final two = _extractTwoNumbers(raw.toString());
          if (two.length == 2) {
            obtained = two[0];
            maxGrade = two[1];
          }
        }
      }
      final grading = d['gradinginfo'] as Map?;
      if (grading != null) {
        final items = grading['gradeitems'] as List?;
        if (items != null && items.isNotEmpty) {
          final first = items[0] as Map?;
          maxGrade ??= _extractDouble(first?['grademax']);
          obtained ??= _extractDouble(first?['grade']);
          obtained ??= _extractDouble(grading['finalgrade']);
        }
      }
      if (obtained == null) return null;
      maxGrade ??= 100.0;
      if (maxGrade == 0) maxGrade = 100.0;
      final scaled = (obtained / maxGrade) * 5.0;
      final display = '${scaled.clamp(0, 5).toStringAsFixed(2)}/5';
      return {'display': display, 'raw': obtained.toStringAsFixed(2)};
    } catch (e, st) {
      debugPrint('fetchAssignmentGradeInfo error: $e');
      debugPrint('$st');
    }
    return null;
  }

  Future<Map<String, String>?> _fetchQuizGradeInfo(String token, int quizId, double? maxQuiz) async {
    try {
      final base = 'https://savio.utb.edu.co/webservice/rest/server.php';
      final q = '$base?wstoken=$token&wsfunction=mod_quiz_get_user_attempts&moodlewsrestformat=json&quizid=$quizId&status=all';
      final r = await _client.get(Uri.parse(q));
      if (r.statusCode != 200) return null;
      final d = json.decode(r.body);
      if (d is Map && (d['exception'] != null || d['error'] != null)) return null;
      final attempts = (d['attempts'] as List? ?? []);
      double? obtained;
      for (final a in attempts.reversed) {
        if (a is Map) {
          final state = (a['state'] ?? '').toString().toLowerCase();
          if (state == 'finished' || state == 'over' || state == 'completed' || state.isEmpty) {
            obtained = _extractDouble(a['sumgrades']) ?? _extractDouble(a['grade']);
            if (obtained != null) break;
          }
        }
      }
      obtained ??= attempts.isNotEmpty ? _extractDouble((attempts.first as Map)['sumgrades']) : null;
      if (obtained == null) return null;
      final maxGrade = (maxQuiz != null && maxQuiz > 0) ? maxQuiz : 100.0;
      final scaled = (obtained / maxGrade) * 5.0;
      final display = '${scaled.clamp(0, 5).toStringAsFixed(2)}/5';
      return {'display': display, 'raw': obtained.toStringAsFixed(2)};
    } catch (e, st) {
      debugPrint('fetchQuizGradeInfo error: $e');
      debugPrint('$st');
    }
    return null;
  }

  // Helpers de extracción numérica
  double? _extractDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim());
  }
  double? _extractFirstNumber(String s) {
    final reg = RegExp(r'(\d+(?:[\.,]\d+)?)');
    final m = reg.firstMatch(s);
    if (m != null) {
      return double.tryParse(m.group(1)!.replaceAll(',', '.'));
    }
    return null;
  }
  List<double> _extractTwoNumbers(String s) {
    final reg = RegExp(r'(\d+(?:[\.,]\d+)?)');
    final matches = reg.allMatches(s).map((m) => m.group(1)!.replaceAll(',', '.'));
    final out = <double>[];
    for (final txt in matches) {
      final n = double.tryParse(txt);
      if (n != null) out.add(n);
      if (out.length == 2) break;
    }
    return out;
  }

  // Helper: parse int from dynamic values robustly
  int _toInt(dynamic v, [int fallback = 0]) {
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is num) return v.toInt();
    final s = v.toString();
    return int.tryParse(s) ?? fallback;
  }

  Widget _buildBody() {
  if (_loading) return const Center(child: CircularProgressIndicator());
  if (_error != null) return Center(child: Text('Error: $_error'));
  if (_courses.isEmpty) return const Center(child: Text('No se encontraron cursos.'));

    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _courses.length,
        itemBuilder: (context, i) {
          final c = _courses[i];
          final cid = _toInt(c['id']);
          final acts = _courseActivities[cid] ?? [];
          final loadingCourse = _courseLoading[cid] == true;
          final hasLoaded = _courseActivities.containsKey(cid);
          final subtitleText = loadingCourse
              ? 'Cargando actividades...'
              : (!hasLoaded
                  ? 'Toca para cargar actividades'
                  : (acts.isEmpty
                      ? 'Sin actividades evaluables'
                      : 'Actividades evaluables: ${acts.length}'));
          return Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: ExpansionTile(
              title: Text('${c['fullname'] ?? c['shortname'] ?? 'Curso'}', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(subtitleText),
              onExpansionChanged: (expanded) async {
                if (expanded && acts.isEmpty && !loadingCourse && _token != null) {
                  setState(() { _courseLoading[cid] = true; });
                  final fetched = await _fetchActivitiesForCourse(_token!, cid);
                  // marcaremos las actividades como pendientes de cargar nota
                  for (final a in fetched) {
                    // limpiar flags previos
                    a.remove('_loadingGrade');
                    a.remove('_gradeError');
                  }
                  _courseActivities[cid] = fetched;
                  if (mounted) setState(() { _courseLoading[cid] = false; });
                  // intentar cargar las calificaciones para esas actividades en segundo plano
                  _ensureGradesForActivities(cid);
                }
              },
              children: acts.isEmpty
                  ? [
                      loadingCourse
                          ? Padding(
                              padding: const EdgeInsets.symmetric(vertical: 18),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: const [CircularProgressIndicator()],
                              ),
                            )
                          : const ListTile(title: Text('No hay actividades evaluables detectadas.'))
                    ]
                  : acts.map((a) {
                      final tipo = a['tipo'] ?? '';
                      final name = a['name'] ?? '';
                      final grade = a['gradeDisplay'] as String?;
                      final dued = a['duedate'] as DateTime?;
                      final subtitle = dued != null ? 'Cierre: ${dued.toLocal()}' : 'Sin fecha de cierre';
                      return ListTile(
                        leading: Icon(tipo == 'assign' ? Icons.assignment : Icons.quiz, color: tipo == 'assign' ? Colors.blue : Colors.orange),
                        title: Text(name),
                        subtitle: Text(subtitle),
                        trailing: a['_loadingGrade'] == true
                            ? const SizedBox(width: 28, height: 18, child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))))
                            : (grade != null ? Text('Nota: $grade', style: const TextStyle(fontWeight: FontWeight.w700)) : const Text('Sin calificación')),
                        onTap: () {
                          // Abrir en webview usando SIEMPRE el course module id (cmid). Si no existe, caer al curso.
                          final cmid = a['cmid'] as int?;
                          final courseId = cid; // del cierre superior
                          String url = 'https://savio.utb.edu.co/course/view.php?id=$courseId';
                          if (cmid != null && cmid > 0) {
                            if (tipo == 'assign') {
                              url = 'https://savio.utb.edu.co/mod/assign/view.php?id=$cmid';
                            } else if (tipo == 'quiz') {
                              url = 'https://savio.utb.edu.co/mod/quiz/view.php?id=$cmid';
                            }
                          }
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => SavioWebViewPage(initialUrl: url, title: name)));
                        },
                      );
                    }).toList(),
            ),
          );
        },
      ),
    );
  }

  // Intenta para un curso cargar las calificaciones de cada actividad listada.
  // Actualiza cada actividad dentro de _courseActivities[cid] cuando obtiene un resultado.
  Future<void> _ensureGradesForActivities(int courseId) async {
    final acts = _courseActivities[courseId];
    if (acts == null) return;
    for (var i = 0; i < acts.length; i++) {
      final a = acts[i];
      if (a['gradeDisplay'] != null) continue; // ya tiene nota
      // marcar como cargando
      a['_loadingGrade'] = true;
      if (mounted) setState(() {});
      try {
        final tipo = (a['tipo'] ?? '').toString();
        final id = _toInt(a['id']);
        Map<String, String>? gi;
        if (tipo == 'assign') {
          gi = await _fetchAssignmentGradeInfo(_token!, id);
        } else if (tipo == 'quiz') {
          final maxQuiz = _extractDouble(a['sumgrades'] ?? a['maxgrade']);
          gi = await _fetchQuizGradeInfo(_token!, id, maxQuiz);
        }
        if (gi != null) {
          a['gradeDisplay'] = gi['display'];
          a['gradeRaw'] = gi['raw'];
        } else {
          a['_gradeError'] = true;
        }
      } catch (e) {
        debugPrint('ensureGradesForActivities error: $e');
        a['_gradeError'] = true;
      } finally {
        a.remove('_loadingGrade');
        if (mounted) setState(() {});
      }
    }
  }

  // Intenta cargar calificaciones para todos los cursos ya listados
  Future<void> _ensureAllGrades() async {
    final keys = _courseActivities.keys.toList();
    for (final k in keys) {
      await _ensureGradesForActivities(k);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Dejar que AppBar muestre el botón atrás automático si aplica.
        automaticallyImplyLeading: true,
        title: Row(
          children: [
            // Logo pequeño al inicio (no quita el botón atrás)
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.all(4),
              child: ClipOval(
                child: Image.asset(
                  'assets/images.png',
                  height: 32,
                  width: 32,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Expanded(child: Text('Actividades y calificaciones')),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refrescar calificaciones',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              if (_token == null) {
                // intentar reasegurar token
                _token = await _ensureToken();
              }
              await _ensureAllGrades();
            },
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFF4F1FF), Color(0xFFFFFFFF)]),
        ),
        child: _buildBody(),
      ),
    );
  }
}
