import 'dart:io' as io;

/// HttpOverrides que permiten (temporalmente) ignorar la validación TLS
/// exclusivamente para el host savio.utb.edu.co. Úsalo solo como
/// mitigación mientras se corrige el certificado en el servidor o
/// se implementa pinning adecuado.
class SavioHttpOverrides extends io.HttpOverrides {
  @override
  io.HttpClient createHttpClient(io.SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (io.X509Certificate cert, String host, int port) {
      // Permitir solo el host objetivo; todo lo demás mantiene validación normal
      if (host == 'savio.utb.edu.co') return true;
      return false;
    };
    return client;
  }
}
