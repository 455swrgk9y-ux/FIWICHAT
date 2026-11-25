import 'dart:async';
import 'dart:convert';

import 'package:fiwichat/crypto.dart';
import 'package:fiwichat/mesh.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Liaison en mémoire entre deux téléphones simulés.
class MemLink implements Link {
  MemLink(this.key, this.target, this.fromKey, this.log);
  @override
  final String key;
  final MeshNode target;
  final String fromKey;
  final List<String> log;
  @override
  String get kind => 'proche';
  @override
  void send(String frame) {
    log.add(frame);
    scheduleMicrotask(() => target.receive(frame, fromKey));
  }
}

void main() {
  late Map<String, MeshNode> nodes;
  late Map<String, List<IncomingNotice>> notices;
  late List<String> wire;
  const names = ['A', 'B', 'C', 'D', 'E', 'F', 'G'];

  Future<void> settle() => Future.delayed(const Duration(milliseconds: 50));

  setUp(() async {
    wire = [];
    nodes = {for (final n in names) n: MeshNode(me: Identity.generate(), myName: 'Nom$n')};
    notices = {for (final n in names) n: []};
    nodes.forEach((n, node) => node.notices.listen(notices[n]!.add));
    // Chaîne A - B - C - D - E - F - G : A et G ne se touchent pas.
    for (var i = 0; i < names.length - 1; i++) {
      final a = nodes[names[i]]!, b = nodes[names[i + 1]]!;
      a.addLink(MemLink('to-${names[i + 1]}', b, 'to-${names[i]}', wire));
      b.addLink(MemLink('to-${names[i]}', a, 'to-${names[i + 1]}', wire));
    }
    for (final n in nodes.values) {
      n.start();
    }
    await settle();
  });

  tearDown(() {
    for (final n in nodes.values) {
      n.stop();
    }
  });

  test('tout le monde se découvre à travers les relais', () {
    expect(nodes['A']!.people.values.map((p) => p.name).toSet(),
        {'NomB', 'NomC', 'NomD', 'NomE', 'NomF', 'NomG'});
    expect(nodes['G']!.people.containsKey(nodes['A']!.myId), isTrue);
  });

  test('un message privé de A arrive seulement chez G, invisible pour les relais', () async {
    final a = nodes['A']!, g = nodes['G']!;
    wire.clear();
    a.send(g.myId, 'Message secret pour G');
    await settle();

    expect(g.conversations[a.myId]!.single.text, 'Message secret pour G');
    expect(notices['G']!.single.body, 'Message secret pour G');
    for (final r in ['B', 'C', 'D', 'E', 'F']) {
      final n = nodes[r]!;
      expect(n.conversations.keys.where((k) => k != kGroupId), isEmpty, reason: r);
      expect(notices[r], isEmpty, reason: '$r ne doit recevoir aucune notification');
    }
    // Rien de lisible sur le réseau : ni le texte, ni les identités.
    final all = wire.join('\n');
    expect(all.contains('Message secret'), isFalse);
    expect(all.contains(a.myId), isFalse);
    expect(all.contains(g.myId), isFalse);
    expect(all.contains('NomA'), isFalse);
    // Accusé de réception revenu chez A.
    expect(a.conversations[g.myId]!.single.delivered, isTrue);
  });

  test('le salon général arrive chez tout le monde', () async {
    nodes['D']!.send(kGroupId, 'Bonjour à tous');
    await settle();
    for (final n in names.where((n) => n != 'D')) {
      expect(nodes[n]!.conversations[kGroupId]!.single.text, 'Bonjour à tous', reason: n);
    }
  });

  test('les paquets ne tournent pas en boucle', () async {
    // On referme la chaîne en anneau.
    final a = nodes['A']!, g = nodes['G']!;
    a.addLink(MemLink('to-G', g, 'to-A', wire));
    g.addLink(MemLink('to-A', a, 'to-G', wire));
    await settle();
    wire.clear();
    a.send(kGroupId, 'boucle ?');
    await settle();
    // Chaque téléphone envoie le paquet au plus une fois à chacun de ses 2 voisins.
    expect(wire.where((f) => f.contains('boucle')).length, lessThanOrEqualTo(14));
    expect(g.conversations[kGroupId]!.where((m) => m.text == 'boucle ?').length, 1);
  });

  test('un paquet modifié par un relais est rejeté', () {
    final a = nodes['A']!, g = nodes['G']!;
    final sealed = sealPrivate(
        me: a.me, myName: 'NomA', recipientId: g.myId, recipientEncId: g.me.encId, text: 'x', mid: '1');
    final c = base64Decode(sealed['c']!);
    c[c.length - 1] ^= 1;
    expect(openPrivate(g.me, sealed['e']!, base64Encode(c)), isNull);
    expect(openPrivate(g.me, sealed['e']!, sealed['c']!)!.text, 'x');
    expect(openPrivate(nodes['B']!.me, sealed['e']!, sealed['c']!), isNull);
  });

  test('deux personnes avec le même pseudo restent distinguées', () async {
    final b = nodes['B']!, c = nodes['C']!, a = nodes['A']!;
    c.rename('NomB');
    await settle();
    final twins = a.people.values.where((p) => p.name == 'NomB').toList();
    expect(twins.length, 2);
    expect(twins[0].tag, isNot(twins[1].tag));
    expect(twins.every(a.isDuplicate), isTrue);
    expect(b.nameUsedByOther('nomb'), isTrue);
    expect(a.nameUsedByOther('Personne'), isFalse);
    // Un message privé à "NomB" (C) n'arrive pas chez l'autre NomB (B).
    a.send(c.myId, 'pour C');
    await settle();
    expect(c.conversations[a.myId]!.single.text, 'pour C');
    expect(b.conversations.containsKey(a.myId), isFalse);
  });

  test('personne ne peut écrire au nom d\'un autre (signatures)', () async {
    final a = nodes['A']!, b = nodes['B']!;
    final pirate = Identity.generate();
    // Message du salon qui prétend venir de B mais signé par le pirate.
    final forged = jsonDecode(signedGrp(pirate, 'NomB', 'je suis B', id: 'f1')) as Map<String, dynamic>;
    forged['src'] = b.myId;
    a.receive(jsonEncode(forged), 'x');
    // Annonce qui veut renommer B.
    final ann = jsonDecode(signedAnn(pirate, 'Méchant', id: 'f2')) as Map<String, dynamic>;
    ann['src'] = b.myId;
    a.receive(jsonEncode(ann), 'x');
    // Texte modifié en route.
    final real = jsonDecode(signedGrp(b.me, 'NomB', 'vrai texte', id: 'f3')) as Map<String, dynamic>;
    real['text'] = 'texte modifié';
    a.receive(jsonEncode(real), 'x');
    await settle();
    expect(a.conversations[kGroupId], isEmpty);
    expect(a.people[b.myId]!.name, 'NomB');
  });

  test('un vieux message rejoué est ignoré', () async {
    final a = nodes['A']!;
    final c = nodes['C']!.me;
    final frame = signedGrp(c, 'NomC', 'une fois', id: 'r1');
    a.receive(frame, 'x');
    // Après un redémarrage, la mémoire des paquets vus est vide : on rejoue.
    final restarted = MeshNode(me: a.me, myName: 'NomA')..importState(a.exportState());
    restarted.receive(frame, 'x');
    expect(restarted.conversations[kGroupId]!.where((m) => m.text == 'une fois').length, 1);
    // Trop vieux (3 jours).
    final old = DateTime.now().subtract(const Duration(days: 3)).millisecondsSinceEpoch;
    a.receive(signedGrp(c, 'NomC', 'ancien', id: 'r2', ts: old), 'x');
    expect(a.conversations[kGroupId]!.any((m) => m.text == 'ancien'), isFalse);
    // Une vieille annonce ne peut pas remettre un ancien pseudo.
    a.receive(signedAnn(c, 'AncienNom', id: 'r3', ts: old), 'x');
    expect(a.people[c.id]!.name, 'NomC');
  });

  test('anti-spam : un voisin qui inonde est freiné', () async {
    final a = nodes['A']!;
    final spam = Identity.generate();
    for (var i = 0; i < 500; i++) {
      a.receive(signedGrp(spam, 'Spam', 'pub $i', id: 's$i'), 'spammeur');
    }
    expect(a.conversations[kGroupId]!.length, lessThan(80));
    expect(a.dropped, greaterThan(400));
    // Les autres voisins passent toujours.
    a.receive(signedGrp(nodes['C']!.me, 'NomC', 'normal', id: 'n1'), 'autre');
    expect(a.conversations[kGroupId]!.last.text, 'normal');
  });

  test('l\'historique se sauvegarde et se recharge', () async {
    final a = nodes['A']!;
    a.send(kGroupId, 'à garder');
    final copy = MeshNode(me: a.me, myName: 'NomA')..importState(a.exportState());
    expect(copy.conversations[kGroupId]!.last.text, 'à garder');
    expect(copy.people.length, a.people.length);
  });
}
