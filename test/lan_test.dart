import 'dart:convert';
import 'dart:io';

import 'package:fiwichat/crypto.dart';
import 'package:fiwichat/mesh.dart';
import 'package:fiwichat/transport_lan.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  test('Wi-Fi local : découverte UDP puis réception TCP', () async {
    final a = MeshNode(me: Identity.generate(), myName: 'A');
    final lan = LanTransport(a);
    await lan.start();
    addTearDown(lan.stop);

    final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(udp.close);
    udp.send(utf8.encode(jsonEncode({'app': kAppTag, 'node': 'autre-tel-123', 'port': kChatPort})),
        InternetAddress.loopbackIPv4, kDiscoveryPort);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(a.links.keys, contains('lan:127.0.0.1'));

    final b = Identity.generate();
    final s = await Socket.connect(InternetAddress.loopbackIPv4, kChatPort);
    s.write('${signedAnn(b, 'Bob', id: 'x1')}\n');
    s.write('${signedGrp(b, 'Bob', 'salut', id: 'x2')}\n');
    await s.flush();
    await s.close();
    await Future.delayed(const Duration(milliseconds: 300));
    expect(a.people.values.single.name, 'Bob');
    expect(a.conversations[kGroupId]!.single.text, 'salut');
  });
}
