import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as path;

class RecordingsListScreen extends StatefulWidget {
  const RecordingsListScreen({super.key});

  @override
  State<RecordingsListScreen> createState() => _RecordingsListScreenState();
}

class _RecordingsListScreenState extends State<RecordingsListScreen> {
  List<FileSystemEntity> _recordings = [];
  bool _isLoading = true;
  String? _error;
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _currentPlayingPath;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _loadRecordings();
    _audioPlayer.onPlayerStateChanged.listen((state) {
      setState(() {
        _isPlaying = state == PlayerState.playing;
      });
    });
    _audioPlayer.onPlayerComplete.listen((_) {
      setState(() {
        _currentPlayingPath = null;
        _isPlaying = false;
      });
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadRecordings() async {
    if (kIsWeb) {
      setState(() {
        _error = 'Web platform not supported for file listing';
        _isLoading = false;
      });
      return;
    }

    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final directory = await getApplicationDocumentsDirectory();
      final recordings = directory
          .listSync()
          .where((entity) =>
              entity is File &&
              (entity.path.endsWith('.wav') ||
                  entity.path.endsWith('.m4a') ||
                  entity.path.endsWith('.aac') ||
                  entity.path.endsWith('.mp3')))
          .toList();

      // Sort by modified date (newest first)
      recordings.sort((a, b) {
        final aStats = a.statSync();
        final bStats = b.statSync();
        return bStats.modified.compareTo(aStats.modified);
      });

      setState(() {
        _recordings = recordings;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _playPauseRecording(String filePath) async {
    try {
      if (_currentPlayingPath == filePath && _isPlaying) {
        await _audioPlayer.pause();
      } else if (_currentPlayingPath == filePath && !_isPlaying) {
        await _audioPlayer.resume();
      } else {
        await _audioPlayer.stop();
        await _audioPlayer.play(DeviceFileSource(filePath));
        setState(() {
          _currentPlayingPath = filePath;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Failed to play: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    await _audioPlayer.stop();
    setState(() {
      _currentPlayingPath = null;
      _isPlaying = false;
    });
  }

  Future<void> _deleteRecording(File file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Recording'),
        content: Text('Delete ${path.basename(file.path)}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        if (_currentPlayingPath == file.path) {
          await _stopRecording();
        }
        await file.delete();
        await _loadRecordings();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✅ Recording deleted')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Failed to delete: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _showFileInfo(File file) async {
    final stats = file.statSync();
    final sizeInBytes = stats.size;
    final sizeInKB = (sizeInBytes / 1024).toStringAsFixed(2);
    final sizeInMB = (sizeInBytes / (1024 * 1024)).toStringAsFixed(2);
    final modified = stats.modified;

    // Try to get duration if possible
    String? duration;
    try {
      await _audioPlayer.setSourceDeviceFile(file.path);
      final dur = await _audioPlayer.getDuration();
      if (dur != null) {
        final minutes = dur.inMinutes;
        final seconds = dur.inSeconds % 60;
        duration = '${minutes}m ${seconds}s';
      }
    } catch (_) {
      duration = 'Unable to read';
    }

    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(path.basename(file.path)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(label: 'Size', value: '$sizeInMB MB ($sizeInKB KB)'),
              const SizedBox(height: 8),
              _InfoRow(label: 'Duration', value: duration ?? 'N/A'),
              const SizedBox(height: 8),
              _InfoRow(
                label: 'Modified',
                value:
                    '${modified.day}/${modified.month}/${modified.year} ${modified.hour}:${modified.minute.toString().padLeft(2, '0')}',
              ),
              const SizedBox(height: 8),
              _InfoRow(label: 'Path', value: file.path),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved Recordings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadRecordings,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading recordings...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text('Error: $_error'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadRecordings,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_recordings.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.mic_off, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No recordings found'),
            const SizedBox(height: 8),
            Text(
              'Start recording to see your files here',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _recordings.length,
      itemBuilder: (context, index) {
        final file = _recordings[index] as File;
        final fileName = path.basename(file.path);
        final stats = file.statSync();
        final sizeInMB = (stats.size / (1024 * 1024)).toStringAsFixed(2);
        final isPlaying = _currentPlayingPath == file.path && _isPlaying;
        final isCurrentFile = _currentPlayingPath == file.path;

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          elevation: isCurrentFile ? 4 : 1,
          color: isCurrentFile ? Colors.blue.shade50 : null,
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: isCurrentFile ? Colors.blue : Colors.grey[300],
              child: Icon(
                isPlaying ? Icons.play_arrow : Icons.music_note,
                color: isCurrentFile ? Colors.white : Colors.grey[700],
              ),
            ),
            title: Text(
              fileName,
              style: TextStyle(
                fontWeight: isCurrentFile ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text('Size: $sizeInMB MB'),
                Text(
                  'Modified: ${stats.modified.day}/${stats.modified.month}/${stats.modified.year} ${stats.modified.hour}:${stats.modified.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Play/Pause button
                IconButton(
                  icon: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.blue,
                  ),
                  onPressed: () => _playPauseRecording(file.path),
                ),
                // Stop button (only show when playing this file)
                if (isCurrentFile)
                  IconButton(
                    icon: const Icon(Icons.stop, color: Colors.orange),
                    onPressed: _stopRecording,
                  ),
                // Info button
                IconButton(
                  icon: const Icon(Icons.info_outline, color: Colors.grey),
                  onPressed: () => _showFileInfo(file),
                ),
                // Delete button
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () => _deleteRecording(file),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            '$label:',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}

