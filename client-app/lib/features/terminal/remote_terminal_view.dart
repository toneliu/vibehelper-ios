import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';

/// Interactive remote terminal tab backed by `/ws/terminal`.
class RemoteTerminalView extends StatefulWidget {
  const RemoteTerminalView({
    super.key,
    required this.wsUrl,
    required this.token,
    required this.hostConnected,
    required this.isActiveTab,
    required this.hostOs,
    required this.palette,
  });

  final String wsUrl;
  final String token;
  final bool hostConnected;
  final bool isActiveTab;
  final String hostOs;
  final VibePalette palette;

  @override
  State<RemoteTerminalView> createState() => _RemoteTerminalViewState();
}

class _RemoteTerminalViewState extends State<RemoteTerminalView> {
  static const int _maxBufferChars = 60000;
  static final RegExp _oscRe =
      RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)');
  static final RegExp _csiRe = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final RegExp _escSingleRe = RegExp(r'\x1B[@-Z\\-_]');

  final TextEditingController _cmdCtrl = TextEditingController();
  final FocusNode _cmdFocus = FocusNode();
  final ScrollController _scrollCtrl = ScrollController();

  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;
  bool _connecting = false;
  bool _ready = false;
  String _shellName = 'terminal';
  String _remoteOs = '';
  String _cwd = '';
  String _statusText = '未连接';
  String _buffer = '';

  final List<String> _history = [];
  int _historyIdx = -1;

  @override
  void initState() {
    super.initState();
    _remoteOs = widget.hostOs.toLowerCase();
    if (widget.isActiveTab && widget.hostConnected) {
      unawaited(_connect());
    }
  }

  @override
  void didUpdateWidget(covariant RemoteTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.wsUrl != oldWidget.wsUrl || widget.token != oldWidget.token) {
      _disconnect();
      if (mounted) {
        setState(() {
          _buffer = '';
          _ready = false;
          _remoteOs = widget.hostOs.toLowerCase();
          _statusText = '未连接';
        });
      }
      if (widget.isActiveTab && widget.hostConnected) {
        unawaited(_connect());
      }
      return;
    }
    if (widget.hostOs.isNotEmpty && _remoteOs.isEmpty) {
      _remoteOs = widget.hostOs.toLowerCase();
    }
    if (widget.isActiveTab &&
        (!oldWidget.isActiveTab ||
            (widget.hostConnected && !oldWidget.hostConnected)) &&
        _ws == null &&
        !_connecting) {
      unawaited(_connect());
    }
  }

  @override
  void dispose() {
    _disconnect();
    _cmdCtrl.dispose();
    _cmdFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Uri? _buildTerminalWsUri() {
    final base = Uri.tryParse(widget.wsUrl.trim());
    if (base == null || base.host.isEmpty) return null;
    final token = widget.token.trim();
    return Uri(
      scheme: base.scheme == 'wss' ? 'wss' : 'ws',
      host: base.host,
      port: base.hasPort ? base.port : (base.scheme == 'wss' ? 443 : 8765),
      path: '/ws/terminal',
      queryParameters: token.isNotEmpty ? {'token': token} : null,
    );
  }

  String _stripAnsi(String raw) {
    return raw
        .replaceAll(_oscRe, '')
        .replaceAll(_csiRe, '')
        .replaceAll(_escSingleRe, '')
        .replaceAll('\x07', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
  }

  void _appendOutput(String text) {
    final cleaned = _stripAnsi(text);
    if (cleaned.isEmpty || !mounted) return;
    setState(() {
      var next = _buffer + cleaned;
      if (next.length > _maxBufferChars) {
        next = next.substring(next.length - _maxBufferChars);
      }
      _buffer = next;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  Future<void> _connect() async {
    if (_connecting) return;
    final uri = _buildTerminalWsUri();
    if (uri == null) {
      setState(() => _statusText = 'Host 地址无效');
      return;
    }

    _disconnect();
    setState(() {
      _connecting = true;
      _ready = false;
      _statusText = '正在连接终端...';
    });

    try {
      final ws = await WebSocket.connect(uri.toString())
          .timeout(const Duration(seconds: 6));
      if (!mounted) {
        await ws.close();
        return;
      }
      ws.pingInterval = const Duration(seconds: 10);
      _ws = ws;
      _wsSub = ws.listen(
        _onServerData,
        onError: (Object err) {
          if (!mounted) return;
          setState(() {
            _ready = false;
            _connecting = false;
            _statusText = '连接异常';
          });
          _appendOutput('\n[终端连接错误: $err]\n');
          _ws = null;
        },
        onDone: () {
          if (!mounted) return;
          setState(() {
            _ready = false;
            _connecting = false;
            _statusText = '已断开';
          });
          _ws = null;
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _ready = false;
        _statusText = '连接失败';
      });
      _appendOutput('\n[无法连接远程终端: $e]\n');
    }
  }

  void _disconnect() {
    unawaited(_wsSub?.cancel());
    _wsSub = null;
    final old = _ws;
    _ws = null;
    if (old != null) {
      unawaited(old.close());
    }
  }

  void _onServerData(dynamic raw) {
    if (!mounted || raw is! String) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final type = decoded['type'] as String? ?? '';
      if (type == 'ready') {
        setState(() {
          _connecting = false;
          _ready = true;
          _shellName = (decoded['shell'] as String?) ?? 'shell';
          _remoteOs = ((decoded['os'] as String?) ?? _remoteOs).toLowerCase();
          _cwd = (decoded['cwd'] as String?) ?? '';
          _statusText = '$_shellName · 已连接';
        });
      } else if (type == 'output') {
        _appendOutput((decoded['data'] as String?) ?? '');
      } else if (type == 'exit') {
        final code = decoded['code'];
        _appendOutput('\n[Shell 已退出 (code=$code)，可点击重开]\n');
        setState(() => _ready = false);
      } else if (type == 'error') {
        _appendOutput('\n[错误: ${decoded['message'] ?? 'unknown'}]\n');
      }
    } catch (_) {}
  }

  void _sendPayload(Map<String, dynamic> payload) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.add(jsonEncode(payload));
    } catch (_) {}
  }

  Future<void> _sendCommand([String? overrideCmd]) async {
    final cmd = (overrideCmd ?? _cmdCtrl.text).trimRight();
    if (cmd.isEmpty) return;

    if (_ws == null) {
      await _connect();
      if (_ws == null) return;
    }

    HapticFeedback.lightImpact();
    if (overrideCmd == null) {
      _cmdCtrl.clear();
    }
    if (_history.isEmpty || _history.last != cmd) {
      _history.add(cmd);
      if (_history.length > 100) {
        _history.removeAt(0);
      }
    }
    _historyIdx = -1;

    final isWin = _remoteOs == 'windows';
    if (isWin) {
      _appendOutput('\nPS> $cmd\n');
    }
    _sendPayload({'type': 'input', 'data': '$cmd\n'});
  }

  void _stepHistory(int delta) {
    if (_history.isEmpty) return;
    var nextIdx = _historyIdx;
    if (nextIdx == -1) {
      if (delta < 0) {
        nextIdx = _history.length - 1;
      } else {
        return;
      }
    } else {
      nextIdx += delta;
    }

    if (nextIdx < 0) {
      nextIdx = 0;
    } else if (nextIdx >= _history.length) {
      _historyIdx = -1;
      _cmdCtrl.clear();
      return;
    }

    _historyIdx = nextIdx;
    final val = _history[nextIdx];
    _cmdCtrl.value = TextEditingValue(
      text: val,
      selection: TextSelection.collapsed(offset: val.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final isWin = _remoteOs == 'windows';
    final quickCmds = isWin
        ? const ['dir', 'pwd', 'git status', 'ipconfig']
        : const ['ls -la', 'pwd', 'git status', 'nvidia-smi', 'df -h'];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        children: [
          // Top Status & Actions Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: p.panel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _ready
                        ? p.success
                        : (_connecting ? p.warning : p.danger),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _statusText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                      if (_cwd.isNotEmpty)
                        Text(
                          _cwd,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: p.muted,
                            fontFamily: 'monospace',
                          ),
                        ),
                    ],
                  ),
                ),
                _topBtn(p, '清屏', Icons.cleaning_services_outlined, () {
                  setState(() => _buffer = '');
                }),
                const SizedBox(width: 4),
                _topBtn(p, '重开', Icons.restart_alt_rounded, () {
                  if (_ws != null) {
                    _sendPayload({'type': 'restart'});
                  } else {
                    unawaited(_connect());
                  }
                }),
                const SizedBox(width: 4),
                _topBtn(p, '重连', Icons.refresh_rounded, () {
                  unawaited(_connect());
                }),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // Quick Command Bar
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    label: Text(
                      'Ctrl+C',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: p.danger,
                        fontFamily: 'monospace',
                      ),
                    ),
                    backgroundColor: p.danger.withValues(alpha: 0.12),
                    side: BorderSide(color: p.danger.withValues(alpha: 0.35)),
                    visualDensity: VisualDensity.compact,
                    onPressed: _ready
                        ? () {
                            HapticFeedback.mediumImpact();
                            _sendPayload(
                                {'type': 'signal', 'signal': 'SIGINT'});
                          }
                        : null,
                  ),
                ),
                for (final cmd in quickCmds)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text(
                        cmd,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: p.text,
                          fontFamily: 'monospace',
                        ),
                      ),
                      backgroundColor: p.panel,
                      side: BorderSide(color: p.border),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => unawaited(_sendCommand(cmd)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // Terminal Viewport
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1117),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: p.isDark ? p.border : const Color(0xFF30363D),
                ),
              ),
              child: SingleChildScrollView(
                controller: _scrollCtrl,
                child: SelectableText(
                  _buffer.isEmpty
                      ? (_ready
                          ? '远程 Shell 已就绪，在下方输入命令并发送...'
                          : '点击上方「重连」接入 Host 终端，或直接在下方输入命令发送')
                      : _buffer,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    height: 1.42,
                    color: Color(0xFFE6EDF3),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Bottom Command Input Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: p.panel,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: p.border),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上一条命令',
                  visualDensity: VisualDensity.compact,
                  onPressed: _history.isNotEmpty ? () => _stepHistory(-1) : null,
                  icon: Icon(Icons.keyboard_arrow_up_rounded,
                      size: 20, color: p.muted),
                ),
                IconButton(
                  tooltip: '下一条命令',
                  visualDensity: VisualDensity.compact,
                  onPressed: _history.isNotEmpty ? () => _stepHistory(1) : null,
                  icon: Icon(Icons.keyboard_arrow_down_rounded,
                      size: 20, color: p.muted),
                ),
                Text(
                  isWin ? '> ' : r'$ ',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: p.accent,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _cmdCtrl,
                    focusNode: _cmdFocus,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => unawaited(_sendCommand()),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13.5,
                      color: p.text,
                    ),
                    decoration: InputDecoration(
                      hintText: '输入 Shell 命令...',
                      hintStyle: TextStyle(fontSize: 13, color: p.muted),
                      filled: false,
                      fillColor: Colors.transparent,
                      hoverColor: Colors.transparent,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 8),
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => unawaited(_sendCommand()),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: p.accent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.send_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBtn(
    VibePalette p,
    String label,
    IconData icon,
    VoidCallback onTap,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
          color: p.panelAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: p.text),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
