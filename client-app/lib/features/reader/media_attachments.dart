// Conversation media attachments: inline previews, audio/video playback,
// text/file preview and download for files referenced in chat turns.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme.dart';
import '../../protocol/messages.dart';

/// Resolve a host-relative media URL (`/api/media?path=...`) to an absolute URL
/// carrying the host token.
String resolveHostMediaUrl(
  String raw, {
  required String hostHttpBase,
  required String hostToken,
  bool download = false,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  Uri? uri = Uri.tryParse(trimmed);
  if (uri == null) return '';
  if (!uri.hasScheme) {
    if (hostHttpBase.isEmpty) return '';
    final base = Uri.tryParse(hostHttpBase);
    if (base == null) return '';
    uri = base.resolveUri(uri);
  }
  final qp = Map<String, String>.from(uri.queryParameters);
  final token = hostToken.trim();
  if (token.isNotEmpty && !qp.containsKey('token')) qp['token'] = token;
  if (download) qp['download'] = '1';
  return uri.replace(queryParameters: qp).toString();
}

String formatFileSize(int bytes) {
  if (bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

bool get _inlinePlaybackSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

const _textPreviewExts = {
  'txt', 'md', 'markdown', 'log', 'json', 'jsonl', 'csv', 'tsv', 'yaml', 'yml',
  'toml', 'ini', 'xml', 'html', 'htm', 'py', 'dart', 'js', 'ts', 'tsx', 'jsx',
  'kt', 'swift', 'java', 'c', 'h', 'cpp', 'rs', 'go', 'sh', 'sql', 'srt', 'vtt',
};

String _extOf(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

bool _isTextPreviewable(MediaAttachment a) =>
    a.mime.startsWith('text/') ||
    a.mime == 'application/json' ||
    _textPreviewExts.contains(_extOf(a.displayName));

IconData _fileIcon(MediaAttachment a) {
  final ext = _extOf(a.displayName);
  if (a.isAudio) return Icons.graphic_eq_rounded;
  if (a.isVideo) return Icons.movie_rounded;
  if (a.isImage) return Icons.image_rounded;
  if (ext == 'pdf') return Icons.picture_as_pdf_rounded;
  if ({'zip', 'tar', 'gz', 'tgz', '7z', 'rar'}.contains(ext)) {
    return Icons.folder_zip_rounded;
  }
  if ({'apk', 'ipa'}.contains(ext)) return Icons.install_mobile_rounded;
  if (_isTextPreviewable(a)) return Icons.description_rounded;
  return Icons.insert_drive_file_rounded;
}

/// Renders every non-image attachment of a turn (images are handled by the
/// existing gallery) plus image attachments not already present in `images`.
class MediaAttachmentList extends StatelessWidget {
  const MediaAttachmentList({
    super.key,
    required this.attachments,
    required this.hostHttpBase,
    required this.hostToken,
    this.knownImageUrls = const [],
    required this.onOpenImage,
  });

  final List<MediaAttachment> attachments;
  final String hostHttpBase;
  final String hostToken;
  final List<String> knownImageUrls;
  final void Function(String resolvedUrl) onOpenImage;

  String _resolve(String raw, {bool download = false}) => resolveHostMediaUrl(
        raw,
        hostHttpBase: hostHttpBase,
        hostToken: hostToken,
        download: download,
      );

  @override
  Widget build(BuildContext context) {
    final p = VibeTheme.paletteOf(context);
    final known = knownImageUrls.toSet();
    final images =
        attachments.where((a) => a.isImage && !known.contains(a.url)).toList();
    final others = attachments.where((a) => !a.isImage).toList();
    if (images.isEmpty && others.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: images.map((a) {
                  final url = _resolve(a.url);
                  return GestureDetector(
                    onTap: () => onOpenImage(url),
                    onLongPress: () => _showAttachmentActions(context, a),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 148,
                        height: 110,
                        color: p.panelAlt,
                        child: Image.network(
                          url,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Center(
                            child: Icon(Icons.broken_image_outlined,
                                color: p.muted),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          for (final a in others)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: a.isAudio
                  ? _AudioAttachmentCard(
                      attachment: a,
                      url: _resolve(a.url),
                      onMore: () => _showAttachmentActions(context, a),
                    )
                  : _FileAttachmentCard(
                      attachment: a,
                      onTap: () => _openAttachment(context, a),
                      onDownload: () => _download(context, a, openAfter: true),
                    ),
            ),
        ],
      ),
    );
  }

  Future<void> _openAttachment(BuildContext context, MediaAttachment a) async {
    final url = _resolve(a.url);
    if (a.isVideo) {
      if (_inlinePlaybackSupported) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MediaPlayerPage(
              url: url,
              title: a.displayName,
              isAudio: false,
              onDownload: (ctx) => _download(ctx, a, openAfter: true),
            ),
          ),
        );
      } else {
        await _launchExternal(context, url);
      }
      return;
    }
    if (_isTextPreviewable(a)) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TextFilePreviewPage(
            url: url,
            attachment: a,
            onDownload: (ctx) => _download(ctx, a, openAfter: true),
          ),
        ),
      );
      return;
    }
    // PDF / Office / archives: download then hand to the system viewer.
    await _download(context, a, openAfter: true);
  }

  void _showAttachmentActions(BuildContext context, MediaAttachment a) {
    final p = VibeTheme.paletteOf(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.panel,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(a.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
              subtitle: Text(a.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.muted, fontSize: 11)),
            ),
            ListTile(
              leading: Icon(Icons.download_rounded, color: p.accent),
              title: Text('下载到手机并打开', style: TextStyle(color: p.text)),
              onTap: () {
                Navigator.of(ctx).pop();
                _download(context, a, openAfter: true);
              },
            ),
            ListTile(
              leading: Icon(Icons.open_in_browser_rounded, color: p.accent),
              title: Text('在浏览器中打开', style: TextStyle(color: p.text)),
              onTap: () {
                Navigator.of(ctx).pop();
                _launchExternal(context, _resolve(a.url));
              },
            ),
            ListTile(
              leading: Icon(Icons.copy_rounded, color: p.accent),
              title: Text('复制宿主机路径', style: TextStyle(color: p.text)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: a.path));
                Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _download(
    BuildContext context,
    MediaAttachment a, {
    bool openAfter = false,
  }) =>
      downloadAndSaveMediaUrl(
        context,
        _resolve(a.url, download: true),
        fileName: a.displayName,
        openAfter: openAfter,
      );
}

String _inferMediaFileName(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null) {
    final pathParam = uri.queryParameters['path'] ?? '';
    if (pathParam.isNotEmpty) {
      final seg = pathParam.split(RegExp(r'[\\/]')).lastWhere(
            (s) => s.isNotEmpty,
            orElse: () => '',
          );
      if (seg.isNotEmpty) return seg;
    }
    if (uri.pathSegments.isNotEmpty && uri.pathSegments.last.isNotEmpty) {
      return uri.pathSegments.last;
    }
  }
  return 'download_${DateTime.now().millisecondsSinceEpoch}.bin';
}

