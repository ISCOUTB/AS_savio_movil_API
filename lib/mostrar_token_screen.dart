import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'moodle_token_service.dart';


class MostrarTokenScreen extends StatefulWidget {
  final String? cookie;
  const MostrarTokenScreen({Key? key, this.cookie}) : super(key: key);

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
      } else {
        setState(() {
          _error = 'No se pudo encontrar el token.';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error: ' + e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Token de acceso'),
        centerTitle: true,
        backgroundColor: Colors.deepPurple,
      ),
      body: Container(
        width: double.infinity,
        color: Colors.grey[100],
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
                      color: Colors.red[50],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red, fontSize: 16),
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
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.04),
                                  blurRadius: 8,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                const Icon(Icons.vpn_key, size: 48, color: Colors.deepPurple),
                                const SizedBox(height: 16),
                                const Text(
                                  'Tu token de acceso',
                                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                SelectableText(
                                  '$_token',
                                  style: const TextStyle(fontSize: 18, color: Colors.black87, fontFamily: 'monospace'),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 18),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.deepPurple,
                                    minimumSize: const Size.fromHeight(48),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  icon: const Icon(Icons.copy, color: Colors.white),
                                  label: const Text(
                                    'Copiar token',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
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
