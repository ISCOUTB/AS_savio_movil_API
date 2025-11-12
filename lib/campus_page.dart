import 'package:flutter/material.dart';

// Renderiza directamente las páginas 1 (mapa) y 2 (leyenda) del PDF como imágenes.
class CampusPage extends StatefulWidget {
  const CampusPage({super.key});

  @override
  State<CampusPage> createState() => _CampusPageState();
}

class _CampusPageState extends State<CampusPage> {
  // No PDF: mostrarmos una o dos imágenes PNG con zoom.
  // Imagen alta del campus provista en PNG.
  final String campusAsset = 'assets/campus.png';

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Campus')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // Pantalla simple: imagen a lo alto con zoom y desplazamiento vertical.
    return InteractiveViewer(
      minScale: 0.6,
      maxScale: 5.0,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            campusAsset,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => Container(
              padding: const EdgeInsets.all(16),
              alignment: Alignment.center,
              child: Text(
                'No se encontró el recurso:\n$campusAsset\n\nColoca el PNG en assets/ y vuelve a abrir.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
