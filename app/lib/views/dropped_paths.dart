import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/dvd_info.dart';
import '../viewmodels/main_viewmodel.dart';
import 'dvd_title_picker.dart';

/// Handling for paths dropped on the app, shared by every drop target.
///
/// There is more than one: the [DropZone] covers the empty state, and the queue
/// panel takes over once the queue is populated. They must agree — a folder that
/// opens a DVD picker on one and is ignored by the other is a bug the user has
/// no way to explain. Keep this the single implementation rather than copying it
/// per widget.

/// File extensions the app will accept as a video.
const _videoExtensions = <String>{
  '.avi', '.mov', '.mp4', '.mkv', '.mxf', '.m2v', '.mpg', '.mpeg',
  '.ts', '.vob', '.dv', '.mts', '.m2ts', '.wmv', '.webm', '.flv',
};

/// Whether [path] looks like a video file this app can read.
bool isVideoFile(String path) {
  final lower = path.toLowerCase();
  return _videoExtensions.any(lower.endsWith);
}

/// Adds every dropped path to the queue.
///
/// Directories go through [MainViewModel.addFolder], which routes a ripped DVD
/// to the title picker and scans anything else for videos. Loose files are
/// filtered to videos and queued together.
Future<void> handleDroppedPaths(
  BuildContext context,
  List<String> paths,
) async {
  final viewModel = context.read<MainViewModel>();
  final videoFiles = <String>[];
  var sawDirectory = false;

  for (final path in paths) {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.directory) {
      sawDirectory = true;
      try {
        await viewModel.addFolder(path);
      } on DvdFolderDetected catch (e) {
        if (!context.mounted) return;
        await showDvdPicker(context, e.mountPoint);
      } catch (e) {
        if (!context.mounted) return;
        showDropError(context, 'Failed to open folder: $e');
      }
    } else if (isVideoFile(path)) {
      videoFiles.add(path);
    }
  }

  if (videoFiles.isNotEmpty) {
    viewModel.addMultipleToQueue(videoFiles);
  } else if (paths.isNotEmpty && !sawDirectory && context.mounted) {
    // Folders report their own outcome (queued, DVD picker, or "no videos
    // found" in the log), so only complain when nothing usable was dropped.
    showDropError(context, 'Please drop video files or folders');
  }
}

/// Reads the disc at [dvdRoot], shows the title picker, and queues the choice.
Future<void> showDvdPicker(BuildContext context, String dvdRoot) async {
  final viewModel = context.read<MainViewModel>();

  if (!context.mounted) return;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Text('Reading DVD structure...'),
        ],
      ),
    ),
  );

  DvdInfo? dvdInfo;
  String? error;
  try {
    dvdInfo = await viewModel.getDvdInfo(dvdRoot);
  } catch (e) {
    error = e.toString();
  }

  // Close the loading dialog.
  if (context.mounted) {
    Navigator.of(context).pop();
  }

  if (error != null) {
    if (context.mounted) {
      showDropError(context, 'Failed to read DVD: $error');
    }
    return;
  }

  if (dvdInfo == null || !context.mounted) return;

  final result = await DvdTitlePicker.show(context: context, dvdInfo: dvdInfo);

  if (result != null && context.mounted) {
    viewModel.addDvdTitle(
      dvdInfo: dvdInfo,
      titleIndex: result.titleIndex,
      startChapter: result.startChapter,
      endChapter: result.endChapter,
    );
  }
}

/// Shows a drop-related failure as a snack bar.
void showDropError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: Theme.of(context).colorScheme.error,
    ),
  );
}
