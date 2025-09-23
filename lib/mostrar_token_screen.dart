import 'package:flutter/material.dart';
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
        title: const Text('Mostrar token'),
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : _error != null
                ? Text(_error!, style: const TextStyle(color: Colors.red))
                : _token != null
                    ? SelectableText('Token: $_token')
                    : const Text('Sin datos'),
      ),
    );
  }
}
