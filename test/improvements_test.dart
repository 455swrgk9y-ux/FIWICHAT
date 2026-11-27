import 'dart:async';
import 'dart:convert';

import 'package:fiwichat/crypto.dart';
import 'package:fiwichat/mesh.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

class MemLink implements Link {
  MemLink(this.key, this.target, this.fromKey);
  @override
  final String key;
  final MeshNode target;
  final String fromKey;
  bool cut = false;
  @override
  String get kind => 'proche';
  @override
  void send(String frame) {
    if (cut) return;
    scheduleMicrotask(() => target.receive(frame, fromKey));
  }
}

Future<void> settle() => Future.delayed(const Duration(milliseconds: 50));

(MemLink, MemLink) connect(MeshNode a, String an, MeshNode b, String bn) {
  final ab = MemLink('to-$bn', b, 'to-$an'),
      ba = MemLink('to-$an', a, 'to-$bn');
  a.addLink(ab);
  b.addLink(ba);
  return (ab, ba);
}

void main() {
  late MeshNode a, b, c;
  setUp(() async {
    a = MeshNode(me: Identity.generate(), myName: 'Alice');
    b = MeshNode(me: Identity.generate(), myName: 'Bob');
    c = MeshNode(me: Identity.generate(), myName: 'Chloé');
  });
  tearDown(() {
    for (final n in [a, b, c]) {
      n.stop();
    }
  });

  test(
    'un message privé est renvoyé tout seul quand la personne revient',
    () async {
      connect(a, 'A', b, 'B');
      final (bc, cb) = connect(b, 'B', c, 'C');
      await settle();
      expect(a.people[c.myId]?.encId, isNotNull);
      // Chloé s'éloigne.
      bc.cut = true;
      cb.cut = true;
      b.removeLink(bc.key);
      c.removeLink(cb.key);
      a.send(c.myId, 'Tu es là ?');
      await settle();
      expect(c.conversations[a.myId], isNull);
      final msg = a.conversations[c.myId]!.single;
      expect(msg.delivered, isFalse);
      // Alice ne la voit plus depuis un moment.
      a.people[c.myId]!.lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
      // Chloé revient : sa présence déclenche le renvoi.
      connect(b, 'B', c, 'C');
      await settle();
      await settle();
      expect(c.conversations[a.myId]!.single.text, 'Tu es là ?');
      expect(msg.delivered, isTrue);
      // Un second retour ne crée pas de doublon.
      a.people[c.myId]!.lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
      expect(a.resendPending(c.myId), 0); // déjà reçu
      expect(c.conversations[a.myId]!.length, 1);
    },
  );

  test('effacer un message ou vider une conversation', () async {
    connect(a, 'A', b, 'B');
    await settle();
    a.send(kGroupId, 'un');
    a.send(kGroupId, 'deux');
    a.send(b.myId, 'privé');
    await settle();
    final g = a.conversations[kGroupId]!;
    a.deleteMessage(kGroupId, g.first);
    expect(a.conversations[kGroupId]!.map((m) => m.text), ['deux']);
    // Chez Bob, rien n'est effacé.
    expect(b.conversations[kGroupId]!.length, 2);
    a.clearConversation(b.myId);
    expect(a.conversations[b.myId], isEmpty);
    expect(jsonDecode(a.exportState())['convos'][b.myId], isEmpty);
  });

  test('économie de batterie : on peut passer en arrière-plan et revenir', () {
    a.start();
    a.setBackground(true);
    expect(a.inBackground, isTrue);
    a.setBackground(false);
    expect(a.inBackground, isFalse);
  });

  group('sécurité', () {
    test('la clé de chiffrement change chaque jour, les messages en route passent encore', () async {
      connect(a, 'A', b, 'B');
      await settle();
      final oldEnc = a.me.encId;
      final oldSecret = a.me.secretBase64;
      var saved = 0;
      a.onIdentityChanged = () => saved++;
      expect(a.rotateKeyIfNeeded(), isFalse);
      final tomorrow = DateTime.now().add(const Duration(hours: 25));
      expect(a.rotateKeyIfNeeded(tomorrow), isTrue);
      expect(saved, 1);
      expect(a.me.encId, isNot(oldEnc));
      expect(a.me.id, Identity.fromBase64(oldSecret).id, reason: 'même code');

      // Un message chiffré avec l'ancienne clé (en route) s'ouvre encore.
      final sealed = sealPrivate(
        me: b.me,
        myName: 'Bob',
        recipientId: a.myId,
        recipientEncId: oldEnc,
        text: 'en route',
        ts: DateTime.now().millisecondsSinceEpoch,
        mid: 'm1',
      );
      expect(openPrivate(a.me, sealed['e']!, sealed['c']!)?.text, 'en route');

      // Bob apprend la nouvelle clé dès la prochaine annonce.
      a.rename('Alice');
      await settle();
      expect(b.people[a.myId]!.encId, a.me.encId);

      // Après 4 jours, l'ancienne clé est effacée pour toujours.
      var t = tomorrow;
      for (var i = 0; i < 3; i++) {
        t = t.add(const Duration(hours: 25));
        a.rotateKeyIfNeeded(t);
      }
      expect(a.me.previous.length, Identity.keepOld);
      expect(openPrivate(a.me, sealed['e']!, sealed['c']!), isNull);

      // Sauvegarde : tout se relit, ancien format compris.
      final back = Identity.fromBase64(a.me.secretBase64);
      expect(back.encId, a.me.encId);
      expect(back.previous.length, Identity.keepOld);
      expect(back.encSince, a.me.encSince);
      final legacy = Identity.generate();
      final legacyStr = legacy.secretBase64.split('|').first;
      final l2 = Identity.fromBase64(legacyStr);
      expect(l2.id, legacy.id);
      expect(
        l2.needsRotation(),
        isTrue,
        reason: 'ancienne clé : on la change tout de suite',
      );
    });

    test('anti-spam par personne : un bavard est freiné même par plusieurs chemins', () async {
      final spam = Identity.generate();
      var i = 0;
      for (final via in ['v1', 'v2', 'v3']) {
        for (var k = 0; k < 20; k++) {
          a.receive(signedGrp(spam, 'Spam', 'pub ${i++}', id: 's$i'), via);
        }
      }
      final got = a.conversations[kGroupId]!
          .where((m) => m.fromId == spam.id)
          .length;
      expect(got, lessThanOrEqualTo(21));
      expect(got, greaterThanOrEqualTo(18));
      // Les autres personnes passent toujours.
      a.receive(signedGrp(b.me, 'Bob', 'normal', id: 'n1'), 'v1');
      expect(a.conversations[kGroupId]!.last.text, 'normal');
    });

    test(
      'de faux paquets au nom de quelqu\'un ne lui font pas perdre son crédit',
      () async {
        final victim = Identity.generate(), attacker = Identity.generate();
        for (var k = 0; k < 50; k++) {
          // Signé par l'attaquant mais au nom de la victime : rejeté, sans rien compter.
          final p = jsonDecode(
            signedGrp(attacker, 'X', 'faux $k', id: 'f$k'),
          ) as Map<String, dynamic>;
          p['src'] = victim.id;
          a.receive(jsonEncode(p), 'v$k');
        }
        for (var k = 0; k < 5; k++) {
          a.receive(signedGrp(victim, 'Vic', 'vrai $k', id: 'ok$k'), 'w');
        }
        expect(
          a.conversations[kGroupId]!.where((m) => m.fromId == victim.id).length,
          5,
        );
      },
    );
  });
}
