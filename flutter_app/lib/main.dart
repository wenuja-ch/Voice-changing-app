import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'device_helper.dart';

void main() {
  runApp(const VoiceChangerApp());
}

class VoiceChangerApp extends StatelessWidget {
  const VoiceChangerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Neon Voice Changer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0C091A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8B5CF6),
          secondary: Color(0xFF06B6D4),
          surface: Color(0xFF1E1B33),
        ),
      ),
      home: const VoiceChangerHomeScreen(),
    );
  }
}

class VoiceChangerHomeScreen extends StatefulWidget {
  const VoiceChangerHomeScreen({super.key});

  @override
  State<VoiceChangerHomeScreen> createState() => _VoiceChangerHomeScreenState();
}

class _VoiceChangerHomeScreenState extends State<VoiceChangerHomeScreen>
    with SingleTickerProviderStateMixin {
  // Config
  String _backendUrl = 'http://127.0.0.1:8000';
  final TextEditingController _urlController = TextEditingController(
    text: 'http://127.0.0.1:8000',
  );

  // Audio recording
  late final AudioRecorder _recorder;
  bool _isRecording = false;
  String? _rawRecordingPath;
  String? _originalWavPath;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  Timer? _amplitudeTimer;
  List<double> _waveAmplitudes = List.filled(30, 0.05, growable: true);

  // Audio players
  late final AudioPlayer _originalPlayer;
  late final AudioPlayer _processedPlayer;

  bool _isOriginalPlaying = false;
  Duration _originalDuration = Duration.zero;
  Duration _originalPosition = Duration.zero;

  bool _isProcessedPlaying = false;
  Duration _processedDuration = Duration.zero;
  Duration _processedPosition = Duration.zero;

  // App states
  bool _isProcessing = false;
  String _selectedEffect = 'none';
  String? _processedWavPath;
  Uint8List? _processedWavBytes;
  String? _errorMessage;

  // Live mode states
  bool _isLiveMode = false;
  bool _isLiveModulating = false;

  // Optimized live mode fields
  final AudioPlayer _livePlayer1 = AudioPlayer();
  final AudioPlayer _livePlayer2 = AudioPlayer();
  bool _useLivePlayer1 = true;
  final http.Client _httpClient = http.Client();
  StreamSubscription<Uint8List>? _recordSub;
  Timer? _liveChunkTimer;
  final List<int> _accumulatedBytes = [];

  // Device lists & selection
  List<InputDevice> _inputDevices = [];
  String? _selectedInputDeviceId;

  List<Map<String, String>> _outputDevices = [];
  String? _selectedOutputDeviceId;

  bool get _isCurrentlyRecording => _isRecording || _isLiveModulating;

  // Animation
  late AnimationController _pulseController;

  final List<Map<String, dynamic>> _effects = [
    {'id': 'none', 'name': 'Original', 'icon': '🗣️', 'desc': 'No change'},
    {'id': 'male', 'name': 'Male', 'icon': '👨', 'desc': 'Lower pitch'},
    {'id': 'female', 'name': 'Female', 'icon': '👩', 'desc': 'Higher pitch'},
    {'id': 'deep', 'name': 'Deep', 'icon': '🦁', 'desc': 'Ultra low pitch'},
    {
      'id': 'chipmunk',
      'name': 'Chipmunk',
      'icon': '🐿️',
      'desc': 'Squeaky high',
    },
    {'id': 'robot', 'name': 'Robot', 'icon': '🤖', 'desc': 'Metallic synth'},
    {'id': 'echo', 'name': 'Echo', 'icon': '⛰️', 'desc': 'Spacial delay'},
    {
      'id': 'distortion',
      'name': 'Distortion',
      'icon': '🎸',
      'desc': 'Fuzz & drive',
    },
    {'id': 'radio', 'name': 'Radio', 'icon': '📻', 'desc': 'Walkie-talkie'},
    {'id': 'alien', 'name': 'Alien', 'icon': '👽', 'desc': 'Extraterrestrial'},
  ];

  @override
  void initState() {
    super.initState();
    _recorder = AudioRecorder();
    _recorder.isEncoderSupported(AudioEncoder.pcm16bits).then((supported) {
      debugPrint('>>> AudioEncoder.pcm16bits supported: $supported');
    });
    _recorder.isEncoderSupported(AudioEncoder.wav).then((supported) {
      debugPrint('>>> AudioEncoder.wav supported: $supported');
    });
    _loadDevices();
    _originalPlayer = AudioPlayer();
    _processedPlayer = AudioPlayer();

    // Pulse animation for recording
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);

    // Player listeners
    _originalPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isOriginalPlaying = state == PlayerState.playing;
        });
      }
    });
    _originalPlayer.onDurationChanged.listen((duration) {
      if (mounted) {
        setState(() {
          _originalDuration = duration;
        });
      }
    });
    _originalPlayer.onPositionChanged.listen((position) {
      if (mounted) {
        setState(() {
          _originalPosition = position;
        });
      }
    });
    _originalPlayer.onPlayerComplete.listen((event) {
      if (mounted) {
        setState(() {
          _isOriginalPlaying = false;
          _originalPosition = Duration.zero;
        });
      }
    });

    _processedPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isProcessedPlaying = state == PlayerState.playing;
        });
      }
    });
    _processedPlayer.onDurationChanged.listen((duration) {
      if (mounted) {
        setState(() {
          _processedDuration = duration;
        });
      }
    });
    _processedPlayer.onPositionChanged.listen((position) {
      if (mounted) {
        setState(() {
          _processedPosition = position;
        });
      }
    });
    _processedPlayer.onPlayerComplete.listen((event) {
      if (mounted) {
        setState(() {
          _isProcessedPlaying = false;
          _processedPosition = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _recordSub?.cancel();
    _liveChunkTimer?.cancel();
    _recorder.dispose();
    _originalPlayer.dispose();
    _processedPlayer.dispose();
    _livePlayer1.dispose();
    _livePlayer2.dispose();
    _httpClient.close();
    _recordingTimer?.cancel();
    _amplitudeTimer?.cancel();
    _pulseController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    try {
      List<InputDevice> inputs = [];
      try {
        inputs = await _recorder.listInputDevices();
      } catch (e) {
        debugPrint('Error listing input devices: $e');
        final hasPermission = await _recorder.hasPermission();
        if (hasPermission) {
          inputs = await _recorder.listInputDevices();
        }
      }

      if (mounted) {
        setState(() {
          _inputDevices = inputs;
          if (_selectedInputDeviceId != null &&
              !inputs.any((d) => d.id == _selectedInputDeviceId)) {
            _selectedInputDeviceId = null;
          }
        });
      }

      final outputs = await getOutputDevices();
      if (mounted) {
        setState(() {
          _outputDevices = outputs;
          if (_selectedOutputDeviceId != null &&
              !outputs.any((d) => d['id'] == _selectedOutputDeviceId)) {
            _selectedOutputDeviceId = null;
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading devices: $e');
    }
  }

  // ----------------------------------------
  // Helper: Wave Header Injection
  // ----------------------------------------
  Uint8List _addWavHeader(Uint8List pcmBytes, int sampleRate) {
    final int byteLength = pcmBytes.length;
    final int fileLength = byteLength + 36;
    final ByteData header = ByteData(44);

    // RIFF
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F

    // File size - 8
    header.setUint32(4, fileLength, Endian.little);

    // WAVE
    header.setUint8(8, 0x57); // W
    header.setUint8(9, 0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E

    // fmt
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6d); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); //

    // Chunk size (16)
    header.setUint32(16, 16, Endian.little);

    // Audio format (1 = PCM)
    header.setUint16(20, 1, Endian.little);

    // Channels (1 = Mono)
    header.setUint16(22, 1, Endian.little);

    // Sample rate
    header.setUint32(24, sampleRate, Endian.little);

    // Byte rate (sampleRate * channels * bytesPerSample)
    header.setUint32(28, sampleRate * 1 * 2, Endian.little);

    // Block align (channels * bytesPerSample)
    header.setUint16(32, 1 * 2, Endian.little);

    // Bits per sample (16)
    header.setUint16(34, 16, Endian.little);

    // "data"
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a

    // Data chunk size
    header.setUint32(40, byteLength, Endian.little);

    final Uint8List wavFile = Uint8List(44 + byteLength);
    wavFile.setRange(0, 44, header.buffer.asUint8List());
    wavFile.setRange(44, wavFile.length, pcmBytes);
    return wavFile;
  }

  // ----------------------------------------
  // Audio Actions
  // ----------------------------------------
  Future<void> _toggleRecording() async {
    if (_isRecording || _isLiveModulating) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    setState(() {
      _errorMessage = null;
    });

    try {
      // Check permissions
      if (kIsWeb) {
        final hasPermission = await _recorder.hasPermission();
        if (!hasPermission) {
          setState(() {
            _errorMessage = 'Microphone permission denied.';
          });
          return;
        }
      } else {
        if (Platform.isAndroid || Platform.isIOS) {
          final status = await Permission.microphone.request();
          if (status != PermissionStatus.granted) {
            setState(() {
              _errorMessage = 'Microphone permission denied.';
            });
            return;
          }
        } else {
          // Windows, macOS, Linux
          final hasPermission = await _recorder.hasPermission();
          if (!hasPermission) {
            setState(() {
              _errorMessage = 'Microphone permission denied.';
            });
            return;
          }
        }
      }

      _originalWavPath = null;
      _processedWavPath = null;
      _processedWavBytes = null;

      if (_isLiveMode) {
        setState(() {
          _isLiveModulating = true;
          _selectedEffect = _selectedEffect == 'none'
              ? 'robot'
              : _selectedEffect;
        });

        if (kIsWeb) {
          _rawRecordingPath = 'live_chunk';
        } else {
          final tempDir = await getTemporaryDirectory();
          _rawRecordingPath = '${tempDir.path}/live_chunk';
        }

        // Start the loop
        _liveModulationLoop();
      } else {
        if (kIsWeb) {
          _rawRecordingPath = 'raw_voice.wav';
        } else {
          final tempDir = await getTemporaryDirectory();
          _rawRecordingPath = '${tempDir.path}/raw_voice.wav';
        }
        _selectedEffect = 'none';

        // Config
        InputDevice? selectedInputDevice;
        if (_selectedInputDeviceId != null) {
          try {
            selectedInputDevice = _inputDevices.firstWhere(
              (d) => d.id == _selectedInputDeviceId,
            );
          } catch (_) {}
        }

        final config = RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 44100,
          numChannels: 1,
          device: selectedInputDevice,
        );

        final normalizedPath = kIsWeb
            ? _rawRecordingPath!
            : File(_rawRecordingPath!).absolute.path;
        await _recorder.start(config, path: normalizedPath);
      }

      setState(() {
        if (!_isLiveMode) {
          _isRecording = true;
        }
        _recordingSeconds = 0;
      });

      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _recordingSeconds++;
        });
      });

      // Poll amplitude to draw visualizer
      _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 100), (
        timer,
      ) async {
        try {
          if (await _recorder.isRecording()) {
            final amp = await _recorder.getAmplitude();
            // Convert decibels (-160 to 0) to normalized 0.0 - 1.0 range
            double norm = (amp.current + 160) / 160;
            if (norm < 0.05) norm = 0.05;
            if (norm > 1.0) norm = 1.0;
            setState(() {
              _waveAmplitudes.removeAt(0);
              _waveAmplitudes.add(norm);
            });
          }
        } catch (_) {}
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to start recording: $e';
        _isRecording = false;
        _isLiveModulating = false;
      });
      _recordingTimer?.cancel();
      _amplitudeTimer?.cancel();
    }
  }

  Future<void> _liveModulationLoop() async {
    _accumulatedBytes.clear();

    try {
      InputDevice? selectedInputDevice;
      if (_selectedInputDeviceId != null) {
        try {
          selectedInputDevice = _inputDevices.firstWhere(
            (d) => d.id == _selectedInputDeviceId,
          );
        } catch (_) {}
      }

      final config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
        device: selectedInputDevice,
      );

      final recordStream = await _recorder.startStream(config);

      _recordSub = recordStream.listen((data) {
        if (_isLiveModulating) {
          _accumulatedBytes.addAll(data);
        }
      });

      _liveChunkTimer = Timer.periodic(const Duration(milliseconds: 500), (
        timer,
      ) async {
        if (!_isLiveModulating || _accumulatedBytes.isEmpty) return;

        final pcmBytes = Uint8List.fromList(_accumulatedBytes);
        _accumulatedBytes.clear();

        final wavBytes = _addWavHeader(pcmBytes, 44100);
        _processAndPlayLiveBytes(wavBytes, _selectedEffect);
      });
    } catch (e) {
      print('Error in live stream: $e');
      setState(() {
        _errorMessage = 'Failed to start live stream: $e';
        _isLiveModulating = false;
      });
      _stopRecording();
    }
  }

  Future<void> _processAndPlayLiveBytes(
    Uint8List wavBytes,
    String effectId,
  ) async {
    try {
      final String base64Audio = base64Encode(wavBytes);

      final response = await _httpClient
          .post(
            Uri.parse('$_backendUrl/process'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'audio': base64Audio,
              'effect': effectId,
              'sample_rate': 44100,
            }),
          )
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = jsonDecode(response.body);
        if (responseData.containsKey('error')) return;

        final String base64Processed = responseData['audio'];
        final Uint8List processedWavBytes = base64Decode(base64Processed);

        if (!_isLiveModulating) return;

        final currentPlayer = _useLivePlayer1 ? _livePlayer1 : _livePlayer2;
        _useLivePlayer1 = !_useLivePlayer1;

        if (kIsWeb) {
          await currentPlayer.play(
            BytesSource(processedWavBytes, mimeType: 'audio/wav'),
          );
        } else {
          final tempDir = await getTemporaryDirectory();
          final chunkFile = File(
            '${tempDir.path}/live_processed_${_useLivePlayer1 ? 1 : 2}.wav',
          );
          await chunkFile.writeAsBytes(processedWavBytes);
          await currentPlayer.play(DeviceFileSource(chunkFile.path));
        }
      }
    } catch (e) {
      print('Error processing live chunk: $e');
    }
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    _amplitudeTimer?.cancel();
    _liveChunkTimer?.cancel();
    _recordSub?.cancel();

    if (_isLiveModulating) {
      setState(() {
        _isLiveModulating = false;
      });
      await _recorder.stop();
      _livePlayer1.stop();
      _livePlayer2.stop();
      return;
    }

    try {
      final path = await _recorder.stop();
      setState(() {
        _isRecording = false;
      });

      if (path != null) {
        if (kIsWeb) {
          setState(() {
            _originalWavPath = path;
          });
          await _originalPlayer.setSource(UrlSource(path));
        } else {
          if (File(path).existsSync()) {
            setState(() {
              _originalWavPath = path;
            });

            // Set player source
            await _originalPlayer.setSource(DeviceFileSource(path));
          }
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error saving recording: $e';
      });
    }
  }

  Future<void> _playOriginal() async {
    if (_originalWavPath == null) return;
    try {
      if (_isOriginalPlaying) {
        await _originalPlayer.pause();
      } else {
        await _processedPlayer.stop(); // Stop processed playback first
        if (kIsWeb) {
          await _originalPlayer.play(UrlSource(_originalWavPath!));
        } else {
          await _originalPlayer.play(DeviceFileSource(_originalWavPath!));
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Playback error: $e';
      });
    }
  }

  Future<void> _applyEffect(String effectId) async {
    if (_rawRecordingPath == null || _isRecording) return;

    setState(() {
      _selectedEffect = effectId;
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      // 1. Read raw PCM audio
      final Uint8List rawBytes;
      if (kIsWeb) {
        rawBytes = await _httpClient.readBytes(Uri.parse(_originalWavPath!));
      } else {
        final File rawFile = File(_rawRecordingPath!);
        rawBytes = await rawFile.readAsBytes();
      }
      final String base64Audio = base64Encode(rawBytes);

      // 2. HTTP POST Request
      final response = await _httpClient
          .post(
            Uri.parse('$_backendUrl/process'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'audio': base64Audio,
              'effect': effectId,
              'sample_rate': 44100,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = jsonDecode(response.body);
        if (responseData.containsKey('error')) {
          throw Exception(responseData['error']);
        }

        final String base64Processed = responseData['audio'];
        final Uint8List processedWavBytes = base64Decode(base64Processed);

        setState(() {
          _processedWavBytes = processedWavBytes;
        });

        if (kIsWeb) {
          setState(() {
            _processedWavPath = 'processed_${effectId}.wav';
            _isProcessing = false;
          });
          await _originalPlayer.stop(); // Stop original playback
          await _processedPlayer.play(
            BytesSource(processedWavBytes, mimeType: 'audio/wav'),
          );
        } else {
          // 3. Save processed WAV
          final tempDir = await getTemporaryDirectory();
          final processedFile = File(
            '${tempDir.path}/processed_${effectId}.wav',
          );
          await processedFile.writeAsBytes(processedWavBytes);

          setState(() {
            _processedWavPath = processedFile.path;
            _isProcessing = false;
          });

          // 4. Play it!
          await _originalPlayer.stop(); // Stop original playback
          await _processedPlayer.play(DeviceFileSource(_processedWavPath!));
        }
      } else {
        throw Exception('Server returned status code ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Connection or processing error: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _playProcessed() async {
    if (_processedWavPath == null) return;
    try {
      if (_isProcessedPlaying) {
        await _processedPlayer.pause();
      } else {
        await _originalPlayer.stop();
        if (kIsWeb) {
          if (_processedWavBytes != null) {
            await _processedPlayer.play(
              BytesSource(_processedWavBytes!, mimeType: 'audio/wav'),
            );
          }
        } else {
          await _processedPlayer.play(DeviceFileSource(_processedWavPath!));
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Playback error: $e';
      });
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  String _formatTime(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _saveBackendUrl() {
    setState(() {
      _backendUrl = _urlController.text.trim();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Backend URL set to $_backendUrl'),
        backgroundColor: const Color(0xFF8B5CF6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'VOICE CHANGER',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
            color: Colors.white,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Color(0xFF06B6D4)),
            onPressed: () {
              // Reload devices when opening settings
              _loadDevices();
              showModalBottomSheet(
                context: context,
                backgroundColor: const Color(0xFF1E1B33),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                builder: (context) {
                  return StatefulBuilder(
                    builder: (BuildContext context, StateSetter setModalState) {
                      return SingleChildScrollView(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Backend Configuration',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _urlController,
                              decoration: InputDecoration(
                                labelText: 'FastAPI URL',
                                labelStyle: const TextStyle(
                                  color: Color(0xFF06B6D4),
                                ),
                                hintText: 'e.g., http://127.0.0.1:8000',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(
                                    color: Color(0xFF8B5CF6),
                                    width: 2,
                                  ),
                                ),
                              ),
                              style: const TextStyle(color: Colors.white),
                            ),
                            const SizedBox(height: 24),
                            const Text(
                              'Audio Input Device',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0C091A),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(
                                    0xFF8B5CF6,
                                  ).withOpacity(0.3),
                                ),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String?>(
                                  value: _selectedInputDeviceId,
                                  dropdownColor: const Color(0xFF1E1B33),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
                                  isExpanded: true,
                                  items: [
                                    const DropdownMenuItem<String?>(
                                      value: null,
                                      child: Text('Default Microphone'),
                                    ),
                                    ..._inputDevices.map((device) {
                                      return DropdownMenuItem<String?>(
                                        value: device.id,
                                        child: Text(device.label),
                                      );
                                    }),
                                  ],
                                  onChanged: (val) {
                                    setModalState(() {
                                      _selectedInputDeviceId = val;
                                    });
                                    setState(() {
                                      _selectedInputDeviceId = val;
                                    });
                                  },
                                ),
                              ),
                            ),
                            if (!kIsWeb && Platform.isWindows) ...[
                              const SizedBox(height: 24),
                              const Text(
                                'Audio Output Device',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0C091A),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(
                                      0xFF8B5CF6,
                                    ).withOpacity(0.3),
                                  ),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String?>(
                                    value: _selectedOutputDeviceId,
                                    dropdownColor: const Color(0xFF1E1B33),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                    isExpanded: true,
                                    items: [
                                      const DropdownMenuItem<String?>(
                                        value: null,
                                        child: Text('Default Playback Device'),
                                      ),
                                      ..._outputDevices.map((device) {
                                        return DropdownMenuItem<String?>(
                                          value: device['id'],
                                          child: Text(device['name']!),
                                        );
                                      }),
                                    ],
                                    onChanged: (val) async {
                                      setModalState(() {
                                        _selectedOutputDeviceId = val;
                                      });
                                      setState(() {
                                        _selectedOutputDeviceId = val;
                                      });
                                      if (val != null) {
                                        await selectOutputDevice(val);
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 32),
                            ElevatedButton(
                              onPressed: () {
                                _saveBackendUrl();
                                Navigator.pop(context);
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF8B5CF6),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                'Save & Close',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.6),
            radius: 1.2,
            colors: [Color(0xFF241544), Color(0xFF0C091A)],
          ),
        ),
        child: Column(
          children: [
            // Error Message
            if (_errorMessage != null)
              Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.2),
                  border: Border.all(color: Colors.redAccent),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),

            // Top Visualizer Panel
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isCurrentlyRecording) ...[
                    AnimatedBuilder(
                      animation: _pulseController,
                      builder: (context, child) {
                        return Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(
                                0xFFFF0055,
                              ).withOpacity(1.0 - _pulseController.value),
                              width: 6 * _pulseController.value,
                            ),
                          ),
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFFFF0055),
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _formatTime(_recordingSeconds),
                      style: const TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w300,
                        color: Colors.white,
                        letterSpacing: 2,
                      ),
                    ),
                    Text(
                      _isLiveModulating
                          ? 'LIVE VOICE CHANGING'
                          : 'RECORDING LIVE VOICE',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _isLiveModulating
                            ? const Color(0xFF06B6D4)
                            : const Color(0xFFFF0055),
                        letterSpacing: 1.5,
                      ),
                    ),
                  ] else if (_originalWavPath != null) ...[
                    // Playback Panel for original voice
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 32),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1B33).withOpacity(0.6),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFF8B5CF6).withOpacity(0.3),
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              IconButton(
                                icon: Icon(
                                  _isOriginalPlaying
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_filled,
                                  size: 44,
                                  color: const Color(0xFF8B5CF6),
                                ),
                                onPressed: _playOriginal,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Your Recorded Voice',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          _formatDuration(_originalPosition),
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                        Text(
                                          _formatDuration(_originalDuration),
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ],
                                    ),
                                    SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 3,
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 6,
                                        ),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                              overlayRadius: 14,
                                            ),
                                        activeTrackColor: const Color(
                                          0xFF8B5CF6,
                                        ),
                                        inactiveTrackColor: Colors.white24,
                                        thumbColor: const Color(0xFF8B5CF6),
                                      ),
                                      child: Slider(
                                        value: _originalPosition.inMilliseconds
                                            .toDouble(),
                                        max:
                                            _originalDuration.inMilliseconds > 0
                                            ? _originalDuration.inMilliseconds
                                                  .toDouble()
                                            : 1.0,
                                        onChanged: (val) {
                                          _originalPlayer.seek(
                                            Duration(milliseconds: val.toInt()),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    // Static Visualizer placeholder / instructions
                    const Text('🎙️', style: TextStyle(fontSize: 64)),
                    const SizedBox(height: 16),
                    const Text(
                      'TAP THE BUTTON TO RECORD',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF06B6D4),
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  // Amplitude Visualizer Bars
                  SizedBox(
                    height: 50,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: _waveAmplitudes.map((amp) {
                        return Container(
                          width: 4,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: _isCurrentlyRecording
                                ? (_isLiveModulating
                                      ? const Color(0xFF06B6D4)
                                      : const Color(0xFFFF0055))
                                : const Color(0xFF06B6D4),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          height: 50 * amp,
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),

            // Middle processed audio panel
            if (_processedWavPath != null && !_isCurrentlyRecording) ...[
              Container(
                margin: const EdgeInsets.only(left: 32, right: 32, bottom: 20),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF8B5CF6), Color(0xFF06B6D4)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF06B6D4).withOpacity(0.4),
                      blurRadius: 15,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _isProcessedPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        size: 48,
                        color: Colors.white,
                      ),
                      onPressed: _playProcessed,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Processed: ${_effects.firstWhere((e) => e['id'] == _selectedEffect)['name']}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(_processedPosition),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                              Text(
                                _formatDuration(_processedDuration),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              activeTrackColor: Colors.white,
                              inactiveTrackColor: Colors.white38,
                              thumbColor: Colors.white,
                            ),
                            child: Slider(
                              value: _processedPosition.inMilliseconds
                                  .toDouble(),
                              max: _processedDuration.inMilliseconds > 0
                                  ? _processedDuration.inMilliseconds.toDouble()
                                  : 1.0,
                              onChanged: (val) {
                                _processedPlayer.seek(
                                  Duration(milliseconds: val.toInt()),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Bottom Panel: Record Button & Effects
            Expanded(
              flex: 5,
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFF131026),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                padding: const EdgeInsets.only(
                  top: 24,
                  left: 16,
                  right: 16,
                  bottom: 16,
                ),
                child: Column(
                  children: [
                    // Live Mode Switch Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.bolt,
                          color: Color(0xFF06B6D4),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'LIVE VOICE CHANGER',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            letterSpacing: 1.2,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Switch(
                          value: _isLiveMode,
                          onChanged: (val) {
                            if (_isCurrentlyRecording) return;
                            setState(() {
                              _isLiveMode = val;
                            });
                          },
                          activeColor: const Color(0xFF06B6D4),
                          activeTrackColor: const Color(
                            0xFF06B6D4,
                          ).withOpacity(0.3),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Large pulsing Record Button
                    GestureDetector(
                      onTap: _toggleRecording,
                      child: Container(
                        height: 76,
                        width: 76,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isCurrentlyRecording
                              ? (_isLiveModulating
                                    ? const Color(0xFF06B6D4)
                                    : const Color(0xFFFF0055))
                              : const Color(0xFF8B5CF6),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  (_isCurrentlyRecording
                                          ? (_isLiveModulating
                                                ? const Color(0xFF06B6D4)
                                                : const Color(0xFFFF0055))
                                          : const Color(0xFF8B5CF6))
                                      .withOpacity(0.5),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Icon(
                          _isCurrentlyRecording ? Icons.stop : Icons.mic,
                          size: 38,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Grid Label
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8.0,
                          vertical: 4.0,
                        ),
                        child: Text(
                          'TAP TO APPLY EFFECT',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                            color: Colors.white60,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Grid of Effects
                    Expanded(
                      child: Stack(
                        children: [
                          GridView.builder(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  childAspectRatio: 1.1,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                ),
                            itemCount: _effects.length,
                            itemBuilder: (context, index) {
                              final item = _effects[index];
                              final isSelected = _selectedEffect == item['id'];
                              final hasVoice =
                                  _rawRecordingPath != null &&
                                  !_isCurrentlyRecording;

                              return InkWell(
                                onTap: (hasVoice || _isLiveModulating)
                                    ? () {
                                        if (_isLiveModulating) {
                                          setState(() {
                                            _selectedEffect = item['id'];
                                          });
                                        } else {
                                          _applyEffect(item['id']);
                                        }
                                      }
                                    : () {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Please record a voice clip first!',
                                            ),
                                            duration: Duration(seconds: 2),
                                          ),
                                        );
                                      },
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? const Color(
                                            0xFF8B5CF6,
                                          ).withOpacity(0.2)
                                        : const Color(0xFF1E1B33),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: isSelected
                                          ? const Color(0xFF8B5CF6)
                                          : const Color(
                                              0xFF8B5CF6,
                                            ).withOpacity(0.1),
                                      width: isSelected ? 2 : 1,
                                    ),
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        item['icon'],
                                        style: const TextStyle(fontSize: 28),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        item['name'],
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: isSelected
                                              ? const Color(0xFF8B5CF6)
                                              : Colors.white,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        item['desc'],
                                        style: const TextStyle(
                                          color: Colors.white38,
                                          fontSize: 10,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),

                          // Processing Spinner Overlay
                          if (_isProcessing)
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    CircularProgressIndicator(
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Color(0xFF06B6D4),
                                      ),
                                    ),
                                    SizedBox(height: 16),
                                    Text(
                                      'Applying effect via FastAPI...',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
