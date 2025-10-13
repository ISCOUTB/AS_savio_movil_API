import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter/services.dart';
import 'mostrar_token_screen.dart';
import 'savio_webview_page.dart';
import 'calcu_nota_webview_page.dart';
import 'calendario_page.dart';
import 'notification_service.dart';
import 'file_change_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart' as wm;
import 'dart:io' show Platform;
import 'dart:convert';

const MethodChannel sessionChannel = MethodChannel('app/session');

Future<void> clearCookiesNative() async {
  try {
    await sessionChannel.invokeMethod('clearCookies');
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  await NotificationService.init(onSelect: _onNotificationTap);
  await NotificationService.requestPermissionsIfNeeded();
  // Iniciar verificación de cambios en archivos (nuevo/actualizado/eliminado)
  FileChangeService.start();
  // Android: Workmanager para tareas periódicas en segundo plano
  if (Platform.isAndroid) {
    await wm.Workmanager().initialize(
      _backgroundDispatcher,
      // isInDebugMode is deprecated; remove it and rely on default behavior
    );
    // Programar tarea periódica cada 15 min (mínimo en Android)
    await wm.Workmanager().registerPeriodicTask(
      FileChangeService.taskName,
      FileChangeService.taskName,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: wm.ExistingPeriodicWorkPolicy.keep,
      constraints: wm.Constraints(
        networkType: wm.NetworkType.connected,
      ),
      backoffPolicy: wm.BackoffPolicy.linear,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
  }

  // iOS: sin tareas periódicas por restricciones; se puede considerar Push Notifications en el futuro.
  runApp(const SavioApp());
  // Si la app se abrió por tocar una notificación, procesar el deep link
  final launchPayload = await NotificationService.getLaunchPayload();
  if (launchPayload != null && launchPayload.isNotEmpty) {
    _onNotificationTap(launchPayload);
  }
}

@pragma('vm:entry-point')
void _backgroundDispatcher() {
  wm.Workmanager().executeTask((task, inputData) async {
    // Requiere inicializar plugins dentro del isolate
    WidgetsFlutterBinding.ensureInitialized();
    await NotificationService.init();

    try {
      // Restaurar cookie/token si están en SharedPreferences
      final sp = await SharedPreferences.getInstance();
      UserSession.moodleCookie = sp.getString('moodleCookie');
      UserSession.accessToken = sp.getString('accessToken');
    } catch (_) {}

    try {
      // Ejecutar una comprobación
      await FileChangeService.checkNow();
    } catch (_) {}
    // Devolver true para indicar éxito
    return Future.value(true);
  });
}

class SavioApp extends StatelessWidget {
  const SavioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('es'),
        Locale('en'),
      ],
      home: const LoginWebViewPage(),
    );
  }
}

class UserSession {
  static String? accessToken;
  static String? moodleCookie;
  static void clear() {
    accessToken = null;
    moodleCookie = null;
  }
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
      // Obtener cookies de sesión de Moodle desde el WebView
      String? cookie;
      try {
        final jsCookie = "document.cookie";
        final cookies = await _controller.runJavaScriptReturningResult(jsCookie);
        if (cookies is String) {
          // Buscar la cookie de sesión de Moodle (ej: MoodleSession...)
          final reg = RegExp(r'(MoodleSession[^=]*)=([^;]*)');
          final match = reg.firstMatch(cookies);
          if (match != null) {
            cookie = '${match.group(1)}=${match.group(2)}';
          }
        }
      } catch (_) {}
      UserSession.moodleCookie = cookie;
      // Persistir para background
      try {
        final sp = await SharedPreferences.getInstance();
        if (cookie != null) await sp.setString('moodleCookie', cookie);
      } catch (_) {}
      setState(() {
        _ready = true;
        _transitioning = true; // ocultar cualquier contenido intermedio
        _blockNav = true; // impedir que el WebView siga navegando
      });
      try {
        await _controller.loadRequest(Uri.parse('about:blank'));
      } catch (_) {}
      UserSession.accessToken = 'webview-session';
      try {
        final sp = await SharedPreferences.getInstance();
        await sp.setString('accessToken', UserSession.accessToken!);
      } catch (_) {}
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
          GestureDetector(
            onLongPress: () async {
              // Disparar comprobación manual de archivos para pruebas
              await FileChangeService.checkNow();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Comprobación de materiales realizada')),
              );
            },
            child: IconButton(
              tooltip: 'Recargar',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _controller.reload();
              },
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_transitioning || _checking || _coverSavio)
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFF7F7FF), Colors.white],
                ),
              ),
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final maxW = constraints.maxWidth;
                    final logoW = (maxW * 0.55).clamp(160.0, 260.0);
                    final message = _transitioning
                        ? 'Iniciando sesión...'
                        : (_coverSavio ? 'Cargando aplicación...' : 'Verificando sesión...');
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Logo SAVIO proporcionado y centrado
                              Image.asset(
                                'assets/savioof.png',
                                width: logoW,
                                fit: BoxFit.contain,
                                semanticLabel: 'SAVIO',
                              ),
                              const SizedBox(height: 22),
                              const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.6,
                                ),
                              ),
                              const SizedBox(height: 16),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                child: Text(
                                  message,
                                  key: ValueKey<String>(message),
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Por favor espera unos segundos',
                                style: TextStyle(color: Colors.black54),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
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


    final menuItems = [
      _MenuGridItem(
        color: Colors.deepPurple.shade200,
        icon: Icons.school,
        iconColor: Colors.white,
        title: 'SAVIO/Moodle',
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const SavioWebViewPage(),
            ),
          );
        },
      ),
      _MenuGridItem(
        color: Colors.deepPurple.shade100,
        icon: Icons.event_available,
        iconColor: Colors.deepPurple,
        title: 'Calendario inteligente',
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const CalendarioPage(),
            ),
          );
        },
      ),
      _MenuGridItem(
        color: Colors.teal.shade100,
        icon: Icons.vpn_key,
        iconColor: Colors.teal.shade700,
        title: 'Mostrar token',
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => MostrarTokenScreen(cookie: UserSession.moodleCookie),
            ),
          );
        },
      ),
      _MenuGridItem(
        color: Colors.pink.shade100,
        icon: Icons.calculate,
        iconColor: Colors.pink.shade700,
        title: 'CalcuNota',
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const CalcuNotaWebViewPage(),
            ),
          );
        },
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(4),
              child: ClipOval(
                child: Image.asset(
                  'assets/images.png',
                  height: 32,
                  width: 32,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Text('Menú'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () => _showProfile(context),
          ),
        ],
      ),
      body: Container(
  color: Colors.grey[50],
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Ajustar el aspect ratio según el alto disponible
            final isSmall = constraints.maxHeight < 650;
            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: isSmall ? 0.95 : 0.98,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: menuItems,
                ),
              ),
            );
          },
        ),
      ),
        floatingActionButton: null,
      );
    }
  }
  
