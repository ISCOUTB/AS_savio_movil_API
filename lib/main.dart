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
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'moodle_token_service.dart';
import 'dart:convert';
import 'package:workmanager/workmanager.dart' as wm;
import 'dart:io' as io;
import 'package:flutter/foundation.dart';
// keep single dart:convert import
import 'actividades_calificaciones_page.dart';
import 'campus_page.dart';

const MethodChannel sessionChannel = MethodChannel('app/session');

Future<void> clearCookiesNative() async {
  try {
    await sessionChannel.invokeMethod('clearCookies');
  } catch (_) {}
}

// Development helper: allow invalid/self-signed certs for specific host when
// running in debug or when explicitly enabled via --dart-define=ALLOW_INVALID_CERTS=true
class _AllowInvalidCertHttpOverrides extends io.HttpOverrides {
  final bool allow;
  _AllowInvalidCertHttpOverrides({this.allow = false});

  @override
  io.HttpClient createHttpClient(io.SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (io.X509Certificate cert, String host, int port) => allow && host == 'savio.utb.edu.co';
    return client;
  }
}

class AppConfig {
  static bool allowInvalidCerts = false;
}

// Tema de la app (claro/oscuro) controlado globalmente
final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.system);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Activar override de certificados inválidos en modo debug o si se pasa
  // --dart-define=ALLOW_INVALID_CERTS=true al compilar/ejecutar.
  final allowInvalid = kDebugMode || (const String.fromEnvironment('ALLOW_INVALID_CERTS', defaultValue: 'false') == 'true');
  io.HttpOverrides.global = _AllowInvalidCertHttpOverrides(allow: allowInvalid);
  // Exponer flag a otras pantallas sin recalcular
  AppConfig.allowInvalidCerts = allowInvalid;
  await initializeDateFormatting('es');
  await NotificationService.init(onSelect: _onNotificationTap);
  await NotificationService.requestPermissionsIfNeeded();
  // Iniciar verificación de cambios en archivos (nuevo/actualizado/eliminado)
  FileChangeService.start();
  // Android: Workmanager para tareas periódicas en segundo plano
  if (io.Platform.isAndroid) {
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
  // Cargar preferencia de tema antes de dibujar
  try {
    final sp = await SharedPreferences.getInstance();
    final t = sp.getString('themeMode');
    if (t == 'dark') {
      appThemeMode.value = ThemeMode.dark;
    } else if (t == 'light') {
      appThemeMode.value = ThemeMode.light;
    } else {
      appThemeMode.value = ThemeMode.system;
    }
  } catch (_) {}

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
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          navigatorKey: appNavigatorKey,
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: _buildLightTheme(),
          darkTheme: _buildDarkTheme(),
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
      },
    );
  }
}

ThemeData _buildLightTheme() {
  const seed = Colors.indigo;
  final base = ThemeData(useMaterial3: true, colorSchemeSeed: seed);
  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFFF9F9FC),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: const Color(0xFFFDFDFE),
      elevation: 0,
      centerTitle: false,
      titleTextStyle: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: Colors.black,
      ),
    ),
    cardTheme: base.cardTheme.copyWith(
      elevation: 2,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    navigationBarTheme: base.navigationBarTheme.copyWith(
      backgroundColor: Colors.white,
    ),
  );
}

ThemeData _buildDarkTheme() {
  const seed = Colors.indigo;
  final base = ThemeData(useMaterial3: true, colorSchemeSeed: seed, brightness: Brightness.dark);
  final scheme = base.colorScheme;
  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFF121317),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: const Color(0xFF181A20),
      elevation: 0,
      titleTextStyle: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    ),
    cardTheme: base.cardTheme.copyWith(
      elevation: 4,
      surfaceTintColor: Colors.transparent,
      color: const Color(0xFF1F222A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dividerColor: Colors.grey.shade800,
    snackBarTheme: base.snackBarTheme.copyWith(
      backgroundColor: const Color(0xFF242832),
      contentTextStyle: const TextStyle(color: Colors.white),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: Colors.grey[200],
      displayColor: Colors.grey[100],
    ),
    // Evitar establecer background explícito si no es necesario; surface/onSurface son suficientes
    colorScheme: scheme.copyWith(
      surface: const Color(0xFF1F222A),
      onSurface: Colors.grey[200],
    ),
  );
}

