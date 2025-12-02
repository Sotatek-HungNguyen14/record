import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

import 'platform/audio_recorder_platform.dart';

enum RecordingMode {
  fileOnly('File Only', Icons.save, 'AAC-LC (M4A)', 'Best quality file'),
  streamOnly('Stream Only', Icons.stream, 'PCM 16-bit', 'Raw audio data'),
  hybrid('Hybrid (Stream + File)', Icons.merge, 'AAC-LC (M4A)',
      'File + AAC stream (Android) / PCM (iOS)');

  final String label;
  final IconData icon;
  final String encoder;
  final String description;

  const RecordingMode(this.label, this.icon, this.encoder, this.description);
}

class Recorder extends StatefulWidget {
  final void Function(String path) onStop;

  const Recorder({super.key, required this.onStop});

  @override
  State<Recorder> createState() => _RecorderState();
}

class _RecorderState extends State<Recorder> with AudioRecorderMixin {
  int _recordDuration = 0;
  Timer? _timer;
  late final AudioRecorder _audioRecorder;
  StreamSubscription<RecordState>? _recordSub;
  RecordState _recordState = RecordState.stop;
  StreamSubscription<Amplitude>? _amplitudeSub;
  Amplitude? _amplitude;

  // 🆕 Recording mode and stream stats
  RecordingMode _recordingMode = RecordingMode.hybrid;
  int _streamBytesReceived = 0;
  int _streamChunksReceived = 0;
  DateTime? _recordingStartTime;