String _withDownloadParam(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.path.endsWith('/api/media')) return url;
  if (uri.queryParameters.containsKey('download')) return url;
  final qp = Map<String, String>.from(uri.queryParameters);
  qp['download'] = '1';
  return uri.replace(queryParameters: qp).toString();
}

/// Download a media URL into `Documents/Downloads` on mobile (or open externally
/// on desktop) and optionally open it in the system viewer.
Future<void> downloadAndSaveMediaUrl(
  BuildContext context,
  String url, {
  String? fileName,
  bool openAfter = false,
}) async {
  final effectiveUrl = _withDownloadParam(url);
  final displayName =
      (fileName != null && fileName.isNotEmpty) ? fileName : _inferMediaFileName(url);
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (!_isMobile) {
    await _launchExternal(context, effectiveUrl);
    return;
  }
  messenger?.showSnackBar(
    SnackBar(
      content: Text('正在下载 $displayName…'),
      duration: const Duration(seconds: 2),
    ),
  );
  try {
    final file = await MediaDownloader.download(effectiveUrl, displayName);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(Platform.isIOS
            ? '已保存到「文件」App › VibeHelper › Downloads'
            : '已保存：${file.path}'),
        duration: const Duration(seconds: 3),
      ),
    );
    if (openAfter) {
      final res = await OpenFilex.open(file.path);
      if (res.type != ResultType.done && messenger != null) {
        messenger.showSnackBar(
          SnackBar(content: Text('没有可打开该文件的应用：${res.message}')),
        );
      }
    }
  } catch (e) {
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text('下载失败：$e')));
  }
}

Future<void> _launchExternal(BuildContext context, String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
      .catchError((_) => false);
  if (!ok && context.mounted) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('无法打开链接')));
  }
}