class UserSession {
  static String? accessToken;
  static String? moodleCookie;
  static String? displayName; // nombre completo del usuario
  static void clear() {
    accessToken = null;
    moodleCookie = null;
    displayName = null;
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

  // Clave para abrir el Drawer desde el logo, sin mostrar el ícono hamburguesa
  static final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {


    final menuItems = [
      // 1. Actividades (PRIORIDAD: primero en el grid)
      _MenuGridItem(
        color: Colors.green.shade300,
        icon: Icons.event_note, // Icono más reconocible para actividades
        iconColor: Colors.green.shade700, // Contraste: antes blanco sobre fondo blanco se veía vacío
        title: 'Actividades',
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const ActividadesCalificacionesPage(),
            ),
          );
        },
      ),
      // 2. Acceso principal a SAVIO/Moodle
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
      // 3. Calendario inteligente
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
      // 4. Mostrar token
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
      // 5. CalcuNota
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
      // 6. Campus (mapa + leyenda)
      _MenuGridItem(
        color: Colors.lightBlue.shade100,
        icon: Icons.map,
        iconColor: Colors.lightBlue.shade700,
        title: 'Campus',
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const CampusPage(),
            ),
          );
        },
      ),
    ];

    return Scaffold(
      key: MenuPage._scaffoldKey,
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              DrawerHeader(
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF1F222A)
                      : Colors.indigo.shade50,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ClipOval(
                      child: Image.asset(
                        'assets/images.png',
                        height: 56,
                        width: 56,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Text(
                        'Menú rápido',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              // Modo oscuro: interruptor
              ValueListenableBuilder<ThemeMode>(
                valueListenable: appThemeMode,
                builder: (context, mode, _) {
                  final isDark = mode == ThemeMode.dark;
                  return SwitchListTile.adaptive(
                    secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
                    title: const Text('Modo oscuro'),
                    value: isDark,
                    onChanged: (v) async {
                      appThemeMode.value = v ? ThemeMode.dark : ThemeMode.light;
                      try {
                        final sp = await SharedPreferences.getInstance();
                        await sp.setString('themeMode', v ? 'dark' : 'light');
                      } catch (_) {}
                    },
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.list_alt),
                title: const Text('Actividades'),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ActividadesCalificacionesPage(),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.school),
                title: const Text('SAVIO / Moodle'),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SavioWebViewPage(),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.event_available),
                title: const Text('Calendario'),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CalendarioPage(),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.vpn_key),
                title: const Text('Mostrar token'),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MostrarTokenScreen(cookie: UserSession.moodleCookie),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.calculate),
                title: const Text('CalcuNota'),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CalcuNotaWebViewPage(),
                    ),
                  );
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text('Cerrar sesión'),
                onTap: () async {
                  Navigator.of(context).pop();
                  final nav = Navigator.of(context);
                  await clearCookiesNative();
                  UserSession.clear();
                  nav.pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const LoginWebViewPage()),
                    (r) => false,
                  );
                },
              ),
            ],
          ),
        ),
      ),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => _openQuickMenu(context),
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: (Theme.of(context).brightness == Brightness.dark
                              ? Colors.black.withValues(alpha: 0.25)
                              : Colors.black.withValues(alpha: 0.08)),
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
            ),
            const SizedBox(width: 12),
            const Text('Menú'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Actividades',
            icon: const Icon(Icons.list_alt),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ActividadesCalificacionesPage(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () => _showProfile(context),
          ),
        ],
      ),
      body: Container(
        // Usa el color del tema (claro/oscuro) en vez de forzar gris claro
        // Preferir scaffoldBackgroundColor/surface en lugar de colorScheme.background
        color: Theme.of(context).scaffoldBackgroundColor,
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
        // Se removió el botón flotante de acceso rápido a Actividades por petición.
      );
    }
  }

  // Abrir el panel lateral (Drawer) desde el logo
  void _openQuickMenu(BuildContext context) {
    MenuPage._scaffoldKey.currentState?.openDrawer();
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Evitar acceso directo a canales de color; usar Color.lerp para oscurecer
    Color darken(Color c, double t) => Color.lerp(c, Colors.black, t) ?? c;
    final Color tileColor = isDark ? darken(color, 0.35) : color;
    final Color circleBg = isDark ? const Color(0xFF2A2E37) : Colors.white;
    final onSurface = theme.colorScheme.onSurface;
    final isSavio = title.trim().toLowerCase().contains('savio');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: tileColor,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black.withValues(alpha: 0.25) : Colors.black.withValues(alpha: 0.06),
                blurRadius: isDark ? 12 : 8,
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
                        shape: BoxShape.circle,
                        gradient: isDark
                            ? const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFF3E2E6F), Color(0xFF5B3FA8)],
                              )
                            : const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFF673AB7), Color(0xFF7E57C2)],
                              ),
                        boxShadow: [
                          BoxShadow(
                            color: isDark ? Colors.black.withValues(alpha: 0.30) : Colors.black.withValues(alpha: 0.10),
                            blurRadius: isDark ? 16 : 12,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: (isDark ? const Color(0xFF5B3FA8) : const Color(0xFF7E57C2)).withValues(alpha: 0.35),
                            blurRadius: isDark ? 26 : 22,
                            spreadRadius: -6,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(18),
                      child: const Icon(Icons.school, size: 40, color: Colors.white),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: circleBg,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: isDark ? Colors.black.withValues(alpha: 0.3) : Colors.black.withValues(alpha: 0.06),
                            blurRadius: isDark ? 12 : 8,
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
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: onSurface,
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

// Obtiene el nombre visible del usuario desde una llamada ligera si se dispone de cookie Moodle.
Future<String?> _fetchDisplayName() async {
  // Si ya lo tenemos cacheado
  if (UserSession.displayName != null && UserSession.displayName!.isNotEmpty) {
    return UserSession.displayName;
  }
  final cookie = UserSession.moodleCookie;
  if (cookie == null || cookie.isEmpty) return null;
  // Obtener token Moodle (mobile) usando el cookie
  try {
    final token = await fetchMoodleMobileToken(cookie);
    if (token == null || token.isEmpty) return null;
    // Llamar core_webservice_get_site_info para fullname
    final base = 'https://savio.utb.edu.co/webservice/rest/server.php';
    final url = '$base?wstoken=$token&wsfunction=core_webservice_get_site_info&moodlewsrestformat=json';
    http.Client client;
    if (AppConfig.allowInvalidCerts) {
      final raw = io.HttpClient()
        ..badCertificateCallback = (cert, host, port) => host == 'savio.utb.edu.co';
      client = IOClient(raw);
    } else {
      client = http.Client();
    }
    final r = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final data = json.decode(r.body);
    if (data is Map && data['fullname'] is String) {
      final name = (data['fullname'] as String).trim();
      if (name.isNotEmpty) {
        UserSession.displayName = name;
        return name;
      }
    }
    return null;
  } catch (_) {
    return null;
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
                final theme = Theme.of(context);
                final isDark = theme.brightness == Brightness.dark;
                final onSurface70 = theme.colorScheme.onSurface.withValues(alpha: 0.7);
                return Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: [
                  BoxShadow(
                    color: isDark ? Colors.black.withValues(alpha: 0.35) : Colors.black.withValues(alpha: 0.12),
                    blurRadius: 16,
                    offset: const Offset(0, -4),
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
                        color: theme.dividerColor.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Center(
                        child: Container(
                          decoration: BoxDecoration(
                            color: isDark
                                ? theme.colorScheme.primary.withValues(alpha: 0.15)
                                : Colors.indigo.shade50,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(6),
                          child: CircleAvatar(
                            radius: 28,
                            backgroundColor: theme.colorScheme.surface,
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
                      ),
                      const SizedBox(height: 10),
                      // Nombre centrado y en dos líneas para permitir nombres largos completos
                      FutureBuilder<String?>(
                        future: _fetchDisplayName(),
                        builder: (context, snapName) {
                          final name = snapName.data;
                          if (name == null || name.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Text(
                            name,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.fade,
                            style: theme.textTheme.titleMedium?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
                          );
                        },
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.verified_user, size: 16, color: Colors.green),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Sesión Microsoft activa',
                              style: TextStyle(color: onSurface70),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Divider(height: 1, color: theme.dividerColor),
                  const SizedBox(height: 8),
                  // Acciones rápidas
                  if (!notifAllowed)
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      color: theme.cardColor,
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


