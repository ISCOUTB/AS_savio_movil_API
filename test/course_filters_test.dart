import 'package:flutter_test/flutter_test.dart';
import 'package:arquisoft/course_filters.dart';

void main() {
  group('CourseFilters.isCurrentCourse', () {
    final now = DateTime(2025, 11, 11);
    int toSec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

    test('Curso visible y dentro de ventana es vigente', () {
      final course = {
        'id': 10,
        'fullname': 'Algoritmos',
        'startdate': toSec(now.subtract(const Duration(days: 10))),
        'enddate': toSec(now.add(const Duration(days: 5))),
        'progress': 50,
        'visible': 1,
      };
      expect(CourseFilters.isCurrentCourse(course, now: now), isTrue);
    });

    test('Curso completado no es vigente aunque fechas coincidan', () {
      final course = {
        'id': 11,
        'fullname': 'Base de Datos',
        'startdate': toSec(now.subtract(const Duration(days: 10))),
        'enddate': toSec(now.add(const Duration(days: 5))),
        'progress': 100,
        'visible': 1,
      };
      expect(CourseFilters.isCurrentCourse(course, now: now), isFalse);
    });

    test('Curso invisible no es vigente', () {
      final course = {
        'id': 12,
        'fullname': 'Calculo',
        'startdate': toSec(now.subtract(const Duration(days: 2))),
        'enddate': toSec(now.add(const Duration(days: 1))),
        'visible': 0,
      };
      expect(CourseFilters.isCurrentCourse(course, now: now), isFalse);
    });

    test('Curso con enddate muy pasado no es vigente', () {
      final course = {
        'id': 13,
        'fullname': 'Arquitectura',
        'startdate': toSec(now.subtract(const Duration(days: 120))),
        'enddate': toSec(now.subtract(const Duration(days: 60))),
        'visible': 1,
      };
      expect(CourseFilters.isCurrentCourse(course, now: now), isFalse);
    });
  });
}
