import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main.dart';
import 'moodle_token_service.dart';


class MostrarTokenScreen extends StatefulWidget {
  final String? cookie;
  const MostrarTokenScreen({super.key, this.cookie});

  @override
  State<MostrarTokenScreen> createState() => _MostrarTokenScreenState();
}

class _MostrarTokenScreenState extends State<MostrarTokenScreen> {
  String? _token;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _getToken();
  }

  Future<void> _getToken() async {
    setState(() => _loading = true);
    try {
      final token = await fetchMoodleMobileToken(widget.cookie ?? '');
      if (token != null) {
        setState(() {
          _token = token;
          _loading = false;
        });
        // Guardar el token globalmente para toda la app
        UserSession.accessToken = token;
      } else {
        setState(() {
          _error = 'No se pudo encontrar el token.';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error: ${e.toString()}';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Token de acceso'),
        centerTitle: true,
      ),
      body: Container(
        width: double.infinity,
        // Usar scaffoldBackgroundColor en lugar de colorScheme.background (lint preferente)
        color: theme.scaffoldBackgroundColor,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: _loading
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  CircularProgressIndicator(),
                  SizedBox(height: 24),
                  Text(
                    'Cargando token...',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center,
                  ),
                ],
              )
            : _error != null
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                  )
                : _token != null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: theme.cardColor,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: theme.brightness == Brightness.dark
                                      ? Colors.black.withValues(alpha: 0.25)
                                      : Colors.black.withValues(alpha: 0.04),
                                  blurRadius: theme.brightness == Brightness.dark ? 12 : 8,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Icon(Icons.vpn_key, size: 48, color: primary),
                                const SizedBox(height: 16),
                                Text(
                                  'Tu token de acceso',
                                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                SelectableText(
                                  '$_token',
                                  style: theme.textTheme.bodyLarge?.copyWith(fontFamily: 'monospace'),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 18),
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size.fromHeight(48),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  icon: const Icon(Icons.copy),
                                  label: const Text('Copiar token'),
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(text: _token!));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Token copiado al portapapeles')),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : const Text('Sin datos', style: TextStyle(fontSize: 16)),
      ),
    );
  }
}
