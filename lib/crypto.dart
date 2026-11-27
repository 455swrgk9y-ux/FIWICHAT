// FIWICHAT - sécurité (NaCl : Ed25519 pour signer, X25519 + XSalsa20-Poly1305 pour chiffrer).
//
// Chaque personne a deux clés :
//  * une clé de SIGNATURE (Ed25519) : c'est son identité. Son code (#4F2A9C) en vient.
//    Tout ce qu'elle envoie (présence, salon, privé) est signé : personne ne peut
//    écrire à sa place, ni changer son pseudo, ni rejouer ses messages.
//  * une clé de CHIFFREMENT (X25519), annoncée et signée par la première.
//
// Un message privé est signé, puis enfermé dans une enveloppe chiffrée avec une clé
// jetable, sans aucun nom dessus. Les relais ne voient ni l'expéditeur, ni le
// destinataire, ni le texte. Format identique à tweetnacl-js (page invité).
import 'dart:convert';

import 'package:pinenacl/ed25519.dart' as ed;
import 'package:pinenacl/x25519.dart';

Uint8List _rand(int n) => PineNaClUtils.randombytes(n);

class Identity {
  Identity(this.signing, this.encryption);

  factory Identity.generate() =>
      Identity(ed.SigningKey.generate(), PrivateKey.generate());

  /// Format sauvegardé : "graine-signature.clé-chiffrement" en base64.
  factory Identity.fromBase64(String s) {
    final parts = s.split('.');
    if (parts.length != 2) throw const FormatException('ancienne clé');
    return Identity(
      ed.SigningKey(seed: base64Decode(parts[0])),
      PrivateKey(base64Decode(parts[1])),
    );
  }

  final ed.SigningKey signing;
  final PrivateKey encryption;

  String get secretBase64 =>
      '${base64Encode(signing.seed.asTypedList)}.${base64Encode(encryption.asTypedList)}';

  /// Identifiant public = clé de signature (base64).
  String get id => base64Encode(signing.verifyKey.asTypedList);

  /// Clé publique de chiffrement (base64), annoncée aux autres.
  String get encId => base64Encode(encryption.publicKey.asTypedList);

  /// Signe une liste de valeurs (encodée en JSON, comme la page invité).
  String sign(List<Object?> fields) => base64Encode(
    signing.sign(utf8.encode(jsonEncode(fields))).signature.asTypedList,
  );
}

/// Vérifie qu'une liste de valeurs a bien été signée par [id].
bool verifySig(String id, List<Object?> fields, Object? sig) {
  try {
    if (sig is! String) return false;
    return ed.VerifyKey(base64Decode(id)).verify(
      signature: ed.Signature(base64Decode(sig)),
      message: utf8.encode(jsonEncode(fields)),
    );
  } catch (_) {
    return false;
  }
}

/// Empreinte complète à comparer en face à face, ex. "4F2A 9C1B 77E0 ...".
String fingerprint(String id) {
  try {
    final hex = base64Decode(id)
        .take(12)
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();
    return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)]
        .join(' ')
        .toUpperCase();
  } catch (_) {
    return '?';
  }
}

/// Petit code tiré de l'identité, ex. "4F2A9C".
/// Deux personnes peuvent avoir le même pseudo, pas le même code.
String shortTag(String id) {
  try {
    return base64Decode(id)
        .take(3)
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
  } catch (_) {
    return '??????';
  }
}

/// Contenu signé d'un message privé : le destinataire est dedans, donc un message
/// ne peut pas être ré-envoyé à quelqu'un d'autre.
/// [media] (photo/vidéo) n'est ajouté que s'il existe : les anciens messages restent valides.
List<Object?> dmFields(
  String from,
  String to,
  String? mid,
  String? text,
  String? ack,
  int ts, [
  Object? media,
]) => ['dm', from, to, mid, text, ack, ts, if (media != null) media];

/// Fabrique les champs "e" et "c" d'un paquet privé.
Map<String, String> sealPrivate({
  required Identity me,
  required String myName,
  required String recipientId,
  required String recipientEncId,
  String? text,
  int ts = 0,
  String? mid,
  String? ack,
  Map<String, dynamic>? media,
}) {
  final sig = me.sign(dmFields(me.id, recipientId, mid, text, ack, ts, media));
  final body = {
    'src': me.id,
    'name': myName,
    'to': recipientId,
    'mid': mid,
    'text': text,
    'ack': ack,
    'ts': ts,
    if (media != null) 'm': media,
    'sig': sig,
  };
  final ephemeral = PrivateKey.generate();
  final box = Box(
    myPrivateKey: ephemeral,
    theirPublicKey: PublicKey(base64Decode(recipientEncId)),
  );
  final sealed = box
      .encrypt(utf8.encode(jsonEncode(body)), nonce: _rand(24))
      .asTypedList;
  return {
    'e': base64Encode(ephemeral.publicKey.asTypedList),
    'c': base64Encode(sealed),
  };
}

class OpenedPrivate {
  OpenedPrivate(
    this.fromId,
    this.fromName,
    this.text,
    this.ts,
    this.mid,
    this.ack, [
    this.media,
  ]);
  final String fromId, fromName;
  final String? text, mid, ack;
  final int ts;

  /// Description d'une photo/vidéo jointe (non vérifiée ici), ou null.
  final Object? media;
}

/// Essaie d'ouvrir un message privé. Renvoie null s'il n'est pas pour moi,
/// s'il a été modifié, ou si la signature est fausse.
OpenedPrivate? openPrivate(Identity me, String e, String c) {
  try {
    final data = base64Decode(c);
    if (data.length < 24 + 16) return null;
    final box = Box(
      myPrivateKey: me.encryption,
      theirPublicKey: PublicKey(base64Decode(e)),
    );
    final plain = box.decrypt(EncryptedMessage.fromList(data));
    final b = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    final src = b['src'] as String;
    final ts = (b['ts'] as num).toInt();
    final mid = b['mid'] as String?,
        text = b['text'] as String?,
        ack = b['ack'] as String?;
    if (b['to'] != me.id) return null;
    final media = b['m'];
    if (!verifySig(
      src,
      dmFields(src, me.id, mid, text, ack, ts, media),
      b['sig'],
    ))
      return null;
    return OpenedPrivate(
      src,
      (b['name'] as String?) ?? '?',
      text,
      ts,
      mid,
      ack,
      media,
    );
  } catch (_) {
    return null;
  }
}
