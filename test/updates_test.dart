import 'dart:io';

import 'package:fiwichat/updates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('seule une version plus récente est proposée', () {
    final u = Updater()..myBuild = 7;
    u.notePeer(InternetAddress('192.168.1.20'), 6);
    expect(u.offer.value, isNull);
    u.notePeer(InternetAddress('192.168.1.20'), 7);
    expect(u.offer.value, isNull);
    u.notePeer(InternetAddress('192.168.1.20'), 9);
    expect(u.offer.value!.build, 9);
    expect(u.offer.value!.apkUrl, 'http://192.168.1.20:8080/fiwichat.apk');
    // Une version plus ancienne ne remplace pas la meilleure.
    u.notePeer(InternetAddress('192.168.1.30'), 8);
    expect(u.offer.value!.build, 9);
    // À égalité, internet est préféré à un voisin.
    u.consider(
      const UpdateOffer(
        build: 9,
        apkUrl: 'https://x/fiwichat.apk',
        fromPhone: false,
      ),
    );
    expect(u.offer.value!.fromPhone, isFalse);
  });

  test('version inconnue (hors Android) : rien n\'est proposé', () {
    final u = Updater();
    u.notePeer(InternetAddress('10.0.0.2'), 99);
    expect(u.offer.value, isNull);
  });

  test('lit version.json, et ignore un fichier abîmé', () {
    expect(Updater.parseVersion('{"build": 12, "name": "1.0.12"}'), 12);
    expect(Updater.parseVersion('pas du json'), isNull);
    expect(Updater.parseVersion('{"name": "x"}'), isNull);
  });

  test('trouve la nouvelle version sur internet et la télécharge', () async {
    final apk = List<int>.generate(200000, (i) => i % 251);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      if (req.uri.path == '/dl/version.json') {
        req.response.write('{"build": 15}');
      } else if (req.uri.path == '/dl/fiwichat.apk') {
        req.response.contentLength = apk.length;
        req.response.add(apk);
      } else {
        req.response.statusCode = 404;
      }
      req.response.close();
    });
    final u = Updater(releaseBase: 'http://127.0.0.1:${server.port}/dl')
      ..myBuild = 10;
    await u.checkInternet();
    expect(u.offer.value!.build, 15);
    expect(u.offer.value!.fromPhone, isFalse);

    final tmp = await Directory.systemTemp.createTemp('fiwi-up');
    final progress = <double?>[];
    u.progress.addListener(() => progress.add(u.progress.value));
    final f = await u.download(u.offer.value!, tmp);
    expect(await f!.readAsBytes(), apk);
    expect(progress.last, isNull); // fini
    expect(progress.any((p) => p != null && p > 0.5), isTrue);
    await tmp.delete(recursive: true);
    await server.close(force: true);
  });

  test('sans internet : pas d\'erreur, pas de proposition', () async {
    final u = Updater(releaseBase: 'http://127.0.0.1:1/dl')..myBuild = 3;
    await u.checkInternet();
    expect(u.offer.value, isNull);
  });
}