/// Streams a host file into the app's Downloads folder.
class MediaDownloader {
  static Future<Directory> downloadsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}Downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> download(String url, String fileName) async {
    final dir = await downloadsDir();
    final safe = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final target = File('${dir.path}${Platform.pathSeparator}$safe');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final tmp = File('${target.path}.part');
      final sink = tmp.openWrite();
      await resp.pipe(sink);
      if (await target.exists()) await target.delete();
      return await tmp.rename(target.path);
    } finally {
      client.close(force: true);
    }
  }
}

class _FileAttachmentCard extends StatelessWidget {
  const _FileAttachmentCard({
    required this.attachment,
    required this.onTap,
    required this.onDownload,
  });

  final MediaAttachment attachment;
  final VoidCallback onTap;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final p = VibeTheme.paletteOf(context);
    final a = attachment;
    final sub = [
      if (a.isVideo) '视频' else if (_isTextPreviewable(a)) '可预览' else '文件',
      formatFileSize(a.size),
    ].where((s) => s.isNotEmpty).join(' · ');
    return Material(
      color: p.panelAlt,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: p.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  a.isVideo ? Icons.play_circle_fill_rounded : _fileIcon(a),
                  color: p.accent,
                  size: a.isVideo ? 24 : 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                    if (sub.isNotEmpty)
                      Text(sub,
                          style: TextStyle(fontSize: 11, color: p.muted)),
                  ],
                ),
              ),
              IconButton(
                tooltip: '下载',
                visualDensity: VisualDensity.compact,
                onPressed: onDownload,
                icon: Icon(Icons.download_rounded, size: 20, color: p.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact inline audio player (play/pause + seek) for voice notes / audio files.
class _AudioAttachmentCard extends StatefulWidget {
  const _AudioAttachmentCard({
    required this.attachment,
    required this.url,
    required this.onMore,
  });

  final MediaAttachment attachment;
  final String url;
  final VoidCallback onMore;

  @override
  State<_AudioAttachmentCard> createState() => _AudioAttachmentCardState();
}

class _AudioAttachmentCardState extends State<_AudioAttachmentCard> {
  VideoPlayerController? _ctrl;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _ctrl?.removeListener(_onTick);
    _ctrl?.dispose();
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    if (!_inlinePlaybackSupported) {
      await _launchExternal(context, widget.url);
      return;
    }
    final c = _ctrl;
    if (c != null && c.value.isInitialized) {
      if (c.value.isPlaying) {
        await c.pause();
      } else {
        if (c.value.position >= c.value.duration) {
          await c.seekTo(Duration.zero);
        }
        await c.play();
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    try {
      await ctrl.initialize();
      ctrl.addListener(_onTick);
      _ctrl = ctrl;
      await ctrl.play();
    } catch (e) {
      await ctrl.dispose();
      _error = '无法播放';
    }
    if (mounted) setState(() => _loading = false);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = VibeTheme.paletteOf(context);
    final v = _ctrl?.value;
    final ready = v != null && v.isInitialized;
    final dur = ready ? v.duration : Duration.zero;
    final pos = ready ? v.position : Duration.zero;
    final progress = (ready && dur.inMilliseconds > 0)
        ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      decoration: BoxDecoration(
        color: p.panelAlt,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: _loading
                ? Padding(
                    padding: const EdgeInsets.all(11),
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: p.accent),
                  )
                : IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: _toggle,
                    icon: Icon(
                      ready && v.isPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                      size: 34,
                      color: p.accent,
                    ),
                  ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.attachment.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: p.text),
                ),
                const SizedBox(height: 2),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.5,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: progress,
                    activeColor: p.accent,
                    inactiveColor: p.border,
                    onChanged: ready
                        ? (x) => _ctrl!.seekTo(Duration(
                            milliseconds: (dur.inMilliseconds * x).round()))
                        : null,
                  ),
                ),
                Text(
                  _error ??
                      (ready
                          ? '${_fmt(pos)} / ${_fmt(dur)}'
                          : ['音频', formatFileSize(widget.attachment.size)]
                              .where((s) => s.isNotEmpty)
                              .join(' · ')),
                  style: TextStyle(
                      fontSize: 10.5,
                      color: _error != null ? p.danger : p.muted),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: widget.onMore,
            icon: Icon(Icons.more_vert_rounded, size: 18, color: p.muted),
          ),
        ],
      ),
    );
  }
}

/// Full-screen video (or audio) player with play/pause, seek and download.
class MediaPlayerPage extends StatefulWidget {
  const MediaPlayerPage({
    super.key,
    required this.url,
    required this.title,
    this.isAudio = false,
    this.onDownload,
  });

  final String url;
  final String title;
  final bool isAudio;
  final Future<void> Function(BuildContext context)? onDownload;

  @override
  State<MediaPlayerPage> createState() => _MediaPlayerPageState();
}

