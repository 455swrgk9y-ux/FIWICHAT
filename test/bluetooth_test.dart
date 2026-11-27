import 'dart:async';

import 'package:fiwichat/crypto.dart';
import 'package:fiwichat/mesh.dart';
import 'package:fiwichat/radios.dart';
import 'package:fiwichat/transport_nearby.dart';
import 'package:flutter_test/flutter_test.dart';

class MemLink implements Link {
  MemLink(this.key, this.target, this.fromKey);
  @override
  final String key;
  final MeshNode target;
  final String fromKey;
  @override
  String get kind => 'proche';
  @override
  void send(String frame) =>
      scheduleMicrotask(() => target.receive(frame, fromKey));
}

Future<void> settle([int ms = 50]) =>
    Future.delayed(Duration(milliseconds: ms));

void main() {
  test('deux téléphones qui se trouvent : un seul appelle l\'autre', () {
    for (var i = 0; i < 50; i++) {
      final a = NearbyTransport(MeshNode(me: Identity.generate(), myName: 'A'))
          .token;
      final b = NearbyTransport(MeshNode(me: Identity.generate(), myName: 'B'))
          .token;
      if (a == b) continue;
      final aCalls = shouldInitiate(a, nearbyName(b));
      final bCalls = shouldInitiate(b, nearbyName(a));
      expect(
        aCalls != bCalls,
        isTrue,
        reason: 'exactement un des deux appelle',
      );
    }
    // Un ancien FIWICHAT (nom "fiwichat") : on l'appelle toujours.
    expect(shouldInitiate('abc', 'fiwichat'), isTrue);
  });

  test(
    'Wi-Fi éteint mais Bluetooth allumé : pas d\'alerte, le Bluetooth suffit',
    () {
      final r = RadioStatus.fromMap({
        'hasBluetooth': true,
        'bluetoothOn': true,
        'wifiOn': false,
        'locationOn': true,
      });
      expect(r.off, isEmpty);
      expect(r.nearbyReady, isTrue);
      final both = RadioStatus.fromMap({
        'hasBluetooth': true,
        'bluetoothOn': false,
        'wifiOn': false,
        'locationOn': true,
      });
      expect(both.off, ['bluetooth', 'wifi']);
    },
  );

  test('message écrit sans personne à portée : il part dès qu\'un chemin Bluetooth apparaît', () async {
    final a = MeshNode(me: Identity.generate(), myName: 'Alice');
    final b = MeshNode(me: Identity.generate(), myName: 'Bob');
    // Ils se sont déjà vus (Bob est connu d'Alice), puis le Wi-Fi a été coupé.
    a.people[b.myId] = Person(b.myId, 'Bob')..encId = b.me.encId;
    a.send(kGroupId, 'salut le salon');
    a.send(b.myId, 'salut Bob');
    expect(a.conversations[kGroupId]!.single.failed, isTrue);
    expect(a.conversations[b.myId]!.single.failed, isTrue);
    // Le Bluetooth relie les deux téléphones.
    a.addLink(MemLink('nb:1', b, 'nb:2'));
    b.addLink(MemLink('nb:2', a, 'nb:1'));
    await settle(500);
    expect(b.conversations[kGroupId]!.single.text, 'salut le salon');
    expect(b.conversations[a.myId]!.single.text, 'salut Bob');
    expect(a.conversations[kGroupId]!.single.failed, isFalse);
    expect(a.conversations[b.myId]!.single.delivered, isTrue);
    // Une autre liaison plus tard ne crée pas de doublon.
    a.addLink(MemLink('lan:x', b, 'lan:y'));
    await settle(500);
    expect(b.conversations[kGroupId]!.length, 1);
    expect(b.conversations[a.myId]!.length, 1);
  });
}
