import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibehelper_client/features/connection/connection_controller.dart';
import 'package:vibehelper_client/features/reader/chat_cache_store.dart';
import 'package:vibehelper_client/protocol/messages.dart';

void main() {
  group('VibeHelper Protocol v1.0 Dart models', () {
    test('encodes inject_text with Chinese + code and options', () {
      const msg = InjectTextMessage(
        requestId: 'req-1',
        targetWindowId: '123',
        text: '帮我重构这个 React 组件',
        autoEnter: true,
        pasteShortcut: PasteShortcut.auto,
      );
      final decoded = jsonDecode(msg.encode()) as Map<String, dynamic>;
      expect(decoded['type'], 'inject_text');
      expect(decoded['request_id'], 'req-1');
      expect(decoded['target_window_id'], '123');
      expect(decoded['text'], '帮我重构这个 React 组件');
      expect(decoded['auto_enter'], true);
      expect(decoded['paste_shortcut'], 'auto');
      expect(decoded['restore_clipboard'], true);
    });

    test('parses window_list from host', () {
      const raw = '''
      {
        "type": "window_list",
        "request_id": "r1",
        "data": [
          {
            "id": "456",
            "title": "main.py - VS Code",
            "app": "code",
            "pid": 1200,
            "is_active": true,
            "is_terminal": false,
            "bounds": {"x": 0, "y": 0, "width": 1920, "height": 1080}
          }
        ]
      }
      ''';
      final parsed = parseHostMessage(raw);
      expect(parsed, isA<WindowListMessage>());
      final list = parsed! as WindowListMessage;
      expect(list.data.length, 1);
      expect(list.data.first.id, '456');
      expect(list.data.first.app, 'code');
      expect(list.data.first.isActive, true);
      expect(list.data.first.bounds?.width, 1920);
    });

    test('parses auth_ack and inject_result', () {
      const authRaw = '''
      {
        "type": "auth_ack",
        "ok": true,
        "protocol_version": "1.0",
        "host_info": {
          "hostname": "dev-box",
          "os": "linux",
          "display_server": "wayland"
        }
      }
      ''';
      final auth = parseHostMessage(authRaw) as AuthAckMessage;
      expect(auth.ok, true);
      expect(auth.hostInfo?.displayServer, 'wayland');

      const resRaw = '''
      {
        "type": "inject_result",
        "request_id": "req-1",
        "ok": true,
        "target_window_id": "123",
        "injected_chars": 15,
        "shortcut_used": "ctrl_shift_v",
        "auto_enter_sent": true,
        "elapsed_ms": 42
      }
      ''';
      final res = parseHostMessage(resRaw) as InjectResultMessage;
      expect(res.ok, true);
      expect(res.shortcutUsed, 'ctrl_shift_v');
      expect(res.elapsedMs, 42);
    });

    test('parses window_content with pending_questions', () {
      const contentRaw = '''
      {
        "type": "window_content",
        "window_title": "Antigravity",
        "app": "Antigravity",
        "agent_status": "idle",
        "pending_questions": [
          {
            "question": "选择渲染方案",
            "options": ["浅色灵光风", "深色极客风"],
            "is_multi_select": false
          },
          {
            "question": "启用哪些增强特性？",
            "options": ["CDP零抢焦", "会话同步"],
            "is_multi_select": true
          }
        ]
      }
      ''';
      final parsed = parseHostMessage(contentRaw) as WindowContentMessage;
      expect(parsed.pendingQuestions.length, 2);
      expect(parsed.pendingQuestions[0].question, '选择渲染方案');
      expect(parsed.pendingQuestions[0].isMultiSelect, false);
      expect(parsed.pendingQuestions[1].options, ['CDP零抢焦', '会话同步']);
      expect(parsed.pendingQuestions[1].isMultiSelect, true);
    });

    test('encodes sync_draft and parses draft_update', () {
      const syncMsg = SyncDraftMessage(
        requestId: 'd1',
        targetWindowId: 'win-ag',
        text: '实时输入草稿',
      );
      final encoded = jsonDecode(syncMsg.encode()) as Map<String, dynamic>;
      expect(encoded['type'], 'sync_draft');
      expect(encoded['target_window_id'], 'win-ag');
      expect(encoded['text'], '实时输入草稿');

      const updRaw = '''
      {
        "type": "draft_update",
        "target_window_id": "win-ag",
        "text": "Host端输入内容",
        "method": "cdp"
      }
      ''';
      final parsed = parseHostMessage(updRaw) as DraftUpdateMessage;
      expect(parsed.targetWindowId, 'win-ag');
      expect(parsed.text, 'Host端输入内容');
      expect(parsed.method, 'cdp');
    });

    test('encodes get_window_content delta fields and round-trips window_content', () {
      const req = GetWindowContentMessage(
        requestId: 'g1',
        targetWindowId: 'win-ag',
        sessionId: 'antigravity:s1',
        supportsDelta: true,
        knownSessionId: 'antigravity:s1',
        knownBlockCount: 5,
        knownPrefixHash: 'pref123',
        knownLastHash: 'last456',
      );
      final reqJson = jsonDecode(req.encode()) as Map<String, dynamic>;
      expect(reqJson['type'], 'get_window_content');
      expect(reqJson['supports_delta'], true);
      expect(reqJson['known_session_id'], 'antigravity:s1');
      expect(reqJson['known_block_count'], 5);
      expect(reqJson['known_prefix_hash'], 'pref123');
      expect(reqJson['known_last_hash'], 'last456');

      const original = WindowContentMessage(
        targetWindowId: 'win-ag',
        windowTitle: 'Antigravity',
        app: 'Antigravity',
        methodUsed: 'transcript',
        agentName: 'antigravity',
        activeSessionId: 'antigravity:s1',
        activeModel: 'Gemini 4 Neon',
        availableModels: ['Gemini 4 Neon'],
        agentStatus: 'working',
        sessions: [
          AgentSessionItem(
            id: 'antigravity:s1',
            agent: 'antigravity',
            title: '测试会话',
            updatedAt: '17:10',
            turnCount: 2,
          ),
        ],
        dialogBlocks: [
          DialogBlockItem(role: 'user', text: '你好', timestamp: '17:10'),
          DialogBlockItem(
            role: 'assistant',
            text: '已收到',
            thinking: '思考中',
            toolCalls: ['read_file(a.dart)'],
            diffItems: [
              DiffChangeItem(
                filePath: 'a.dart',
                kind: 'edit',
                summary: '+1 / -0',
                diffPreview: '+ok',
              ),
            ],
            images: ['/api/media?path=a.png'],
            timestamp: '17:10',
            model: 'Gemini 4 Neon',
          ),
        ],
        isDelta: true,
        deltaFromIndex: 1,
        totalBlockCount: 2,
        syncPrefixHash: 'pref123',
        syncLastHash: 'last456',
      );
      final roundTrip = WindowContentMessage.fromJson(
        jsonDecode(jsonEncode(original.toCacheJson())) as Map<String, dynamic>,
      );
      expect(roundTrip.activeSessionId, 'antigravity:s1');
      expect(roundTrip.isDelta, true);
      expect(roundTrip.deltaFromIndex, 1);
      expect(roundTrip.totalBlockCount, 2);
      expect(roundTrip.syncPrefixHash, 'pref123');
      expect(roundTrip.syncLastHash, 'last456');
      expect(roundTrip.dialogBlocks.length, 2);
      expect(roundTrip.dialogBlocks[1].diffItems.first.filePath, 'a.dart');
      expect(roundTrip.dialogBlocks[1].images, ['/api/media?path=a.png']);
      expect(buildFullTextFromBlocks(roundTrip.dialogBlocks), '【我】你好\n\n【AI】已收到');
    });

    test('ChatCacheStore persists, evicts LRU, and normalizes offline status', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ChatCacheStore(maxMemoryEntries: 4, maxDiskEntries: 2);
      await store.ensureLoaded();

      WindowContentMessage makeMsg(String sid, String text) => WindowContentMessage(
            activeSessionId: sid,
            windowTitle: 'Antigravity',
            app: 'Antigravity',
            agentStatus: 'working',
            pendingQuestions: const [
              PendingQuestionItem(question: 'Q?', options: ['A']),
            ],
            dialogBlocks: [DialogBlockItem(role: 'user', text: text)],
            totalBlockCount: 1,
            syncPrefixHash: '',
            syncLastHash: 'hash-$sid',
          );

      store.put('host1', makeMsg('s1', 'one'), immediateFlush: true);
      store.put('host1', makeMsg('s2', 'two'), immediateFlush: true);
      store.put('host1', makeMsg('s3', 'three'), immediateFlush: true);
      await store.flush();
      store.dispose();

      // Reload from mocked SharedPreferences: maxDiskEntries=2 evicted s1, kept s2 & s3
      final reloaded = ChatCacheStore(maxMemoryEntries: 4, maxDiskEntries: 2);
      await reloaded.ensureLoaded();
      expect(reloaded.getCached('host1', 's1'), isNull);
      final s2 = reloaded.getCached('host1', 's2');
      expect(s2, isNotNull);
      expect(s2!.dialogBlocks.first.text, 'two');
      expect(s2.agentStatus, 'idle');
      expect(s2.pendingQuestions, isEmpty);
      expect(s2.fullText, '【我】two');

      final last = reloaded.getLastForHost('host1');
      expect(last?.activeSessionId, 's3');
      expect(last?.syncLastHash, 'hash-s3');
      reloaded.dispose();
    });

    test('HostIdeApp parses supports_cdp and app_kind with legacy defaults', () {
      final chatgpt = HostIdeApp.fromJson(const {
        'id': 'chatgpt',
        'name': 'ChatGPT',
        'installed': true,
        'exe_path': '/usr/bin/chatgpt',
        'running': true,
        'cdp_port': 9225,
        'cdp_active': true,
        'cdp_pages': 1,
        'supports_cdp': true,
        'app_kind': 'cdp',
      });
      expect(chatgpt.isCli, false);
      expect(chatgpt.cdpPort, 9225);

      final claudeCli = HostIdeApp.fromJson(const {
        'id': 'claude',
        'name': 'Claude Code (CLI)',
        'installed': true,
        'exe_path': '/home/u/.local/bin/claude',
        'running': false,
        'cdp_port': 9226,
        'cdp_active': false,
        'cdp_pages': 0,
        'supports_cdp': false,
        'app_kind': 'cli',
      });
      expect(claudeCli.isCli, true);
      expect(claudeCli.supportsCdp, false);

      final legacy = HostIdeApp.fromJson(const {
        'id': 'antigravity',
        'name': 'Antigravity',
      });
      expect(legacy.supportsCdp, true);
      expect(legacy.appKind, 'cdp');
      expect(legacy.isCli, false);
    });
  });
}
