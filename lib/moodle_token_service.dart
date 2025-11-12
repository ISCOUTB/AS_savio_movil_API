import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart';
// Para cliente HTTP configurable en modo debug (solución temporal)
import 'dart:io';
import 'package:http/io_client.dart';
import 'package:flutter/foundation.dart';

Future<String?> fetchMoodleMobileToken(String cookie) async {
  final url = Uri.parse('https://savio.utb.edu.co/user/managetoken.php');

  // Cliente HTTP. En release usa validación normal de certificados.
  // En debug habilita una excepción puntual para el host, útil si el servidor
  // no entrega la cadena completa y el emulador/dispositivo no confía.
  http.Client client;
  if (kDebugMode) {
    final ioHttp = HttpClient()
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        return host == 'savio.utb.edu.co';
      };
    client = IOClient(ioHttp);
  } else {
    client = http.Client();
  }

  final response = await client.get(url, headers: {
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
