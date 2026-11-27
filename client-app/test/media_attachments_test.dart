import 'package:flutter_test/flutter_test.dart';
import 'package:vibehelper_client/features/reader/media_attachments.dart';
import 'package:vibehelper_client/protocol/messages.dart';

void main() {
  group('MediaAttachment & URL resolution', () {
    test('DialogBlockItem round-trips attachments from host payload', () {
      final block = DialogBlockItem.fromJson({
        'role': 'assistant',
        'text': '已生成音频与演示视频',
        'images': ['/api/media?path=%2Ftmp%2Fshot.png'],
        'attachments': [
          {
            'url': '/api/media?path=%2Ftmp%2Fvoice.m4a',
            'kind': 'audio',
            'name': 'voice.m4a',
            'mime': 'audio/mp4',
            'size': 2048,
            'path': '/tmp/voice.m4a',
          },
          {
            'url': '/api/media?path=%2Ftmp%2Fdemo.mp4',
            'kind': 'video',
            'name': 'demo.mp4',
            'mime': 'video/mp4',
            'size': 1048576,
            'path': '/tmp/demo.mp4',
          },
          {
            'url': '/api/media?path=%2Ftmp%2Freport.pdf',
            'kind': 'file',
            'name': 'report.pdf',
            'mime': 'application/pdf',
            'size': 5120,
            'path': '/tmp/report.pdf',
          },
        ],
      });

      expect(block.attachments.length, 3);
      expect(block.attachments[0].isAudio, isTrue);
      expect(block.attachments[1].isVideo, isTrue);
      expect(block.attachments[2].displayName, 'report.pdf');

      final serialized = block.toJson();
      final reparsed = DialogBlockItem.fromJson(serialized);
      expect(reparsed.attachments.length, 3);
      expect(reparsed.attachments[1].mime, 'video/mp4');
    });

    test('resolveHostMediaUrl appends token and optional download flag', () {
      final streamUrl = resolveHostMediaUrl(
        '/api/media?path=%2Ftmp%2Fdemo.mp4',
        hostHttpBase: 'http://192.168.199.113:8765',
        hostToken: 'tok123',
      );
      final parsedStream = Uri.parse(streamUrl);
      expect(parsedStream.scheme, 'http');
      expect(parsedStream.host, '192.168.199.113');
      expect(parsedStream.port, 8765);
      expect(parsedStream.path, '/api/media');
      expect(parsedStream.queryParameters['path'], '/tmp/demo.mp4');
      expect(parsedStream.queryParameters['token'], 'tok123');
      expect(parsedStream.queryParameters.containsKey('download'), isFalse);

      final downloadUrl = resolveHostMediaUrl(
        '/api/media?path=%2Ftmp%2Fdemo.mp4',
        hostHttpBase: 'http://192.168.199.113:8765',
        hostToken: 'tok123',
        download: true,
      );
      final parsedDl = Uri.parse(downloadUrl);
      expect(parsedDl.queryParameters['token'], 'tok123');
      expect(parsedDl.queryParameters['download'], '1');
    });
  });
}
