import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({Key? key}) : super(key: key);

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late final CalendarController _calendarController;
  DateTime _displayDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _calendarController = CalendarController();
  }

  @override
  void dispose() {
    _calendarController.dispose();
    super.dispose();
  }

  void _onViewChanged(ViewChangedDetails details) {
    setState(() {
      _displayDate = details.visibleDates[details.visibleDates.length ~/ 2];
    });
  }

  // Eliminadas funciones de navegación personalizada para evitar errores

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Calendario inteligente')),
      body: Column(
        children: [
          // Eliminado header personalizado para evitar errores de reconstrucción
          Expanded(
            child: SfCalendar(
              controller: _calendarController,
              view: CalendarView.month,
              showDatePickerButton: true,
              showNavigationArrow: true,
              todayHighlightColor: Colors.deepPurple,
              selectionDecoration: BoxDecoration(
                color: Colors.deepPurple.withOpacity(0.2),
                border: Border.all(color: Colors.deepPurple, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              monthViewSettings: const MonthViewSettings(
                showAgenda: true,
                agendaStyle: AgendaStyle(
                  backgroundColor: Colors.white,
                  appointmentTextStyle: TextStyle(color: Colors.black),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
