// Utilidades de filtrado de cursos vigentes para reusar y testear

class CourseFilters {
  // Heurística: si el curso está visible, no completado y su ventana de fechas está cerca del presente
  static bool isCurrentCourse(Map c, {DateTime? now, int startToleranceDays = 15, int endToleranceDays = 30}) {
    // Usar nombre sin guion bajo para evitar lint de variables locales con prefijo
    final currentNow = now ?? DateTime.now();
    final nowSec = currentNow.millisecondsSinceEpoch ~/ 1000;
    final end = (c['enddate'] is num) ? (c['enddate'] as num).toInt() : 0;
    final start = (c['startdate'] is num) ? (c['startdate'] as num).toInt() : 0;
    final completed = (c['completed'] == true) || ((c['progress'] is num) && ((c['progress'] as num).toInt() >= 100));
    final visible = c.containsKey('visible') ? (c['visible'] != 0) : true;
    final startOk = (start == 0) || (start <= nowSec + startToleranceDays * 24 * 3600);
    final endOk = (end == 0) || (end >= nowSec - endToleranceDays * 24 * 3600);
    return visible && !completed && startOk && endOk;
  }
}
