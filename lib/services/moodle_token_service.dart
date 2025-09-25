import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart';

Future<String?> fetchMoodleMobileToken(String cookie) async {
  final url = Uri.parse('https://savio.utb.edu.co/user/managetoken.php');
  final response = await http.get(url, headers: {
    'Cookie': cookie, // Usa la cookie de sesión de Microsoft/Moodle
  });

  if (response.statusCode == 200) {
    Document document = parser.parse(response.body);
    // Busca todas las filas de la tabla
    final rows = document.querySelectorAll('tbody tr');
    for (var row in rows) {
      final cells = row.querySelectorAll('td');
      if (cells.length > 1 && cells[1].text.trim() == 'Moodle mobile web service') {
        return cells[0].text.trim(); // El token está en la primera celda
      }
    }
  }
  return null;
}
