import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_settings.dart';
import '../../core/theme.dart';
import '../connection/connection_controller.dart';

/// Host Security & Device Pairing management page:
/// - Generate 1-time 6-digit pairing codes for additional devices
/// - Set / update / clear custom master password & toggle mandatory auth
/// - Enable / disable HTTPS/WSS TLS encryption, view/copy SHA-256 fingerprint
/// - List & 1-tap revoke authorized device tokens
class HostSecurityPage extends ConsumerStatefulWidget {
  const HostSecurityPage({super.key, required this.hostName});

  final String hostName;

  @override
  ConsumerState<HostSecurityPage> createState() => _HostSecurityPageState();
}

class _HostSecurityPageState extends ConsumerState<HostSecurityPage> {
  HostSecurityStatus? _status;
  bool _loading = true;
  bool _busy = false;
  Timer? _countdownTimer;
  int _pairCountdownS = 0;

  final _pwCtrl = TextEditingController();
  final _pwConfirmCtrl = TextEditingController();
  final _sansCtrl = TextEditingController();
  final _certFileCtrl = TextEditingController();
  final _keyFileCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _pwCtrl.dispose();
    _pwConfirmCtrl.dispose();
    _sansCtrl.dispose();
    _certFileCtrl.dispose();
    _keyFileCtrl.dispose();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    setState(() => _pairCountdownS = seconds);
    if (seconds <= 0) return;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_pairCountdownS <= 1) {
        t.cancel();
        setState(() => _pairCountdownS = 0);
      } else {
        setState(() => _pairCountdownS -= 1);
      }
    });
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final st = await ref.read(hostActionProvider).fetchHostSecurity();
    if (!mounted) return;
    _sansCtrl.text = st.tlsExtraSans.join(', ');
    _certFileCtrl.text = st.tlsCertFile;
    _keyFileCtrl.text = st.tlsKeyFile;
    setState(() {
      _status = st;
      _loading = false;
    });
    if (st.activePairCode.isNotEmpty && st.activePairExpiresInS > 0) {
      _startCountdown(st.activePairExpiresInS);
    } else {
      _startCountdown(0);
    }
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? VibeTheme.danger : null,
      ),
    );
  }

  Future<void> _generateCode() async {
    setState(() => _busy = true);
    final (ok, code, expiresInS, msg) =
        await ref.read(hostActionProvider).generatePairingCode(ttlS: 600);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      _snack(msg, isError: true);
      return;
    }
    _snack('已生成 6 位配对码：$code');
    await _load();
    if (_pairCountdownS <= 0 && expiresInS > 0) {
      _startCountdown(expiresInS);
    }
  }

  Future<void> _saveMasterPassword() async {
    final p1 = _pwCtrl.text;
    final p2 = _pwConfirmCtrl.text;
    if (p1.length < 4) {
      _snack('主密码长度至少 4 位', isError: true);
      return;
    }
    if (p1 != p2) {
      _snack('两次输入的主密码不一致', isError: true);
      return;
    }
    setState(() => _busy = true);
    final (ok, msg) = await ref
        .read(hostActionProvider)
        .setMasterPassword(password: p1, requireAuth: true);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _pwCtrl.clear();
      _pwConfirmCtrl.clear();
    }
    _snack(msg, isError: !ok);
    await _load();
  }

  Future<void> _toggleRequireAuth(bool val) async {
    setState(() => _busy = true);
    final (ok, msg) =
        await ref.read(hostActionProvider).setMasterPassword(requireAuth: val);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(msg, isError: !ok);
    await _load();
  }

  Future<void> _saveTls({required bool enabled, bool regenerate = false}) async {
    final sans = _sansCtrl.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    setState(() => _busy = true);
    final (ok, sha, msg) = await ref.read(hostActionProvider).configureHostTls(
          enabled: enabled,
          certFile: _certFileCtrl.text,
          keyFile: _keyFileCtrl.text,
          extraSans: sans,
          regenerate: regenerate,
        );
    if (!mounted) return;
    if (ok && sha.isNotEmpty) {
      // Automatically pin newly generated / active cert fingerprint on current active profile
      final settings = ref.read(settingsProvider);
      final active = settings.activeHost;
      await ref.read(settingsProvider.notifier).upsertHostProfile(
            active.copyWith(tlsCertSha256: sha),
            select: false,
          );
    }
    setState(() => _busy = false);
    _snack(msg, isError: !ok);
    await _load();
  }

  Future<void> _revokeDevice(AuthorizedDeviceItem dev) async {
    final p = VibeTheme.paletteOf(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        title: Text('吊销设备权限', style: TextStyle(color: p.text)),
        content: Text(
          '确定要吊销「${dev.name}」的访问权限吗？该设备将立即失去控制权限，需重新配对才能连接。',
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
            child: const Text('确认吊销'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _busy = true);
    final (ok, msg) =
        await ref.read(hostActionProvider).revokeDevice(dev.id);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(msg, isError: !ok);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = VibeTheme.paletteOf(context);
    final st = _status;
    final activeHost = ref.watch(settingsProvider).activeHost;

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(
          '${widget.hostName} · 安全与设备',
          style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700, color: p.text),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading && st == null
          ? const Center(child: CircularProgressIndicator())
          : (st?.error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      st!.error!,
                      style: TextStyle(color: p.danger),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  children: [
                    // 1. Summary badges
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _statusBadge(
                          p,
                          icon: st!.authRequired
                              ? Icons.verified_user_rounded
                              : Icons.lock_open_rounded,
                          label: st.authRequired ? '已启用身份认证' : '未启用身份认证',
                          color: st.authRequired ? p.success : p.warning,
                        ),
                        _statusBadge(
                          p,
                          icon: st.tlsEnabled
                              ? Icons.https_rounded
                              : Icons.http_rounded,
                          label: st.tlsEnabled ? 'HTTPS/WSS 已启用' : '明文 HTTP/WS',
                          color: st.tlsEnabled ? p.success : p.warning,
                        ),
                        if (activeHost.hasPinnedCert)
                          _statusBadge(
                            p,
                            icon: Icons.fingerprint_rounded,
                            label: '本机已锁定 TLS 指纹',
                            color: p.accent,
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // 2. 6-digit pairing code
                    _sectionCard(
                      p,
                      title: '6 位一次性配对码',
                      subtitle: '给新手机或新设备配对使用，客户端会自动交换并保存 256-bit 设备凭证',
                      trailing: FilledButton(
                        onPressed: _busy ? null : _generateCode,
                        child: const Text('生成配对码', style: TextStyle(fontSize: 12)),
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: p.panelAlt,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: p.border),
                            ),
                            child: Center(
                              child: Text(
                                (st.activePairCode.isNotEmpty &&
                                        _pairCountdownS > 0)
                                    ? st.activePairCode
                                    : '------',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 6,
                                  color: (st.activePairCode.isNotEmpty &&
                                          _pairCountdownS > 0)
                                      ? p.accent
                                      : p.muted,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  (st.activePairCode.isNotEmpty &&
                                          _pairCountdownS > 0)
                                      ? '有效倒计时 $_pairCountdownS 秒（单次有效）'
                                      : '当前无有效配对码',
                                  style: TextStyle(fontSize: 12, color: p.muted),
                                ),
                              ),
                              if (st.activePairCode.isNotEmpty &&
                                  _pairCountdownS > 0)
                                TextButton.icon(
                                  onPressed: () {
                                    Clipboard.setData(
                                        ClipboardData(text: st.activePairCode));
                                    _snack('已复制 6 位配对码');
                                  },
                                  icon: const Icon(Icons.copy_rounded, size: 15),
                                  label: const Text('复制'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 3. Master password & auth switch
                    _sectionCard(
                      p,
                      title: '主密码与鉴权开关',
                      subtitle:
                          '只需记住一个个人主密码，新设备输入「地址 + 主密码」即可自动完成配对；宿主机仅存 scrypt 加盐哈希',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            title: Text('强制远程访问鉴权',
                                style: TextStyle(fontSize: 13.5, color: p.text)),
                            subtitle: Text(
                              st.hasMasterPassword
                                  ? '已设置主密码，公网暴露建议保持开启'
                                  : '建议先设置主密码并生成新设备凭证后再开启',
                              style: TextStyle(fontSize: 11.5, color: p.muted),
                            ),
                            value: st.requireAuth,
                            onChanged: _busy ? null : _toggleRequireAuth,
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _pwCtrl,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: '设置/更改主密码（至少 4 位）',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _pwConfirmCtrl,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: '确认主密码',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton(
                                  onPressed: _busy ? null : _saveMasterPassword,
                                  child: const Text('保存主密码并开启鉴权'),
                                ),
                              ),
                              if (st.hasMasterPassword) ...[
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  onPressed: _busy
                                      ? null
                                      : () async {
                                          setState(() => _busy = true);
                                          final (ok, msg) = await ref
                                              .read(hostActionProvider)
                                              .setMasterPassword(clear: true);
                                          if (!mounted) return;
                                          setState(() => _busy = false);
                                          _snack(msg, isError: !ok);
                                          await _load();
                                        },
                                  child: const Text('清除'),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 4. TLS Encryption & Fingerprint Pinning
                    _sectionCard(
                      p,
                      title: '公网 HTTPS / WSS 加密与证书指纹',
                      subtitle:
                          '端口映射到公网时请务必开启 TLS（保存后需重启宿主服务，并将本机连接地址切换为 wss://）',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            title: Text('启用 HTTPS / WSS 加密监听',
                                style: TextStyle(fontSize: 13.5, color: p.text)),
                            subtitle: Text(
                              '模式: ${st.tlsCertMode == 'custom' ? '自定义证书' : '自动自签名 ECDSA 证书'}',
                              style: TextStyle(fontSize: 11.5, color: p.muted),
                            ),
                            value: st.tlsEnabled,
                            onChanged: _busy
                                ? null
                                : (val) => _saveTls(enabled: val),
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _sansCtrl,
                            decoration: const InputDecoration(
                              labelText: 'DDNS 域名 / 公网 IP (SAN, 逗号分隔)',
                              hintText: 'home.ddns.net, 1.2.3.4',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (st.tlsCertSha256.isNotEmpty) ...[
                            Text('当前证书 SHA-256 指纹:',
                                style: TextStyle(fontSize: 11.5, color: p.muted)),
                            const SizedBox(height: 4),
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                Clipboard.setData(
                                    ClipboardData(text: st.tlsCertSha256));
                                _snack('已复制 SHA-256 证书指纹');
                              },
                              child: Container(
                                padding: const EdgeInsets.all(9),
                                decoration: BoxDecoration(
                                  color: p.panelAlt,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: p.border),
                                ),
                                child: Text(
                                  st.tlsCertSha256,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: p.text,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _saveTls(
                                          enabled: st.tlsEnabled,
                                          regenerate: false),
                                  child: const Text('保存 SAN 配置'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: FilledButton.tonal(
                                  onPressed: _busy
                                      ? null
                                      : () => _saveTls(
                                          enabled: true, regenerate: true),
                                  child: const Text('生成新自签名证书'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 5. Authorized Devices
                    _sectionCard(
                      p,
                      title: '已授权设备 (${st.devices.length})',
                      subtitle: '支持 1 键吊销遗失或不再使用的设备凭证，立即失效',
                      child: st.devices.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Text('暂无已配对设备',
                                  style:
                                      TextStyle(fontSize: 12.5, color: p.muted)),
                            )
                          : Column(
                              children: [
                                for (final d in st.devices)
                                  Container(
                                    margin: const EdgeInsets.only(top: 8),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 11, vertical: 9),
                                    decoration: BoxDecoration(
                                      color: p.panelAlt,
                                      borderRadius: BorderRadius.circular(11),
                                      border: Border.all(color: p.border),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          d.platform == 'ios'
                                              ? Icons.phone_iphone_rounded
                                              : Icons.smartphone_rounded,
                                          size: 20,
                                          color: p.accent,
                                        ),
                                        const SizedBox(width: 9),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                d.name,
                                                style: TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: p.text,
                                                ),
                                              ),
                                              Text(
                                                '${d.platform} · ${d.lastIp.isNotEmpty ? d.lastIp : '-'}',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: p.muted),
                                              ),
                                            ],
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: _busy
                                              ? null
                                              : () => _revokeDevice(d),
                                          child: Text('吊销',
                                              style: TextStyle(
                                                  color: p.danger,
                                                  fontWeight: FontWeight.w700)),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ],
                )),
    );
  }

  Widget _statusBadge(
    VibePalette p, {
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard(
    VibePalette p, {
    required String title,
    required String subtitle,
    Widget? trailing,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700, color: p.text),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: TextStyle(fontSize: 11.5, color: p.muted)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
