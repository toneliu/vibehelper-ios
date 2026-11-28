import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/pinned_http_client.dart';
import '../../core/theme.dart';

String? httpBaseFromWsUrl(String rawWsUrl) {
  final wsUri = Uri.tryParse(rawWsUrl.trim());
  if (wsUri == null || wsUri.host.isEmpty) return null;
  final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
  final port = wsUri.hasPort ? wsUri.port : (scheme == 'https' ? 443 : 8765);
  return '$scheme://${wsUri.host}:$port';
}

enum _LogFilter { all, actions, terminal, errors }

class _IpSummaryItem {
  const _IpSummaryItem({
    required this.ip,
    required this.count,
    required this.lastSeen,
    required this.failed,
    required this.actions,
  });

  final String ip;
  final int count;
  final String lastSeen;
  final int failed;
  final int actions;

  factory _IpSummaryItem.fromJson(Map<String, dynamic> j) => _IpSummaryItem(
        ip: (j['ip'] as String?) ?? 'unknown',
        count: (j['count'] as num?)?.toInt() ?? 0,
        lastSeen: (j['last_seen'] as String?) ?? '',
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        actions: (j['actions'] as num?)?.toInt() ?? 0,
      );
}

class _AccessLogEntry {
  const _AccessLogEntry({
    required this.time,
    required this.ip,
    required this.peerIp,
    required this.kind,
    required this.method,
    required this.target,
    required this.status,
    required this.ok,
    required this.detail,
    required this.ua,
  });

  final String time;
  final String ip;
  final String peerIp;
  final String kind;
  final String method;
  final String target;
  final int status;
  final bool ok;
  final String detail;
  final String ua;

