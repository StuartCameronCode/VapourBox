import 'package:file_picker/file_picker.dart';

/// Extensions offered by the "add videos" file picker.
const List<String> videoFileExtensions = [
  'avi', 'mov', 'mp4', 'mkv', 'mxf', 'm2v', 'mpg', 'mpeg',
  'ts', 'vob', 'dv', 'mts', 'm2ts', 'wmv', 'webm', 'flv'
];

/// Shows the system file picker for one or more videos and returns their
/// paths, empty if cancelled. Shared by the drop zone, the queue's add button
/// and the Add Videos shortcut so they always offer the same file types.
Future<List<String>> pickVideoFiles() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: videoFileExtensions,
    allowMultiple: true,
  );
  if (result == null) return const [];
  return result.files
      .where((f) => f.path != null)
      .map((f) => f.path!)
      .toList();
}
