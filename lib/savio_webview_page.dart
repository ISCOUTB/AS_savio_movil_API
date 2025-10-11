import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class SavioWebViewPage extends StatefulWidget {
  final String? initialUrl;
  final String? title;

  const SavioWebViewPage({super.key, this.initialUrl, this.title});

  @override
  State<SavioWebViewPage> createState() => _SavioWebViewPageState();
}

class _SavioWebViewPageState extends State<SavioWebViewPage> {
  late final WebViewController _controller;
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _updateNav(),
          onPageStarted: (_) => _updateNav(),
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl ?? 'https://savio.utb.edu.co/my'));
  }

  Future<void> _updateNav() async {
    final canBack = await _controller.canGoBack();
    final canForward = await _controller.canGoForward();
    if (mounted) {
      setState(() {
        _canGoBack = canBack;
        _canGoForward = canForward;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'SAVIO/Moodle'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.arrow_back_ios, color: _canGoBack ? null : Colors.grey),
            tooltip: 'Atrás',
            onPressed: _canGoBack ? () async {
              await _controller.goBack();
              _updateNav();
            } : null,
          ),
          IconButton(
            icon: Icon(Icons.arrow_forward_ios, color: _canGoForward ? null : Colors.grey),
            tooltip: 'Adelante',
            onPressed: _canGoForward ? () async {
              await _controller.goForward();
              _updateNav();
            } : null,
          ),
        ],
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