  factory _AccessLogEntry.fromJson(Map<String, dynamic> j) => _AccessLogEntry(
        time: (j['time'] as String?) ?? (j['timestamp'] as String?) ?? '',
        ip: (j['ip'] as String?) ?? 'unknown',
        peerIp: (j['peer_ip'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'http',
        method: (j['method'] as String?) ?? '',
        target: (j['target'] as String?) ?? '',
        status: (j['status'] as num?)?.toInt() ?? 200,
        ok: (j['ok'] as bool?) ?? true,
        detail: (j['detail'] as String?) ?? '',
        ua: (j['ua'] as String?) ?? '',
      );
}

class AccessLogPage extends StatefulWidget {
  const AccessLogPage({
    super.key,
    required this.hostHttpBase,
    required this.hostToken,
    required this.hostName,
    this.tlsCertSha256 = '',
  });

  final String hostHttpBase;
  final String hostToken;
  final String hostName;
  final String tlsCertSha256;

  @override
  State<AccessLogPage> createState() => _AccessLogPageState();
}

class _AccessLogPageState extends State<AccessLogPage> {
  _LogFilter _filter = _LogFilter.all;
  String _selectedIp = '';
  bool _loading = true;
  String? _error;
  int _total = 0;
  List<_IpSummaryItem> _ipSummary = const [];
  List<_AccessLogEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _fetchLogs();
  }

  Future<void> _fetchLogs() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = createPinnedHttpClient(
      pinnedCertSha256: widget.tlsCertSha256,
      connectionTimeout: const Duration(seconds: 6),
    );
    try {
      final token = widget.hostToken.trim();
      final qp = <String, String>{
        'limit': '200',
        if (_selectedIp.isNotEmpty) 'ip': _selectedIp,
        if (_filter == _LogFilter.actions) 'only_actions': 'true',
        if (_filter == _LogFilter.terminal) 'only_terminal': 'true',
        if (_filter == _LogFilter.errors) 'only_errors': 'true',
      };
      final uri = Uri.parse('${widget.hostHttpBase}/api/host/access-logs')
          .replace(queryParameters: qp);
      final req = await client.getUrl(uri);
      applyAuthHeaders(req, token);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await utf8.decoder.bind(resp).join();
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      if (decoded['ok'] != true) {
        throw StateError((decoded['message'] as String?) ?? '获取日志失败');
      }
      final rawIps = (decoded['ip_summary'] as List<dynamic>?) ?? const [];
      final rawEntries = (decoded['entries'] as List<dynamic>?) ?? const [];
      if (!mounted) return;
      setState(() {
        _total = (decoded['total'] as num?)?.toInt() ?? rawEntries.length;
        _ipSummary = rawIps
            .whereType<Map<String, dynamic>>()
            .map(_IpSummaryItem.fromJson)
            .toList();
        _entries = rawEntries
            .whereType<Map<String, dynamic>>()
            .map(_AccessLogEntry.fromJson)
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载日志失败：$e';
      });
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _confirmClear() async {
    final p = VibeTheme.paletteOf(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        title: Text('清空审计日志', style: TextStyle(color: p.text)),
        content: Text(
          '确定清空宿主机上的所有 IP 访问与终端执行日志吗？此操作不可恢复。',
          style: TextStyle(color: p.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: p.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final client = createPinnedHttpClient(
      pinnedCertSha256: widget.tlsCertSha256,
      connectionTimeout: const Duration(seconds: 6),
    );
    try {
      final token = widget.hostToken.trim();
      final uri = Uri.parse('${widget.hostHttpBase}/api/host/access-logs');
      final req = await client.deleteUrl(uri);
      applyAuthHeaders(req, token);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      await resp.drain<void>();
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      setState(() => _selectedIp = '');
      await _fetchLogs();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清空失败：$e')),
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  (String, Color) _badgeFor(VibePalette p, _AccessLogEntry e) {
    if (e.kind == 'terminal_exec') return ('终端命令', p.warning);
    if (e.kind == 'terminal_session') return ('终端会话', p.accent);
    if (e.kind == 'ws_auth_fail') return ('鉴权失败', p.danger);
    if (e.kind == 'ws_action') {
      if (e.target.startsWith('audio_bridge')) return ('语音', p.accent);
      if (e.target == 'inject_text') return ('注入', p.success);
      if (e.target == 'input_key') return ('按键', p.accent);
      if (e.target.contains('stream')) return ('推流', p.accent);
      return ('操作', p.accent);
    }
    if (e.kind == 'ws_connect') return ('WS', p.accent);
    if (e.kind == 'ws_auth') return ('WS鉴权', p.success);
    if (e.kind == 'ws_disconnect') return ('WS断开', p.muted);
    if (!e.ok || e.status >= 400) return ('HTTP ${e.status}', p.danger);
    return ('HTTP', p.muted);
  }

  @override
  Widget build(BuildContext context) {
    final p = VibeTheme.paletteOf(context);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.panel,
        foregroundColor: p.text,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('IP 访问与终端审计日志', style: TextStyle(fontSize: 16)),
            Text(
              '${widget.hostName} · 共 $_total 条记录',
              style: TextStyle(fontSize: 11.5, color: p.muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _fetchLogs,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '清空日志',
            onPressed: _confirmClear,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_ipSummary.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              decoration: BoxDecoration(
                color: p.panel,
                border: Border(bottom: BorderSide(color: p.border, width: 0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '来访 IP 汇总（点击筛选）',
                    style: TextStyle(fontSize: 11.5, color: p.muted),
                  ),
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final item in _ipSummary) ...[
                          _buildIpChip(p, item),
                          const SizedBox(width: 6),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: p.panel,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (f, label) in const [
                    (_LogFilter.all, '全部'),
                    (_LogFilter.actions, '关键操作'),
                    (_LogFilter.terminal, '终端审计'),
                    (_LogFilter.errors, '仅异常'),
                  ]) ...[
                    ChoiceChip(
                      label: Text(label, style: const TextStyle(fontSize: 12)),
                      selected: _filter == f,
                      onSelected: (sel) {
                        if (!sel) return;
                        setState(() => _filter = f);
                        _fetchLogs();
                      },
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
          Expanded(
            child: _loading && _entries.isEmpty
                ? Center(child: CircularProgressIndicator(color: p.accent))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: p.danger),
                              ),
                              const SizedBox(height: 12),
                              FilledButton(
                                onPressed: _fetchLogs,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _entries.isEmpty
                        ? Center(
                            child: Text(
                              '暂无匹配的访问或终端审计记录',
                              style: TextStyle(color: p.muted),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _fetchLogs,
                            child: ListView.separated(
                              padding: const EdgeInsets.all(12),
                              itemCount: _entries.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (ctx, i) =>
                                  _buildEntryCard(p, _entries[i]),
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildIpChip(VibePalette p, _IpSummaryItem item) {
    final selected = _selectedIp == item.ip;
    final hasFail = item.failed > 0;
    final tint = hasFail ? p.danger : p.accent;
    return FilterChip(
      selected: selected,
      onSelected: (_) {
        setState(() => _selectedIp = selected ? '' : item.ip);
        _fetchLogs();
      },
      visualDensity: VisualDensity.compact,
      selectedColor: tint.withValues(alpha: 0.18),
      side: BorderSide(
        color: hasFail ? p.danger.withValues(alpha: 0.5) : p.border,
      ),
      label: Text(
        hasFail
            ? '${item.ip} · ${item.count}次 (异常${item.failed})'
            : '${item.ip} · ${item.count}次',
        style: TextStyle(
          fontSize: 11.5,
          color: hasFail ? p.danger : p.text,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildEntryCard(VibePalette p, _AccessLogEntry e) {
    final (badgeLabel, badgeColor) = _badgeFor(p, e);
    final viaProxy = e.peerIp.isNotEmpty && e.peerIp != e.ip;
    final ipText = viaProxy ? '${e.ip} (via ${e.peerIp})' : e.ip;
    final isTerminalCmd = e.kind == 'terminal_exec';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        final summary =
            '[${e.time}] $ipText ${e.kind} ${e.method} ${e.target} ${e.detail}'
                .trim();
        Clipboard.setData(ClipboardData(text: summary));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已复制该条审计记录'),
            duration: Duration(seconds: 1),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: !e.ok ? p.danger.withValues(alpha: 0.45) : p.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    badgeLabel,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: badgeColor,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    ipText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  e.time,
                  style: TextStyle(fontSize: 11, color: p.muted),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              '${e.method} ${e.target}${!e.ok ? '  (status=${e.status})' : ''}',
              style: TextStyle(fontSize: 11.5, color: p.muted),
            ),
            if (e.detail.isNotEmpty) ...[
              const SizedBox(height: 5),
              if (isTerminalCmd)
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: p.codeBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    e.detail,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      color: p.codeText,
                    ),
                  ),
                )
              else
                Text(
                  e.detail,
                  style: TextStyle(fontSize: 12, color: p.text),
                ),
            ],
            if (e.ua.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                e.ua,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: p.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
