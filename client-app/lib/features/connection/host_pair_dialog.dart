import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_settings.dart';
import '../../core/theme.dart';
import 'connection_controller.dart';

/// Shared Add / Edit / Pair Host dialog supporting:
/// - One-time 6-digit pairing code
/// - Personal Master Password
/// - Legacy Token or unauthenticated direct mode
/// Automatically handles TLS toggle (`wss://`) and SHA-256 certificate pinning.
Future<HostProfile?> showHostEditOrPairDialog(
  BuildContext context,
  WidgetRef ref, {
  HostProfile? existing,
}) async {
  final p = VibeTheme.paletteOf(context);
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final initialUrl = existing?.wsUrl ?? '192.168.1.';
  final urlCtrl = TextEditingController(text: initialUrl);
  final secretCtrl = TextEditingController();
  final tokenCtrl = TextEditingController(text: existing?.token ?? '');

  var useTls = existing?.isTls ?? false;
  var authMethod = (existing != null && existing.token.trim().isNotEmpty)
      ? 'token'
      : 'pair_code';
  var pinnedSha = existing?.tlsCertSha256 ?? '';
  var showAdvanced = existing != null &&
      (existing.token.trim().isNotEmpty || existing.hasPinnedCert);
  var pairing = false;
  String? errorMsg;

  String buildNormalizedUrl(String raw, bool tls) {
    var base = normalizeWsUrl(raw);
    if (tls && base.startsWith('ws://')) {
      base = 'wss://${base.substring(5)}';
    } else if (!tls && base.startsWith('wss://')) {
      base = 'ws://${base.substring(6)}';
    }
    return base;
  }

  final saved = await showDialog<HostProfile>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) {
        return AlertDialog(
          backgroundColor: p.panel,
          title: Text(
            existing == null ? '新增 / 配对宿主机' : '编辑宿主机',
            style: TextStyle(color: p.text, fontWeight: FontWeight.w700),
          ),
          content: SizedBox(
            width: 390,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '主机名称',
                      hintText: '例如：办公室 Win11 / 家用 Linux',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: urlCtrl,
                    keyboardType: TextInputType.url,
                    onChanged: (v) {
                      final trimmed = v.trim().toLowerCase();
                      if (trimmed.startsWith('wss://') ||
                          trimmed.startsWith('https://')) {
                        if (!useTls) setDlg(() => useTls = true);
                      } else if (trimmed.startsWith('ws://') ||
                          trimmed.startsWith('http://')) {
                        if (useTls) setDlg(() => useTls = false);
                      }
                    },
                    decoration: const InputDecoration(
                      labelText: '地址 (IP / 域名 / 端口)',
                      hintText: '192.168.110.125:8765 或 home.ddns.net:8765',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      '加密传输 (WSS / HTTPS)',
                      style: TextStyle(fontSize: 13, color: p.text),
                    ),
                    subtitle: Text(
                      '外网端口映射建议开启，配对时自动锁定自签名证书指纹',
                      style: TextStyle(fontSize: 11, color: p.muted),
                    ),
                    value: useTls,
                    onChanged: pairing
                        ? null
                        : (val) {
                            setDlg(() {
                              useTls = val;
                              urlCtrl.text =
                                  buildNormalizedUrl(urlCtrl.text, val);
                            });
                          },
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ChoiceChip(
                        label: const Text('6位配对码',
                            style: TextStyle(fontSize: 12)),
                        selected: authMethod == 'pair_code',
                        onSelected: pairing
                            ? null
                            : (_) => setDlg(() {
                                  authMethod = 'pair_code';
                                  errorMsg = null;
                                }),
                      ),
                      ChoiceChip(
                        label: const Text('主密码',
                            style: TextStyle(fontSize: 12)),
                        selected: authMethod == 'master_password',
                        onSelected: pairing
                            ? null
                            : (_) => setDlg(() {
                                  authMethod = 'master_password';
                                  errorMsg = null;
                                }),
                      ),
                      ChoiceChip(
                        label: const Text('直连/Token',
                            style: TextStyle(fontSize: 12)),
                        selected: authMethod == 'token',
                        onSelected: pairing
                            ? null
                            : (_) => setDlg(() {
                                  authMethod = 'token';
                                  errorMsg = null;
                                }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (authMethod == 'pair_code')
                    TextField(
                      controller: secretCtrl,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      decoration: const InputDecoration(
                        labelText: '6 位一次性配对码',
                        hintText: '在宿主机终端 / 本机页或已授权手机查看',
                        counterText: '',
                      ),
                    )
                  else if (authMethod == 'master_password')
                    TextField(
                      controller: secretCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '宿主机主密码',
                        hintText: '配对后自动保存设备凭证，无需反复输入密码',
                      ),
                    )
                  else
                    TextField(
                      controller: tokenCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '设备凭证 / Legacy Token (可选)',
                        hintText: '未开启鉴权可留空',
                      ),
                    ),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () => setDlg(() => showAdvanced = !showAdvanced),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            showAdvanced
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            size: 16,
                            color: p.muted,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            pinnedSha.isNotEmpty
                                ? '高级：已锁定 TLS 指纹'
                                : '高级：手动 Token / 证书指纹',
                            style: TextStyle(fontSize: 11.5, color: p.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (showAdvanced) ...[
                    const SizedBox(height: 6),
                    if (authMethod != 'token')
                      TextField(
                        controller: tokenCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: '当前已保存凭证 (只读/备选)',
                          isDense: true,
                        ),
                      ),
                    if (pinnedSha.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: p.panelAlt,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: p.border),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'SHA-256: $pinnedSha',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                  color: p.muted,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => setDlg(() => pinnedSha = ''),
                              child: const Text('清除锁定',
                                  style: TextStyle(fontSize: 11)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                  if (errorMsg != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorMsg!,
                      style: TextStyle(fontSize: 12, color: p.danger),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: pairing ? null : () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: pairing
                  ? null
                  : () async {
                      final normalizedUrl =
                          buildNormalizedUrl(urlCtrl.text, useTls);
                      if (normalizedUrl.isEmpty) return;
                      final hostLabel = nameCtrl.text.trim().isEmpty
                          ? inferHostLabel(normalizedUrl)
                          : nameCtrl.text.trim();

                      if (authMethod == 'token') {
                        Navigator.of(ctx).pop(
                          HostProfile(
                            id: existing?.id ??
                                'host-${DateTime.now().millisecondsSinceEpoch}',
                            name: hostLabel,
                            wsUrl: normalizedUrl,
                            token: tokenCtrl.text.trim(),
                            deviceId: existing?.deviceId ?? '',
                            tlsCertSha256: pinnedSha,
                            authMode: tokenCtrl.text.trim().isEmpty
                                ? ''
                                : (existing?.authMode ?? 'token'),
                          ),
                        );
                        return;
                      }

                      final secret = secretCtrl.text.trim();
                      if (authMethod == 'pair_code' && secret.length != 6) {
                        setDlg(() => errorMsg = '请输入完整的 6 位数字配对码');
                        return;
                      }
                      if (authMethod == 'master_password' &&
                          secretCtrl.text.isEmpty) {
                        setDlg(() => errorMsg = '请输入主密码');
                        return;
                      }

                      setDlg(() {
                        pairing = true;
                        errorMsg = null;
                      });
                      final deviceName = ref.read(settingsProvider).clientName;
                      final pairRes =
                          await ref.read(hostActionProvider).pairHost(
                                wsUrl: normalizedUrl,
                                code: authMethod == 'pair_code' ? secret : '',
                                password: authMethod == 'master_password'
                                    ? secretCtrl.text
                                    : '',
                                deviceName: deviceName,
                                expectedCertSha256: pinnedSha,
                              );
                      if (!ctx.mounted) return;
                      if (!pairRes.ok) {
                        setDlg(() {
                          pairing = false;
                          errorMsg = pairRes.message;
                        });
                        return;
                      }
                      Navigator.of(ctx).pop(
                        HostProfile(
                          id: existing?.id ??
                              'host-${DateTime.now().millisecondsSinceEpoch}',
                          name: nameCtrl.text.trim().isEmpty &&
                                  pairRes.hostName.isNotEmpty
                              ? pairRes.hostName
                              : hostLabel,
                          wsUrl: normalizedUrl,
                          token: pairRes.deviceToken,
                          deviceId: pairRes.deviceId,
                          tlsCertSha256: pairRes.tlsCertSha256,
                          authMode: 'paired',
                        ),
                      );
                    },
              child: pairing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(authMethod == 'token' ? '保存' : '配对并保存'),
            ),
          ],
        );
      },
    ),
  );

  nameCtrl.dispose();
  urlCtrl.dispose();
  secretCtrl.dispose();
  tokenCtrl.dispose();
  return saved;
}