class _MenuGridItem extends StatelessWidget {
  final Color color;
  final IconData icon;
  final Color iconColor;
  final String title;
  final VoidCallback onTap;

  const _MenuGridItem({
    required this.color,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSavio = title.trim().toLowerCase().contains('savio');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              isSavio
                  ? Container(
                      decoration: BoxDecoration(
                        color: Colors.deepPurple,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(18),
                      child: Icon(Icons.school, size: 40, color: Colors.white),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(14),
                      child: Icon(icon, size: 36, color: iconColor),
                    ),
              const SizedBox(height: 12),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Global navigator key to allow navigation from notification taps even when no context is at hand
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

// Handle notification payloads to deep-link into Savio/Moodle
void _onNotificationTap(String payload) {
  try {
    final data = json.decode(payload);
    if (data is Map) {
      final String? url = data['url'] as String?;
      final String? title = data['title'] as String?;
      if (url != null && url.isNotEmpty) {
        final nav = appNavigatorKey.currentState;
        if (nav != null) {
          nav.push(
            MaterialPageRoute(
              builder: (_) => SavioWebViewPage(
                initialUrl: url,
                title: title ?? 'SAVIO/Moodle',
              ),
            ),
          );
        }
      }
    }
  } catch (_) {
    // ignore malformed payloads
  }
}

  void _showProfile(BuildContext context) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.45,
          minChildSize: 0.25,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return FutureBuilder<bool>(
              future: NotificationService.areNotificationsAllowed(),
              builder: (context, snap) {
                final notifAllowed = snap.data == true;
                return Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 16,
                    offset: Offset(0, -4),
                  ),
                ],
              ),
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                children: [
                  Center(
                    child: Container(
                      width: 48,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.indigo.shade50,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(6),
                        child: CircleAvatar(
                          radius: 28,
                          backgroundColor: Colors.white,
                          child: ClipOval(
                            child: Image.asset(
                              'assets/images.png',
                              width: 48,
                              height: 48,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Tu sesión',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                            ),
                            Row(
                              children: const [
                                Icon(Icons.verified_user, size: 16, color: Colors.green),
                                SizedBox(width: 6),
                                Text('Sesión Microsoft activa', style: TextStyle(color: Colors.black54)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Divider(height: 1, color: Colors.grey[200]),
                  const SizedBox(height: 8),
                  // Acciones rápidas
                  if (!notifAllowed)
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      color: Colors.grey[50],
                      child: Column(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.notifications_active, color: Colors.deepPurple),
                            title: const Text('Notificaciones'),
                            subtitle: const Text('Permite las notificaciones para recibir alertas'),
                            trailing: OutlinedButton(
                              onPressed: () async {
                                // En muchos dispositivos, si el usuario negó, debemos abrir configuración
                                await NotificationService.requestPermissionsIfNeeded();
                                final allowed = await NotificationService.areNotificationsAllowed();
                                if (!allowed) {
                                  await NotificationService.openAppSettingsPage();
                                }
                              },
                              child: const Text('Configurar'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  // Botón principal: Cerrar sesión
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: const Icon(Icons.logout),
                    label: const Text('Cerrar sesión', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    onPressed: () async {
                      final ok = await _confirmLogout(context);
                      if (ok != true) return;
                      await clearCookiesNative();
                      UserSession.clear();
                      try {
                        final sp = await SharedPreferences.getInstance();
                        await sp.remove('moodleCookie');
                        await sp.remove('accessToken');
                      } catch (_) {}
                      if (context.mounted) {
                        Navigator.of(context).pop();
                        Navigator.of(context).pushAndRemoveUntil(
                          MaterialPageRoute(builder: (_) => const LoginWebViewPage()),
                          (route) => false,
                        );
                      }
                    },
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancelar'),
                  ),
                ],
              ),
            );
              },
            );
          },
        );
      },
    );
  }

  Future<bool?> _confirmLogout(BuildContext context) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Cerrar sesión'),
          content: const Text('¿Seguro que quieres cerrar tu sesión y volver a iniciar?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Cerrar sesión'),
            ),
          ],
        );
      },
    );
  }


