import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// URL aplikasi web SWF.
const String kAppUrl = 'https://protika.desaverse.id/login';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SwfWebApp());
}

class SwfWebApp extends StatelessWidget {
  const SwfWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SWF',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0D9488)),
        useMaterial3: true,
      ),
      home: const WebShell(),
    );
  }
}

class WebShell extends StatefulWidget {
  const WebShell({super.key});

  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  late final WebViewController _controller;
  late final NavigationDelegate _navigationDelegate;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _navigationDelegate = NavigationDelegate(
      onProgress: (int value) {
        if (!mounted) return;
        // Hanya update setiap 10% untuk mengurangi rebuild
        final newProgress = value / 100.0;
        if ((newProgress - _progress).abs() > 0.1 || newProgress == 1.0) {
          setState(() => _progress = newProgress);
        }
      },
    );
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(_navigationDelegate)
      ..loadRequest(Uri.parse(kAppUrl));

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _setupAndroidExtras();
    });
  }

  Future<void> _setupAndroidExtras() async {
    if (!Platform.isAndroid) return;
    await _requestNotificationPermission();
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      await platform.setOnShowFileSelector(_androidFileSelector);
      // Optimasi WebView Android
      await platform.setMediaPlaybackRequiresUserGesture(false);
      await platform.setGeolocationPermissionsPromptCallbacks(
        onShowPrompt: (request) async {
          return GeolocationPermissionsResponse(
            allow: true,
            retain: true,
          );
        },
      );
    }
  }

  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    final status = await Permission.notification.status;
    if (status.isGranted || status.isPermanentlyDenied) return;
    await Permission.notification.request();
  }

  FileType _fileTypeFromAcceptTypes(List<String> acceptTypes) {
    if (acceptTypes.isEmpty) return FileType.any;
    final joined = acceptTypes.join(',').toLowerCase();
    if (joined.contains('image')) return FileType.image;
    if (joined.contains('video')) return FileType.video;
    if (joined.contains('audio')) return FileType.audio;
    return FileType.any;
  }

  Future<bool> _ensureCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  Future<void> _ensureMediaPermissions(FileType type) async {
    if (!Platform.isAndroid) return;
    switch (type) {
      case FileType.video:
        await Permission.videos.request();
        break;
      case FileType.image:
        await Permission.photos.request();
        break;
      case FileType.any:
        await Permission.photos.request();
        await Permission.videos.request();
        break;
      default:
        break;
    }
  }

  Future<List<String>> _androidFileSelector(FileSelectorParams params) async {
    try {
      if (params.isCaptureEnabled) {
        if (!await _ensureCameraPermission()) return [];
        final photo = await ImagePicker().pickImage(source: ImageSource.camera);
        if (photo == null) return [];
        return [Uri.file(photo.path).toString()];
      }

      final multiple = params.mode == FileSelectorMode.openMultiple;
      final type = _fileTypeFromAcceptTypes(params.acceptTypes);
      await _ensureMediaPermissions(type);

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: multiple,
        type: type,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return [];

      return result.files
          .map((f) => f.path)
          .whereType<String>()
          .where((p) => p.isNotEmpty)
          .map((p) => Uri.file(p).toString())
          .toList(growable: false);
    } catch (e, st) {
      debugPrint('File selector: $e\n$st');
      return [];
    }
  }

  Future<void> _onPopInvoked(bool didPop, Object? result) async {
    if (didPop) return;
    if (await _controller.canGoBack()) {
      await _controller.goBack();
    } else {
      SystemNavigator.pop();
    }
  }

  Future<void> _handleRefresh() async {
    setState(() => _progress = 0);
    await _controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 40,
          backgroundColor: Colors.white,
          elevation: 2,
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh, size: 22),
              color: const Color(0xFF0D9488),
              onPressed: _handleRefresh,
              padding: const EdgeInsets.all(8),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_progress < 1.0)
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 3,
                backgroundColor: Colors.grey[200],
                color: const Color(0xFF0D9488),
              ),
            Expanded(
              child: WebViewWidget(controller: _controller),
            ),
          ],
        ),
      ),
    );
  }
}
