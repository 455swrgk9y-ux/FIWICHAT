import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fiwichat/crypto.dart';
import 'package:fiwichat/media.dart';
import 'package:fiwichat/mesh.dart';
import 'package:flutter_test/flutter_test.dart';

/// Liaison en mémoire, qui peut « perdre » certains paquets.
class MemLink implements Link {
  MemLink(this.key, this.target, this.fromKey, this.log, {this.lose});
  @override
  final String key;
  final MeshNode target;
  final String fromKey;
  final List<String> log;
  final bool Function(String frame)? lose;
  @override
  String get kind => 'proche';
  @override
  void send(String frame) {
    log.add(frame);
    if (lose?.call(frame) ?? false) return;
    scheduleMicrotask(() => target.receive(frame, fromKey));
  }
}

Uint8List fakePhoto(int size) =>
    Uint8List.fromList(List.generate(size, (i) => (i * 31 + i ~/ 7) % 256));

void main() {
  late Map<String, MeshNode> nodes;
  late List<String> wire;
  late Directory tmp;
  const names = ['A', 'B', 'C', 'D'];
  final lost = <String>{}; // morceaux à perdre une fois, ex. "3"

  Future<void> waitFor(bool Function() ok, {int seconds = 20}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('trop long');
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  setUp(() async {
    wire = [];
    lost.clear();
    tmp = await Directory.systemTemp.createTemp('fiwi-media');
    nodes = {
      for (final n in names)
        n: MeshNode(me: Identity.generate(), myName: 'Nom$n'),
    };
    for (final n in names) {
      nodes[n]!.attachMedia(Directory('${tmp.path}/$n'));
    }
    bool lose(String f) {
      if (!f.startsWith('{"t":"fc"')) return false;
      final i = (jsonDecode(f) as Map)['i'].toString();
      return lost.remove(i);
    }

    // Chaîne A - B - C - D. Entre C et D, des morceaux peuvent se perdre.
    for (var i = 0; i < names.length - 1; i++) {
      final a = nodes[names[i]]!, b = nodes[names[i + 1]]!;
      final lossy = names[i] == 'C';
      a.addLink(
        MemLink(
          'to-${names[i + 1]}',
          b,
          'to-${names[i]}',
          wire,
          lose: lossy ? lose : null,
        ),
      );
      b.addLink(MemLink('to-${names[i]}', a, 'to-${names[i + 1]}', wire));
    }
    for (final n in nodes.values) {
      n.start();
    }
    await Future.delayed(const Duration(milliseconds: 50));
  });

  tearDown(() async {
    for (final n in nodes.values) {
      n.stop();
    }
    await tmp.delete(recursive: true);
  });

  test('chiffrement des fichiers : aller-retour, et refus si modifié', () {
    final key = Uint8List(32)..[0] = 7, nonce = Uint8List(24)..[1] = 9;
    final plain = fakePhoto(50000);
    final box = secretboxSeal(plain, nonce, key);
    expect(box.length, plain.length + 16);
    expect(secretboxOpen(box, nonce, key), plain);
    box[100] ^= 1;
    expect(secretboxOpen(box, nonce, key), isNull);
  });

  test('une photo du salon traverse les relais, intacte', () async {
    final a = nodes['A']!, d = nodes['D']!;
    final photo = fakePhoto(100000);
    expect(
      await a.sendMedia(
        kGroupId,
        photo,
        kind: 'photo',
        mime: 'image/jpeg',
        caption: 'Coucou',
      ),
      isTrue,
    );
    await waitFor(
      () =>
          d.conversations[kGroupId]!.isNotEmpty &&
          d.conversations[kGroupId]!.single.path != null,
    );
    final m = d.conversations[kGroupId]!.single;
    expect(m.text, 'Coucou');
    expect(m.media!.kind, 'photo');
    expect(await File(m.path!).readAsBytes(), photo);
    expect(m.progress, isNull);
    // Chez l'expéditeur, l'envoi est terminé.
    expect(a.conversations[kGroupId]!.single.progress, isNull);
  });

  test('une vidéo privée : seul le destinataire peut l\'ouvrir', () async {
    final a = nodes['A']!, d = nodes['D']!;
    final video = fakePhoto(60000);
    wire.clear();
    await a.sendMedia(d.myId, video, kind: 'video', mime: 'video/mp4');
    await waitFor(() => d.conversations[a.myId]?.single.path != null);
    expect(
      await File(d.conversations[a.myId]!.single.path!).readAsBytes(),
      video,
    );
    for (final r in ['B', 'C']) {
      final n = nodes[r]!;
      expect(
        n.conversations.keys.where((k) => k != kGroupId),
        isEmpty,
        reason: r,
      );
      final files = Directory('${tmp.path}/$r');
      expect(
        files.existsSync() ? files.listSync() : const [],
        isEmpty,
        reason: '$r ne garde aucun fichier',
      );
    }
    // Sur le réseau : ni la vidéo en clair, ni l'identité de A.
    final all = wire.join('\n');
    expect(all.contains(a.myId), isFalse);
    expect(all.contains(base64Encode(video.sublist(0, 30))), isFalse);
  });

  test('des morceaux perdus sont redemandés puis reçus', () async {
    final a = nodes['A']!, d = nodes['D']!;
    lost.addAll({'2', '5', '9'});
    final photo = fakePhoto(100000); // 12 morceaux
    await a.sendMedia(kGroupId, photo, kind: 'photo', mime: 'image/jpeg');
    await Future.delayed(const Duration(milliseconds: 300));
    final m = d.conversations[kGroupId]!.single;
    expect(m.path, isNull);
    expect(m.progress, closeTo(9 / 12, 0.01));
    // Plus rien n'arrive : D redemande ce qui manque.
    d.media!.tick(at: DateTime.now().add(const Duration(seconds: 7)));
    await waitFor(() => m.path != null);
    expect(await File(m.path!).readAsBytes(), photo);
  });

  test('un faux morceau est refusé et pas relayé', () async {
    final a = nodes['A']!, b = nodes['B']!;
    await a.sendMedia(
      kGroupId,
      fakePhoto(20000),
      kind: 'photo',
      mime: 'image/jpeg',
    );
    final fid = a.conversations[kGroupId]!.single.media!.fid;
    // On attend que les vrais morceaux ne soient plus « récents ».
    await Future.delayed(const Duration(milliseconds: 3200));
    final before = wire.length;
    final fake = jsonEncode({
      't': 'fc',
      'id': 'faux1',
      'h': 0,
      'f': fid,
      'i': 0,
      'd': base64Encode(Uint8List(500)),
    });
    b.receive(fake, 'to-A');
    await Future.delayed(const Duration(milliseconds: 100));
    expect(
      wire.length,
      before,
      reason: 'B ne doit pas relayer un faux morceau',
    );
  });

  test('un message vocal privé arrive avec sa durée', () async {
    final a = nodes['A']!, d = nodes['D']!;
    final voice = fakePhoto(40000);
    await a.sendMedia(
      d.myId,
      voice,
      kind: 'audio',
      mime: 'audio/mp4',
      durationMs: 12500,
    );
    await waitFor(() => d.conversations[a.myId]?.single.path != null);
    final m = d.conversations[a.myId]!.single;
    expect(m.media!.isAudio, isTrue);
    expect(m.media!.durationMs, 12500);
    expect(m.path, endsWith('.m4a'));
    expect(await File(m.path!).readAsBytes(), voice);
  });

  test('une durée fausse rend la description invalide', () {
    final ok = {
      'f': 'x',
      'k': 'audio',
      't': 'audio/mp4',
      's': 10,
      'n': 1,
      'key': base64Encode(Uint8List(32)),
      'no': base64Encode(Uint8List(24)),
      'hs': 'AAAAAAAA',
    };
    expect(MediaMeta.fromJson(ok), isNotNull);
    expect(MediaMeta.fromJson({...ok, 'ms': -5}), isNull);
    expect(MediaMeta.fromJson({...ok, 'k': 'virus'}), isNull);
  });

  test('trop lourd : refusé tout de suite', () async {
    final ok = await nodes['A']!.sendMedia(
      kGroupId,
      Uint8List(kMaxMediaBytes + 1),
      kind: 'video',
      mime: 'video/mp4',
    );
    expect(ok, isFalse);
  });

  test('les photos restent après un redémarrage', () async {
    final a = nodes['A']!, d = nodes['D']!;
    final photo = fakePhoto(30000);
    await a.sendMedia(kGroupId, photo, kind: 'photo', mime: 'image/png');
    await waitFor(() => d.conversations[kGroupId]!.single.path != null);
    final saved = d.exportState();
    final d2 = MeshNode(me: d.me, myName: 'NomD')..importState(saved);
    d2.attachMedia(Directory('${tmp.path}/D'));
    final m = d2.conversations[kGroupId]!.single;
    expect(m.media!.mime, 'image/png');
    expect(await File(m.path!).readAsBytes(), photo);
    d2.stop();
  });
}
