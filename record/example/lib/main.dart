import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:record_example/audio_player.dart';
import 'package:record_example/audio_recorder.dart';
import 'package:record_example/recordings_list_screen.dart';

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  int _currentIndex = 0;
  String? audioPath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Recorder Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: Text(_currentIndex == 0 ? 'Audio Recorder' : 'Recordings'),
          actions: [
            if (_currentIndex == 0 && audioPath != null)
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() => audioPath = null);
                },
                tooltip: 'Close player',
              ),
          ],
        ),
        body: IndexedStack(
          index: _currentIndex,
          children: [
            // Recorder Tab
            Center(
              child: audioPath != null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 25),
                      child: AudioPlayer(
                        source: audioPath!,
                        onDelete: () {
                          if (!kIsWeb) {
                            try {
                              File(audioPath!).deleteSync();
                            } catch (_) {
                              // Ignored
                            }
                          }

                          setState(() => audioPath = null);
                        },
                      ),
                    )
                  : Recorder(
                      onStop: (path) {
                        if (kDebugMode) print('Recorded file path: $path');
                        setState(() => audioPath = path);
                      },
                    ),
            ),
            // Recordings List Tab
            const RecordingsListScreen(),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) {
            setState(() {
              _currentIndex = index;
              // Clear audioPath when switching tabs
              if (index == 1) {
                audioPath = null;
              }
            });
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.mic),
              label: 'Record',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.list),
              label: 'Recordings',
            ),
          ],
        ),
        floatingActionButton: _currentIndex == 1
            ? FloatingActionButton(
                onPressed: () {
                  // Refresh recordings list
                  setState(() {
                    _currentIndex = 1; // Trigger rebuild
                  });
                },
                child: const Icon(Icons.refresh),
              )
            : null,
      ),
    );
  }
}