  @override
  void initState() {
    _audioRecorder = AudioRecorder();

    _recordSub = _audioRecorder.onStateChanged().listen((recordState) {
      _updateRecordState(recordState);
    });

    _amplitudeSub = _audioRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 300))
        .listen((amp) {
      setState(() => _amplitude = amp);
    });

    super.initState();
  }

  Future<void> _start() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        // 🎯 Select encoder based on recording mode
        // Stream-only mode ONLY supports PCM16bits
        // File and Hybrid modes can use AAC for better quality
        final encoder = _recordingMode == RecordingMode.streamOnly
            ? AudioEncoder.aacLc
            : AudioEncoder.aacLc;

        if (!await _isEncoderSupported(encoder)) {
          return;
        }

        final devs = await _audioRecorder.listInputDevices();
        debugPrint(devs.toString());

        final config =
            RecordConfig(encoder: encoder, sampleRate: 16000, numChannels: 1);

        // Reset stream stats
        setState(() {
          _streamBytesReceived = 0;
          _streamChunksReceived = 0;
          _recordingStartTime = DateTime.now();
        });

        // Start recording based on selected mode
        switch (_recordingMode) {
          case RecordingMode.fileOnly:
            await recordFile(_audioRecorder, config);
            debugPrint('🎙️ Recording to file only (${encoder.name})');
            break;

          case RecordingMode.streamOnly:
            await recordStream(_audioRecorder, config);
            debugPrint('📡 Recording stream only (${encoder.name})');
            break;

          case RecordingMode.hybrid:
            await recordHybrid(
              _audioRecorder,
              config,
              (data) {
                // Update stream statistics
                setState(() {
                  _streamBytesReceived += data.length;
                  _streamChunksReceived++;
                });
              },
            );
            debugPrint('🔄 Hybrid recording (${encoder.name})');
            break;
        }

        _recordDuration = 0;
        _startTimer();
      }
    } catch (e) {
      if (kDebugMode) {
        print(e);
      }
      // Show error to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stop() async {
    final path = await _audioRecorder.stop();

    if (path != null) {
      widget.onStop(path);

      downloadWebData(path);
    }
  }

  Future<void> _pause() => _audioRecorder.pause();

  Future<void> _resume() => _audioRecorder.resume();

  void _updateRecordState(RecordState recordState) {
    setState(() => _recordState = recordState);

    switch (recordState) {
      case RecordState.pause:
        _timer?.cancel();
        break;
      case RecordState.record:
        _startTimer();
        break;
      case RecordState.stop:
        _timer?.cancel();
        _recordDuration = 0;
        _streamBytesReceived = 0;
        _streamChunksReceived = 0;
        _recordingStartTime = null;
        break;
    }
  }

  Future<bool> _isEncoderSupported(AudioEncoder encoder) async {
    final isSupported = await _audioRecorder.isEncoderSupported(
      encoder,
    );

    if (!isSupported) {
      debugPrint('${encoder.name} is not supported on this platform.');
      debugPrint('Supported encoders are:');

      for (final e in AudioEncoder.values) {
        if (await _audioRecorder.isEncoderSupported(e)) {
          debugPrint('- ${e.name}');
        }
      }
    }

    return isSupported;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Mode selector
                if (_recordState == RecordState.stop) ...[
                  const Text(
                    'Recording Mode',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildModeSelector(),
                  const SizedBox(height: 40),
                ],

                // Recording controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    _buildRecordStopControl(),
                    const SizedBox(width: 20),
                    _buildPauseResumeControl(),
                    const SizedBox(width: 20),
                    _buildText(),
                  ],
                ),

                // Amplitude display
                if (_amplitude != null) ...[
                  const SizedBox(height: 40),
                  _buildAmplitudeWidget(),
                ],

                // Stream statistics (for hybrid mode)
                if (_recordState != RecordState.stop &&
                    (_recordingMode == RecordingMode.hybrid ||
                        _recordingMode == RecordingMode.streamOnly)) ...[
                  const SizedBox(height: 40),
                  _buildStreamStats(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _recordSub?.cancel();
    _amplitudeSub?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  Widget _buildRecordStopControl() {
    late Icon icon;
    late Color color;

    if (_recordState != RecordState.stop) {
      icon = const Icon(Icons.stop, color: Colors.red, size: 30);
      color = Colors.red.withValues(alpha: 0.1);
    } else {
      final theme = Theme.of(context);
      icon = Icon(Icons.mic, color: theme.primaryColor, size: 30);
      color = theme.primaryColor.withValues(alpha: 0.1);
    }

    return ClipOval(
      child: Material(
        color: color,
        child: InkWell(
          child: SizedBox(width: 56, height: 56, child: icon),
          onTap: () {
            (_recordState != RecordState.stop) ? _stop() : _start();
          },
        ),
      ),
    );
  }

  Widget _buildPauseResumeControl() {
    if (_recordState == RecordState.stop) {
      return const SizedBox.shrink();
    }

    late Icon icon;
    late Color color;

    if (_recordState == RecordState.record) {
      icon = const Icon(Icons.pause, color: Colors.red, size: 30);
      color = Colors.red.withValues(alpha: 0.1);
    } else {
      final theme = Theme.of(context);
      icon = const Icon(Icons.play_arrow, color: Colors.red, size: 30);
      color = theme.primaryColor.withValues(alpha: 0.1);
    }

    return ClipOval(
      child: Material(
        color: color,
        child: InkWell(
          child: SizedBox(width: 56, height: 56, child: icon),
          onTap: () {
            (_recordState == RecordState.pause) ? _resume() : _pause();
          },
        ),
      ),
    );
  }

  Widget _buildText() {
    if (_recordState != RecordState.stop) {
      return _buildTimer();
    }

    return const Text("Waiting to record");
  }

  Widget _buildTimer() {
    final String minutes = _formatNumber(_recordDuration ~/ 60);
    final String seconds = _formatNumber(_recordDuration % 60);

    return Text(
      '$minutes : $seconds',
      style: const TextStyle(color: Colors.red),
    );
  }

  String _formatNumber(int number) {
    String numberStr = number.toString();
    if (number < 10) {
      numberStr = '0$numberStr';
    }

    return numberStr;
  }

  void _startTimer() {
    _timer?.cancel();

    _timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      setState(() => _recordDuration++);
    });
  }

  Widget _buildModeSelector() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: RecordingMode.values.map((mode) {
          final isSelected = _recordingMode == mode;
          return InkWell(
            onTap: () => setState(() => _recordingMode = mode),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              decoration: BoxDecoration(
                color: isSelected
                    ? Theme.of(context).primaryColor.withValues(alpha: 0.1)
                    : null,
                border: mode != RecordingMode.values.last
                    ? Border(bottom: BorderSide(color: Colors.grey.shade300))
                    : null,
              ),
              child: Row(
                children: [
                  Icon(
                    mode.icon,
                    size: 28,
                    color: isSelected
                        ? Theme.of(context).primaryColor
                        : Colors.grey.shade600,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mode.label,
                          style: TextStyle(
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontSize: 16,
                            color: isSelected
                                ? Theme.of(context).primaryColor
                                : null,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          mode.description,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(
                              Icons.music_note,
                              size: 12,
                              color: Colors.grey.shade500,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              mode.encoder,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade500,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (isSelected)
                    Icon(
                      Icons.check_circle,
                      color: Theme.of(context).primaryColor,
                      size: 24,
                    ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildAmplitudeWidget() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          const Text(
            '🎵 Audio Level',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Column(
                children: [
                  const Text('Current', style: TextStyle(fontSize: 12)),
                  Text(
                    '${_amplitude?.current.toStringAsFixed(1) ?? "0.0"} dB',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Column(
                children: [
                  const Text('Max', style: TextStyle(fontSize: 12)),
                  Text(
                    '${_amplitude?.max.toStringAsFixed(1) ?? "0.0"} dB',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.red,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStreamStats() {
    final bytesInKB = (_streamBytesReceived / 1024).toStringAsFixed(2);
    final bytesInMB = (_streamBytesReceived / (1024 * 1024)).toStringAsFixed(2);
    final duration = _recordingStartTime != null
        ? DateTime.now().difference(_recordingStartTime!).inSeconds
        : 0;
    final bytesPerSecond = duration > 0 ? (_streamBytesReceived / duration) : 0;
    final kbps = (bytesPerSecond * 8 / 1000).toStringAsFixed(2);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.analytics, color: Colors.green.shade700),
              const SizedBox(width: 8),
              Text(
                '📊 Stream Statistics',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.green.shade900,
                ),
              ),
            ],
          ),
          const Divider(),
          _buildStatRow('Data Received', '$bytesInKB KB ($bytesInMB MB)'),
          _buildStatRow('Chunks Received', '$_streamChunksReceived'),
          _buildStatRow('Bitrate', '$kbps kbps'),
          if (_recordingMode == RecordingMode.hybrid) ...[
            const Divider(),
            Row(
              children: [
                Icon(Icons.save, size: 16, color: Colors.green.shade700),
                const SizedBox(width: 4),
                const Text(
                  'File being saved simultaneously',
                  style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, color: Colors.black87),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }
}
