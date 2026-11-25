import 'dart:convert';
import 'dart:io';

import 'package:fiwichat/crypto.dart';
import 'package:fiwichat/guest_http.dart';
import 'package:fiwichat/mesh.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late MeshNode host;
  late HttpServer server;
  late Directory tmp;
  String? apk;

  Future<HttpClientResponse> get(String path) async {
    final c = HttpClient();
    final req = await c.get('127.0.0.1', server.port, path);
    return req.close();
  }

  setUp(() async {
    host = MeshNode(me: Identity.generate(), myName: 'Hôte');
    tmp = await Directory.systemTemp.createTemp('fiwi');
    apk = null;
    server = await serveGuests(host,
        html: '<html>page invité</html>',
        nacl: '/* nacl */',
        apkPath: () => apk,
        address: InternetAddress.loopbackIPv4,
        port: 0);
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  test('la page du chat est servie', () async {
    final r = await get('/');
    expect(await utf8.decodeStream(r), contains('page invité'));
  });

  test("l'appli se télécharge depuis le téléphone, sans internet", () async {
    final f = File('${tmp.path}/base.apk')..writeAsBytesSync(List.generate(300000, (i) => i % 251));
    apk = f.path;
    final r = await get('/fiwichat.apk');
    expect(r.statusCode, 200);
    expect(r.headers.contentType?.mimeType, 'application/vnd.android.package-archive');
    expect(r.headers.value('content-disposition'), contains('fiwichat.apk'));
    final bytes = await r.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(bytes, f.readAsBytesSync());
  });

  test("sans APK (ex. iPhone), un message clair au lieu d'une erreur", () async {
    final r = await get('/fiwichat.apk');
    expect(r.statusCode, 404);
    expect(await utf8.decodeStream(r), contains('Android'));
  });

  test("un invité rejoint le maillage par la page", () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
    final guest = Identity.generate();
    ws.add(signedAnn(guest, 'Invité', id: 'g1', guest: true));
    ws.add(signedGrp(guest, 'Invité', 'coucou', id: 'g2'));
    await Future.delayed(const Duration(milliseconds: 200));
    expect(host.people[guest.id]!.guest, isTrue);
    expect(host.conversations[kGroupId]!.single.text, 'coucou');
    expect(host.linkCount('invite'), 1);
    await ws.close();
  });
}
