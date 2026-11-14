// A source whose timestamps reset (an MPEG-PS/TS, task #21) is decoded from
// a joined copy: `QueueItem.decodePath`. `inputPath` stays the user's file.
// A probe or decode that reads `inputPath` sees the broken timeline again
// (frame count short, seeks past a reset undefined) and nothing would say so,
// so every read of `.inputPath` in lib/ is listed here as one that means the
// user's file. A new read fails this test until it is classified: use
// `decodePath` for anything that probes or decodes.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/queue_item.dart';
import 'package:vapourbox/services/timestamp_continuity_service.dart';

/// file -> the trimmed lines allowed to read `.inputPath`, and why.
const _userFileReads = <String, Map<String, String>>{
  'lib/viewmodels/main_viewmodel.dart': {
    'String? get inputPath => selectedItem?.inputPath;': 'the user\'s file, for display',
    'if (_queue.any((q) => q.inputPath == filePath)) continue;': 'duplicate check on add',
    'item.inputPath,': 'the source _prepareContinuity scans and copies',
    'item.outputPath = _generateOutputPath(item.inputPath);': 'output naming',
    'inputPath: item.inputPath,': 'the failure log goes beside the user\'s file',
  },
  'lib/views/queue_panel.dart': {
    "_InfoRow(label: 'Path', value: item.inputPath),": 'display',
    'onPressed: () => _showInFolder(item.inputPath),': 'Show in Folder',
  },
  'lib/views/settings/settings_dialog.dart': {
    'if (viewModel.inputPath != null) ...[': 'whether a video is selected',
  },
  'lib/views/pass_settings/pass_settings_inline.dart': {
    'videoPath: item.inputPath,': 'the pitch-factor sidecar sits beside the user\'s file',
  },
};

void main() {
  test('every read of .inputPath in lib/ means the user\'s file, not the decode', () {
    final unclassified = <String>[];
    final read = RegExp(r'(?<!this)\.inputPath\b');
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      final allowed = _userFileReads[path] ?? const {};
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (!read.hasMatch(line)) continue;
        if (!allowed.containsKey(line)) unclassified.add('$path:${i + 1}: $line');
      }
    }
    expect(unclassified, isEmpty,
        reason: 'Use QueueItem.decodePath to probe or decode the source; list '
            'a read that means the user\'s own file in _userFileReads.');
  });

  test('decodePath is the joined copy when there is one, else the input', () {
    final item = QueueItem(inputPath: '/v/show.vob', outputPath: '/v/show.mkv');
    expect(item.decodePath, '/v/show.vob');
    item.continuityProxy =
        const ContinuityProxy(path: '/tmp/continuous_x_show.vob', resetCount: 2, sizeBytes: 3 << 30);
    expect(item.decodePath, '/tmp/continuous_x_show.vob');
    expect(item.inputPath, '/v/show.vob');
    expect(item.filename, 'show.vob');
    expect(item.continuityProxy!.note,
        'Timestamps reset 2 times; decoded from a joined copy (3.0 GB in the temp folder)');
  });

  test('a scan is read from the worker\'s JSON', () {
    final s = ContinuityScan.fromJson({
      'format': 'mpeg',
      'applies': true,
      'resets': [
        {'stream': 1, 'codecType': 'audio', 'packet': 250, 'from': 6.5, 'to': 0.53},
        {'stream': 0, 'codecType': 'video', 'packet': 150, 'from': 6.46, 'to': 0.5},
      ],
      'videoPackets': 300,
    });
    expect(s.needsCopy, isTrue);
    expect(s.videoResetPictures, [150]);
    expect(s.resetCount, 1);
    expect(const ContinuityScan(format: 'mpeg', applies: true).needsCopy, isFalse);
    expect(
        ContinuityScan.fromJson({
          'format': 'mov,mp4',
          'applies': false,
          'resets': [
            {'stream': 0, 'codecType': 'video', 'packet': 1, 'from': 1, 'to': 0},
          ],
        }).needsCopy,
        isFalse);
  });
}
