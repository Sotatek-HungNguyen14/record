// ignore_for_file: avoid_print

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

mixin AudioRecorderMixin {
  Future<void> recordFile(AudioRecorder recorder, RecordConfig config) async {
    final path = await _getPath();

    await recorder.start(config, path: path);
  }

  Future<void> recordStream(AudioRecorder recorder, RecordConfig config) async {
    final path = await _getPath();

    final file = File(path);

    final stream = await recorder.startStream(config);

    stream.listen(
      (data) {
        file.writeAsBytesSync(data, mode: FileMode.append);
      },
      onDone: () {
        print('End of stream. File written to $path.');
      },
    );
  }

  /// 🆕 Hybrid mode: Stream audio data AND save to file simultaneously
  Future<void> recordHybrid(
    AudioRecorder recorder,
    RecordConfig config,
    void Function(List<int> data)? onData,
  ) async {
    final path = await _getPath();

    print('🎯 Starting hybrid recording to: $path');

    final stream = await recorder.startStreamWithFile(config, path: path);

    stream.listen(
      (data) {
        // Process stream data (e.g., for real-time transcription)
        onData?.call(data);
      },
      onDone: () {
        print('✅ Hybrid recording complete. File saved to $path.');
      },
      onError: (error) {
        print('❌ Error in hybrid recording: $error');
      },
    );
  }

  void downloadWebData(String path) {}

  Future<String> _getPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(
      dir.path,
      'audio_${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
  }
}
