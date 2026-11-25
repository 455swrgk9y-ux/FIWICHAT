import 'dart:convert';

import 'package:fiwichat/crypto.dart';
import 'package:fiwichat/mesh.dart';

/// Fabrique des paquets signés comme le ferait un vrai téléphone.
String signedAnn(Identity who, String name, {String id = 'a1', bool guest = false, int? ts}) {
  final p = <String, dynamic>{
    't': 'ann',
    'id': id,
    'h': 0,
    'src': who.id,
    'x': who.encId,
    'name': name,
    if (guest) 'guest': true,
    'ts': ts ?? DateTime.now().millisecondsSinceEpoch,
  };
  p['sig'] = who.sign(MeshNode.annFields(p));
  return jsonEncode(p);
}

String signedGrp(Identity who, String name, String text, {String id = 'g1', int? ts}) {
  final p = <String, dynamic>{
    't': 'grp',
    'id': id,
    'h': 0,
    'src': who.id,
    'name': name,
    'text': text,
    'ts': ts ?? DateTime.now().millisecondsSinceEpoch,
  };
  p['sig'] = who.sign(MeshNode.grpFields(p));
  return jsonEncode(p);
}
