// FIWICHAT - messages vocaux : enregistrer sa voix, l'envoyer comme une photo, l'écouter.
// Le son est compressé (AAC mono, 32 kbit/s) : 2 minutes ≈ 480 Ko.
import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

import 'mesh.dart';

const Duration kMaxVoice = Duration(minutes: 2);

String clock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Enregistre un message vocal dans un fichier temporaire.
class VoiceRecorder {
  AudioRecorder? _rec;
  String? _path;
  DateTime? started;

  bool get recording => started != null;
  Duration get elapsed =>
      started == null ? Duration.zero : DateTime.now().difference(started!);

  /// Démarre. Renvoie false si le micro n'est pas autorisé.
  Future<bool> start() async {
    final rec = _rec ??= AudioRecorder();
    if (!await rec.hasPermission()) return false;
    _path =
        '${Directory.systemTemp.path}/vocal_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await rec.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 32000,
        sampleRate: 22050,
        numChannels: 1,
        noiseSuppress: true,
        echoCancel: true,
      ),
      path: _path!,
    );
    started = DateTime.now();
    return true;
  }

  /// Arrête et renvoie le fichier et sa durée (null si trop court ou raté).
  Future<(File, Duration)?> stop() async {
    final d = elapsed;
    started = null;
    final path = await _rec?.stop() ?? _path;
    if (path == null || d < const Duration(milliseconds: 700)) return null;
    final f = File(path);
    return f.existsSync() && f.lengthSync() > 0 ? (f, d) : null;
  }

  Future<void> cancel() async {
    started = null;
    try {
      await _rec?.cancel();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await cancel();
    await _rec?.dispose();
  }
}

/// Un seul lecteur pour toute l'appli : lancer un vocal arrête le précédent.
class VoicePlayback {
  VoicePlayback._();
  static final instance = VoicePlayback._();

  AudioPlayer? _player;
  final current = ValueNotifier<String?>(null);
  final playing = ValueNotifier<bool>(false);
  final position = ValueNotifier<Duration>(Duration.zero);
  final duration = ValueNotifier<Duration>(Duration.zero);

  AudioPlayer get _p {
    final existing = _player;
    if (existing != null) return existing;
    final p = AudioPlayer();
    p.onPlayerStateChanged.listen(
      (s) => playing.value = s == PlayerState.playing,
    );
    p.onPositionChanged.listen((d) => position.value = d);
    p.onDurationChanged.listen((d) => duration.value = d);
    p.onPlayerComplete.listen((_) {
      playing.value = false;
      position.value = Duration.zero;
    });
    return _player = p;
  }

  Future<void> toggle(String path) async {
    try {
      if (current.value == path && playing.value) {
        await _p.pause();
      } else if (current.value == path) {
        await _p.resume();
      } else {
        current.value = path;
        position.value = Duration.zero;
        duration.value = Duration.zero;
        await _p.play(DeviceFileSource(path));
      }
    } catch (_) {
      playing.value = false;
    }
  }
}

/// Bulle d'un message vocal : bouton lecture / pause, barre et durée.
class VoiceBubble extends StatelessWidget {
  const VoiceBubble({super.key, required this.message, required this.ready});
  final ChatMessage message;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final m = message.media!;
    final scheme = Theme.of(context).colorScheme;
    final total = Duration(milliseconds: m.durationMs ?? 0);
    if (!ready) {
      final p = message.progress;
      return SizedBox(
        width: 230,
        child: Row(
          children: [
            Icon(Icons.mic, size: 32, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p == null
                        ? 'Message vocal en attente…'
                        : 'Réception du vocal · ${(p * 100).round()} %',
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: p),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final vp = VoicePlayback.instance;
    final path = message.path!;
    return ListenableBuilder(
      listenable: Listenable.merge([
        vp.current,
        vp.playing,
        vp.position,
        vp.duration,
      ]),
      builder: (context, _) {
        final mine = vp.current.value == path;
        final isPlaying = mine && vp.playing.value;
        final dur = mine && vp.duration.value > Duration.zero
            ? vp.duration.value
            : total;
        final pos = mine ? vp.position.value : Duration.zero;
        final frac = dur.inMilliseconds == 0
            ? 0.0
            : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
        return SizedBox(
          width: 230,
          child: Row(
            children: [
              IconButton.filled(
                key: Key('play-${m.fid}'),
                onPressed: () => vp.toggle(path),
                icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: frac, minHeight: 5),
                    const SizedBox(height: 6),
                    Text(
                      mine && pos > Duration.zero
                          ? '${clock(pos)} / ${clock(dur)}'
                          : 'Vocal · ${clock(dur)}',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
