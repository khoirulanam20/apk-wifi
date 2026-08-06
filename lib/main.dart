import 'dart:convert';
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

// Method channel untuk native Android features
const MethodChannel _nativeChannel = MethodChannel('com.bintangkecil.swf/native');

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
  bool _isRefreshing = false;
  bool _isAtTop = true;

  @override
  void initState() {
    super.initState();
    
    // Setup method channel listener untuk refresh dari native
    _nativeChannel.setMethodCallHandler((call) async {
      if (call.method == 'onRefresh' && mounted) {
        if (!_isAtTop) {
          await _nativeChannel.invokeMethod('refreshComplete');
          return;
        }
        setState(() {
          _isRefreshing = true;
          _progress = 0;
        });
        await _controller.reload();
      }
    });
    
    _navigationDelegate = NavigationDelegate(
      onProgress: (int value) {
        if (!mounted) return;
        // Hanya update setiap 10% untuk mengurangi rebuild
        final newProgress = value / 100.0;
        if ((newProgress - _progress).abs() > 0.1 || newProgress == 1.0) {
          setState(() => _progress = newProgress);
          // Hide refresh indicator when done
          if (newProgress == 1.0 && _isRefreshing) {
            setState(() => _isRefreshing = false);
            // Notify native that refresh is complete
            _nativeChannel.invokeMethod('refreshComplete');
          }
        }
      },
      onNavigationRequest: (request) async {
        if (_isDownloadUrl(request.url)) {
          await _startUrlDownload(request.url);
          return NavigationDecision.prevent;
        }
        return NavigationDecision.navigate;
      },
      onPageFinished: (_) {
        _injectScrollListener();
        _injectDownloadHandler();
        _injectShareHandler();
      },
    );
    
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(_navigationDelegate)
      ..addJavaScriptChannel('ScrollChannel', onMessageReceived: (message) {
        final isAtTop = message.message == '1';
        _reportScrollState(isAtTop);
      })
      ..addJavaScriptChannel('DownloadChannel', onMessageReceived: (message) {
        _handleDownloadMessage(message.message);
      })
      ..addJavaScriptChannel('ShareChannel', onMessageReceived: (message) {
        _handleShareMessage(message.message);
      })
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
      
      // Tunggu sampai frame benar-benar rendered
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // Delay tambahan untuk memastikan view hierarchy sudah stabil
        await Future.delayed(const Duration(milliseconds: 1000));
        
        // Enable pull-to-refresh via native channel
        try {
          debugPrint('Calling enablePullToRefresh...');
          final result = await _nativeChannel.invokeMethod('enablePullToRefresh');
          debugPrint('enablePullToRefresh result: $result');
        } catch (e) {
          debugPrint('Pull-to-refresh error: $e');
        }
      });
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

  Future<void> _reportScrollState(bool isAtTop) async {
    if (isAtTop == _isAtTop) return;
    _isAtTop = isAtTop;
    if (!Platform.isAndroid) return;
    await _nativeChannel.invokeMethod('updateScrollState', {'isAtTop': isAtTop});
  }

  bool _isDownloadUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme == 'blob') return true;

    final path = uri.path.toLowerCase();
    final query = uri.query.toLowerCase();

    if (path.endsWith('.pdf')) return true;
    if (uri.queryParameters.containsKey('download')) return true;
    if (query.contains('download=1') || query.contains('force_download')) {
      return true;
    }
    if (path.contains('/export') &&
        (path.contains('pdf') || uri.queryParameters['format'] == 'pdf')) {
      return true;
    }
    return false;
  }

  String _filenameFromUrl(String url, {String fallback = 'download.pdf'}) {
    final uri = Uri.tryParse(url);
    if (uri == null) return fallback;
    final segments = uri.pathSegments;
    if (segments.isNotEmpty) {
      final last = segments.last;
      if (last.isNotEmpty) return last;
    }
    return fallback;
  }

  void _showDownloadSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _startUrlDownload(String url, {String? filename}) async {
    if (!Platform.isAndroid) return;
    try {
      final name = filename ?? _filenameFromUrl(url);
      await _nativeChannel.invokeMethod('downloadUrl', {
        'url': url,
        'filename': name,
      });
      _showDownloadSnackBar('Mengunduh $name...');
    } catch (e, st) {
      debugPrint('Download error: $e\n$st');
      _showDownloadSnackBar('Gagal mengunduh file');
    }
  }

  Future<void> _saveBase64File(String base64, String filename) async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeChannel.invokeMethod('saveBase64File', {
        'data': base64,
        'filename': filename,
      });
      _showDownloadSnackBar('$filename tersimpan di Downloads');
    } catch (e, st) {
      debugPrint('Save error: $e\n$st');
      _showDownloadSnackBar('Gagal menyimpan file');
    }
  }

  void _handleDownloadMessage(String raw) {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final type = data['type'] as String?;
      if (type == 'url') {
        final url = data['url'] as String?;
        if (url == null || url.isEmpty) return;
        _startUrlDownload(url, filename: data['filename'] as String?);
      } else if (type == 'blob') {
        final payload = data['data'] as String?;
        if (payload == null || payload.isEmpty) return;
        final filename = (data['filename'] as String?) ?? 'download.pdf';
        _saveBase64File(payload, filename);
      }
    } catch (e, st) {
      debugPrint('Download message parse error: $e\n$st');
    }
  }

  Future<void> _sharePdfUrl(String url, {String? filename, String target = 'whatsapp'}) async {
    if (!Platform.isAndroid) return;
    try {
      final name = filename ?? _filenameFromUrl(url);
      _showDownloadSnackBar('Menyiapkan PDF untuk dibagikan...');
      await _nativeChannel.invokeMethod('sharePdfUrl', {
        'url': url,
        'filename': name,
        'target': target,
      });
    } catch (e, st) {
      debugPrint('Share error: $e\n$st');
      _showDownloadSnackBar('Gagal membagikan PDF');
    }
  }

  Future<void> _shareBase64Pdf(String base64, String filename, {String target = 'whatsapp'}) async {
    if (!Platform.isAndroid) return;
    try {
      _showDownloadSnackBar('Menyiapkan PDF untuk dibagikan...');
      await _nativeChannel.invokeMethod('shareBase64Pdf', {
        'data': base64,
        'filename': filename,
        'target': target,
      });
    } catch (e, st) {
      debugPrint('Share error: $e\n$st');
      _showDownloadSnackBar('Gagal membagikan PDF');
    }
  }

  void _handleShareMessage(String raw) {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final type = data['type'] as String?;
      final target = (data['target'] as String?) ?? 'whatsapp';
      if (type == 'url') {
        final url = data['url'] as String?;
        if (url == null || url.isEmpty) return;
        _sharePdfUrl(url, filename: data['filename'] as String?, target: target);
      } else if (type == 'blob') {
        final payload = data['data'] as String?;
        if (payload == null || payload.isEmpty) return;
        final filename = (data['filename'] as String?) ?? 'document.pdf';
        _shareBase64Pdf(payload, filename, target: target);
      }
    } catch (e, st) {
      debugPrint('Share message parse error: $e\n$st');
    }
  }

  Future<void> _injectScrollListener() async {
    await _controller.runJavaScript('''
(function() {
  if (window.__swfScrollListenerInstalled) return;
  window.__swfScrollListenerInstalled = true;

  function getScrollOffset() {
    var y = window.pageYOffset
      || document.documentElement.scrollTop
      || document.body.scrollTop
      || 0;
    if (y > 0) return y;

    var nodes = document.querySelectorAll(
      'html, body, main, [role="main"], [data-scroll], .overflow-auto, .overflow-y-auto, .overflow-scroll, .overflow-y-scroll'
    );
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].scrollTop > y) y = nodes[i].scrollTop;
    }
    return y;
  }

  function reportScroll() {
    var atTop = getScrollOffset() <= 0;
    ScrollChannel.postMessage(atTop ? '1' : '0');
  }

  reportScroll();
  document.addEventListener('scroll', reportScroll, { capture: true, passive: true });
  window.addEventListener('resize', reportScroll, { passive: true });
})();
''');
  }

  Future<void> _injectDownloadHandler() async {
    await _controller.runJavaScript(r'''
(function() {
  if (window.__swfDownloadHandlerInstalled) return;
  window.__swfDownloadHandlerInstalled = true;

  function filenameFromUrl(url, fallback) {
    try {
      var path = new URL(url, window.location.href).pathname;
      var parts = path.split('/').filter(Boolean);
      if (parts.length) return parts[parts.length - 1];
    } catch (e) {}
    return fallback || 'download.pdf';
  }

  function isDownloadLink(link) {
    if (!link || !link.href) return false;
    var href = link.href;
    if (link.download) return true;
    if (href.indexOf('blob:') === 0) return true;
    if (/\.pdf(\?|$)/i.test(href)) return true;
    if (/[?&]download(=|&|$)/i.test(href)) return true;
    if (/[?&]force_download/i.test(href)) return true;
    return false;
  }

  function postDownload(payload) {
    if (window.DownloadChannel) {
      DownloadChannel.postMessage(JSON.stringify(payload));
    }
  }

  function handleDownload(url, filename) {
    var name = filename || filenameFromUrl(url, 'download.pdf');
    if (url.indexOf('blob:') === 0) {
      fetch(url).then(function(r) { return r.blob(); }).then(function(blob) {
        var reader = new FileReader();
        reader.onloadend = function() {
          var result = reader.result || '';
          var base64 = String(result).split(',')[1] || '';
          postDownload({ type: 'blob', data: base64, filename: name });
        };
        reader.readAsDataURL(blob);
      }).catch(function(err) {
        console.error('SWF blob download failed', err);
      });
      return;
    }
    postDownload({ type: 'url', url: url, filename: name });
  }

  document.addEventListener('click', function(e) {
    var link = e.target && e.target.closest ? e.target.closest('a') : null;
    if (!isDownloadLink(link)) return;
    e.preventDefault();
    e.stopPropagation();
    handleDownload(link.href, link.download || filenameFromUrl(link.href, 'download.pdf'));
  }, true);

  var origClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function() {
    if (isDownloadLink(this)) {
      handleDownload(this.href, this.download || filenameFromUrl(this.href, 'download.pdf'));
      return;
    }
    return origClick.apply(this, arguments);
  };

  var origOpen = window.open;
  window.open = function(url, target, features) {
    if (url && (/\.pdf(\?|$)/i.test(url) || /[?&]download/i.test(url))) {
      handleDownload(url, filenameFromUrl(url, 'download.pdf'));
      return null;
    }
    return origOpen.apply(window, arguments);
  };
})();
''');
  }

  Future<void> _injectShareHandler() async {
    await _controller.runJavaScript(r'''
(function() {
  if (window.__swfShareHandlerInstalled) return;
  window.__swfShareHandlerInstalled = true;

  function filenameFromUrl(url, fallback) {
    try {
      var path = new URL(url, window.location.href).pathname;
      var parts = path.split('/').filter(Boolean);
      if (parts.length) return parts[parts.length - 1];
    } catch (e) {}
    return fallback || 'document.pdf';
  }

  function guessPdfUrlFromPage() {
    var path = window.location.pathname;
    var invoiceMatch = path.match(/\/tagihan\/(\d+)\/invoice/);
    if (invoiceMatch) {
      return window.location.origin + '/tagihan/' + invoiceMatch[1] + '/invoice/pdf';
    }
    var link = document.querySelector('a[href*=".pdf"], a[download][href], a[data-pdf-url]');
    if (link) {
      return link.dataset.pdfUrl || link.href;
    }
    return null;
  }

  function postShare(payload) {
    if (window.ShareChannel) {
      ShareChannel.postMessage(JSON.stringify(payload));
    }
  }

  function handleSharePdf(url, filename, target) {
    var name = filename || filenameFromUrl(url, 'document.pdf');
    if (url.indexOf('blob:') === 0) {
      fetch(url).then(function(r) { return r.blob(); }).then(function(blob) {
        var reader = new FileReader();
        reader.onloadend = function() {
          var result = reader.result || '';
          var base64 = String(result).split(',')[1] || '';
          postShare({ type: 'blob', data: base64, filename: name, target: target || 'whatsapp' });
        };
        reader.readAsDataURL(blob);
      });
      return;
    }
    postShare({ type: 'url', url: url, filename: name, target: target || 'whatsapp' });
  }

  window.SwfApp = window.SwfApp || {};
  window.SwfApp.sharePdf = function(url, filename) {
    handleSharePdf(url || guessPdfUrlFromPage(), filename, 'whatsapp');
  };

  function isShareElement(el) {
    if (!el) return false;
    var text = (el.textContent || '').toLowerCase().trim();
    var href = (el.href || '').toLowerCase();
    if (el.dataset && (el.dataset.sharePdf || el.dataset.share === 'pdf')) return true;
    if (/bagikan|share|whatsapp|kirim/i.test(text)) return true;
    if (/wa\.me|whatsapp\.com|api\.whatsapp/i.test(href)) return true;
    return false;
  }

  document.addEventListener('click', function(e) {
    var el = e.target && e.target.closest
      ? e.target.closest('button, a, [role="button"]')
      : null;
    if (!isShareElement(el)) return;

    var pdfUrl = (el.dataset && (el.dataset.pdfUrl || el.dataset.sharePdf))
      || el.getAttribute('data-pdf-url')
      || guessPdfUrlFromPage();
    if (!pdfUrl) return;

    e.preventDefault();
    e.stopPropagation();
    handleSharePdf(pdfUrl, el.dataset && el.dataset.filename, 'whatsapp');
  }, true);

  if (navigator.share) {
    var origShare = navigator.share.bind(navigator);
    navigator.share = function(data) {
      if (data && data.files && data.files.length) {
        var file = data.files[0];
        var reader = new FileReader();
        reader.onloadend = function() {
          var result = reader.result || '';
          var base64 = String(result).split(',')[1] || '';
          postShare({
            type: 'blob',
            data: base64,
            filename: file.name || 'document.pdf',
            target: 'whatsapp'
          });
        };
        reader.readAsDataURL(file);
        return Promise.resolve();
      }
      if (data && data.url && /\.pdf(\?|$)/i.test(data.url)) {
        handleSharePdf(data.url, null, 'whatsapp');
        return Promise.resolve();
      }
      return origShare(data);
    };
  }
})();
''');
  }

  Future<void> _handleRefresh() async {
    if (_isRefreshing) return;
    setState(() {
      _isRefreshing = true;
      _progress = 0;
    });
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
          title: GestureDetector(
            onDoubleTap: _handleRefresh,
            child: Container(
              height: 40,
              color: Colors.transparent,
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh, size: 22),
              color: const Color(0xFF0D9488),
              onPressed: _handleRefresh,
              padding: const EdgeInsets.all(8),
              tooltip: 'Refresh',
            ),
          ],
        ),
        body: Column(
          children: [
            if (_progress < 1.0 || _isRefreshing)
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
