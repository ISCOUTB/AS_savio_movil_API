import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter/services.dart';

const MethodChannel sessionChannel = MethodChannel('app/session');

Future<void> clearCookiesNative() async {
  try {
    await sessionChannel.invokeMethod('clearCookies');
  } catch (_) {}
}

void main() {
  runApp(const SavioApp());
}

class SavioApp extends StatelessWidget {
  const SavioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const LoginWebViewPage(),
    );
  }
}

class UserSession {
  static String? accessToken;
  static void clear() => accessToken = null;
}

class LoginWebViewPage extends StatefulWidget {
  const LoginWebViewPage({super.key});

  @override
  State<LoginWebViewPage> createState() => _LoginWebViewPageState();
}

class _LoginWebViewPageState extends State<LoginWebViewPage> {
  final String startUrl = 'https://savio.utb.edu.co/';
  late final WebViewController _controller;
  bool _ready = false; // sesión lista
  bool _transitioning = false; // tapar WebView al pasar al menú
  bool _blockNav = false; // bloquear navegación post-login
  bool _checking = false;
  int _attempts = 0;
  static const int maxAttempts = 12;
  bool _coverSavio = true; // cubrir el WebView cuando es Savio
  bool _forcedMicrosoft = false; // ya intentamos forzar el login MS

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 SavioApp/1.0',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() {
              _ready = false;
              _coverSavio = !_isMicrosoftUrl(url);
            });
            // Forzar que window.open navegue en el mismo WebView (evitar pestañas nuevas)
            _controller.runJavaScript(
              "window.open = function(u){ try{ location.href = u; }catch(e){ } }",
            );
            _maybeForceMicrosoft(url);
          },
          onPageFinished: (url) {
            if (!_checking) _verifySession();
            _maybeForceMicrosoft(url);
          },
          onUrlChange: (change) {
            final url = change.url ?? '';
            if (url.isNotEmpty) {
              final cover = !_isMicrosoftUrl(url);
              if (cover != _coverSavio) {
                setState(() => _coverSavio = cover);
              }
            }
          },
          onWebResourceError: (error) {
            // print('Web error: ${error.errorCode} ${error.description}');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error de carga: ${error.errorCode}')),
            );
          },
          onNavigationRequest: (request) {
            if (_blockNav) return NavigationDecision.prevent;
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(startUrl));

    // Intento de limpieza de sesión por JS (opcional)
    // Nota: para una limpieza real de cookies fuera del contexto de la página
    // se requiere un plugin específico o reiniciar la app.
  }

  bool _isMicrosoftUrl(String? url) {
    if (url == null) return false;
    final u = url.toLowerCase();
    return u.contains('login.microsoftonline.com') ||
        u.contains('login.microsoft.com') ||
        u.contains('microsoft.com');
  }

  Future<void> _maybeForceMicrosoft(String? url) async {
    if (url == null) return;
    if (_isMicrosoftUrl(url)) {
      if (_coverSavio) setState(() => _coverSavio = false);
      return; // ya estamos en MS
    }
    // En Savio: intentar abrir proveedor Microsoft sin mostrar la página
    if (!_forcedMicrosoft && url.contains('savio.utb.edu.co')) {
      _forcedMicrosoft = true;
      try {
        const jsClickMicrosoft = r"""
          (function(){
            try{
              function clickIf(el){ if(!el) return false; el.click(); return true; }
              // Intentos directos por atributos
              var q = [
                "a[href*='login.microsoft']",
                "a[href*='microsoftonline']",
                "a[href*='oauth2']",
                "a[href*='saml']",
                "button[data-provider*='microsoft']",
                "[title*='Microsoft']"
              ];
              for (var i=0;i<q.length;i++){
                try{
                  var el = document.querySelector(q[i]);
                  if (el && clickIf(el)) return 'OPENED';
                }catch(_){/* selector inválido: continuar */}
              }
              // Búsqueda por texto visible
              var nodes = document.querySelectorAll('a,button,div,span');
              for (var j=0;j<nodes.length;j++){
                var n = nodes[j];
                var t = (n.textContent||'').toLowerCase();
                var h = (n.getAttribute && n.getAttribute('href')) ? n.getAttribute('href').toLowerCase() : '';
                if (t.includes('microsoft') || h.includes('microsoft')){
                  if (clickIf(n)) return 'OPENED';
                }
              }
              return 'NO';
            }catch(e){return 'NO';}
          })();
        """;
        final res = await _controller
            .runJavaScriptReturningResult(jsClickMicrosoft)
            .timeout(const Duration(seconds: 3));
        final opened = ('$res').contains('OPENED');
        if (!opened) {
          // Fallback: intentar ir a una ruta de login conocida
          try {
            final uri = Uri.parse(url);
            final base = '${uri.scheme}://${uri.host}';
            await _controller.loadRequest(Uri.parse('$base/login/index.php'));
          } catch (_) {}
        }
      } catch (_) {}
    }
  }

  Future<void> _verifySession() async {
    if (_checking || _ready) return;
    setState(() {
      _checking = true; // mostrar overlay de verificación
    });
    _attempts++;
    const js = """
      (function(){
        try{
          var u=document.querySelector('.userbutton .usertext');
          if(u&&u.textContent.trim().length>0){return 'OK';}
          var mailBtn=document.querySelector('.theme-loginform button.login-open');
          if(mailBtn&&/@/.test(mailBtn.textContent)) return 'OK';
          return 'NO';
        }catch(e){return 'NO';}
      })();
    """;
    Object? res;
    try {
      res = await _controller
          .runJavaScriptReturningResult(js)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      res = null; // tratar como NO
    }
    final ok = '$res'.contains('OK');
    if (ok) {
      setState(() {
        _ready = true;
        _transitioning = true; // ocultar cualquier contenido intermedio
        _blockNav = true; // impedir que el WebView siga navegando
      });
      try {
        await _controller.loadRequest(Uri.parse('about:blank'));
      } catch (_) {}
      UserSession.accessToken = 'webview-session';
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const MenuPage()));
    } else if (_attempts < maxAttempts) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) {
        setState(() {
          _checking = false;
        });
      }
      if (mounted) _verifySession();
    } else {
      // Si no se pudo verificar, simplemente deja el login visible (sin overlays ni botones extra)
      if (mounted) {
        setState(() {
          _checking = false;
          _coverSavio = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Iniciar sesión'),
        actions: [
          IconButton(
            tooltip: 'Recargar',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _controller.reload();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_transitioning || _checking || _coverSavio)
            Container(
              color: Colors.white,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          if (_transitioning || _checking || _coverSavio)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Text(
                    _transitioning
                        ? 'Iniciando sesión...'
                        : (_coverSavio
                              ? 'Redirigiendo a Microsoft...'
                              : 'Verificando sesión...'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: null,
    );
  }
}

class MenuPage extends StatelessWidget {
  const MenuPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Menú'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () => _showProfile(context),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _MenuCard(
              icon: Icons.calendar_today,
              title: 'Calendario inteligente',
              onTap: () =>
                  _toast(context, 'Abrir Calendario inteligente (pendiente)'),
            ),
            _MenuCard(
              icon: Icons.sticky_note_2,
              title: 'Apuntes rápidos',
              onTap: () => _toast(
                context,
                'Abrir Gestor de apuntes rápidos (pendiente)',
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showProfile(BuildContext context) async {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Sesión Microsoft activa',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () async {
                    await clearCookiesNative();
                    UserSession.clear();
                    if (context.mounted) {
                      Navigator.of(context).pop();
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(
                          builder: (_) => const LoginWebViewPage(),
                        ),
                        (route) => false,
                      );
                    }
                  },
                  child: const Text('Cerrar sesión'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MenuCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _MenuCard({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, size: 28),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