class _MediaPlayerPageState extends State<MediaPlayerPage> {
  late final VideoPlayerController _ctrl;
  String? _error;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..addListener(_onTick);
    _ctrl.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      _ctrl.play();
      _scheduleHide();
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '视频加载失败：$e');
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _ctrl.removeListener(_onTick);
    _ctrl.dispose();
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _ctrl.value.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final v = _ctrl.value;
    final ready = v.isInitialized;
    final dur = v.duration;
    final pos = v.position;
    final progress = (ready && dur.inMilliseconds > 0)
        ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15)),
        actions: [
          if (widget.onDownload != null)
            IconButton(
              tooltip: '下载',
              icon: const Icon(Icons.download_rounded),
              onPressed: () => widget.onDownload!(context),
            ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _showControls = !_showControls);
          if (_showControls) _scheduleHide();
        },
        child: Stack(
          children: [
            Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70)),
                    )
                  : !ready
                      ? const CircularProgressIndicator(color: Colors.white)
                      : AspectRatio(
                          aspectRatio:
                              v.aspectRatio > 0 ? v.aspectRatio : 16 / 9,
                          child: VideoPlayer(_ctrl),
                        ),
            ),
            if (ready && v.isBuffering)
              const Center(
                  child: CircularProgressIndicator(color: Colors.white54)),
            if (ready && _showControls) ...[
              Center(
                child: IconButton(
                  iconSize: 64,
                  onPressed: () {
                    if (v.isPlaying) {
                      _ctrl.pause();
                    } else {
                      if (pos >= dur) _ctrl.seekTo(Duration.zero);
                      _ctrl.play();
                      _scheduleHide();
                    }
                  },
                  icon: Icon(
                    v.isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_fill_rounded,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 24,
                child: SafeArea(
                  child: Row(
                    children: [
                      Text(_fmt(pos),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                      Expanded(
                        child: Slider(
                          value: progress,
                          activeColor: Colors.white,
                          inactiveColor: Colors.white24,
                          onChanged: (x) {
                            _ctrl.seekTo(Duration(
                                milliseconds:
                                    (dur.inMilliseconds * x).round()));
                            _scheduleHide();
                          },
                        ),
                      ),
                      Text(_fmt(dur),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Fetches and displays text-like files (code, logs, markdown, json ...).
class TextFilePreviewPage extends StatefulWidget {
  const TextFilePreviewPage({
    super.key,
    required this.url,
    required this.attachment,
    this.onDownload,
  });

  final String url;
  final MediaAttachment attachment;
  final Future<void> Function(BuildContext context)? onDownload;

  @override
  State<TextFilePreviewPage> createState() => _TextFilePreviewPageState();
}

class _TextFilePreviewPageState extends State<TextFilePreviewPage> {
  static const _maxPreviewBytes = 2 * 1024 * 1024;
  String? _text;
  String? _error;
  bool _truncated = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(widget.url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${_maxPreviewBytes - 1}');
      final resp = await req.close();
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        builder.add(chunk);
        if (builder.length >= _maxPreviewBytes) break;
      }
      final bytes = builder.takeBytes();
      _truncated = widget.attachment.size > bytes.length;
      var text = utf8.decode(bytes, allowMalformed: true);
      if (widget.attachment.displayName.toLowerCase().endsWith('.json')) {
        try {
          text = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
        } catch (_) {}
      }
      if (mounted) setState(() => _text = text);
    } catch (e) {
      if (mounted) setState(() => _error = '加载失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = VibeTheme.paletteOf(context);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.panel,
        foregroundColor: p.text,
        title: Text(widget.attachment.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15)),
        actions: [
          if (_text != null)
            IconButton(
              tooltip: '复制全部',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _text!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制')),
                );
              },
            ),
          if (widget.onDownload != null)
            IconButton(
              tooltip: '下载',
              icon: const Icon(Icons.download_rounded),
              onPressed: () => widget.onDownload!(context),
            ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!, style: TextStyle(color: p.danger)))
          : _text == null
              ? Center(child: CircularProgressIndicator(color: p.accent))
              : Column(
                  children: [
                    if (_truncated)
                      Container(
                        width: double.infinity,
                        color: p.warning.withValues(alpha: 0.15),
                        padding: const EdgeInsets.all(8),
                        child: Text('文件较大，仅预览前 2 MB，完整内容请下载',
                            style: TextStyle(fontSize: 12, color: p.text)),
                      ),
                    Expanded(
                      child: Scrollbar(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SelectableText(
                              _text!,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.45,
                                color: p.codeText,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
