// FIWICHAT - mises à jour.
//
// Toutes les versions sont signées avec la même clé : une nouvelle version
// s'installe donc par-dessus l'ancienne, sans rien perdre.
// FIWICHAT cherche une version plus récente :
//  * sur internet quand il y en a (fichier version.json publié avec l'appli) ;
//  * sans internet, auprès des téléphones FIWICHAT sur le même Wi-Fi
//    (chacun annonce son numéro de version et sert son appli sur le port 8080).
// Avant d'installer, Android vérifie que le fichier vient bien de FIWICHAT.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('fiwichat/wifi');

const kReleaseBase =
    'https://github.com/455swrgk9y-ux/FIWICHAT/releases/latest/download';

class UpdateOffer {
  const UpdateOffer({
    required this.build,
    required this.apkUrl,
    required this.fromPhone,
  });
  final int build;
  final String apkUrl;

  /// true : la version vient d'un téléphone à côté (sans internet).
  final bool fromPhone;
}

class Updater {
  Updater({this.releaseBase = kReleaseBase, HttpClient Function()? client})
    : _client = client ?? HttpClient.new;

  final String releaseBase;
  final HttpClient Function() _client;

  /// Numéro de la version installée (null si inconnu, ex. hors Android).
  int? myBuild;

  /// La meilleure nouvelle version trouvée, ou null.
  final offer = ValueNotifier<UpdateOffer?>(null);

  /// Progression du téléchargement (0 à 1), ou null quand rien ne se télécharge.
  final progress = ValueNotifier<double?>(null);

  Timer? _timer;

  Future<void> start() async {
    try {
      myBuild = (await _channel.invokeMethod<num>('appVersion'))?.toInt();
    } catch (_) {}
    unawaited(checkInternet());
    _timer = Timer.periodic(const Duration(hours: 3), (_) => checkInternet());
  }

  void stop() => _timer?.cancel();

  /// Propose [build] si c'est plus récent que la version installée et que l'offre actuelle.
  /// Une version sur internet est préférée à égalité (plus fiable qu'un voisin).
  void consider(UpdateOffer o) {
    final mine = myBuild;
    if (mine == null || o.build <= mine) return;
    final cur = offer.value;
    if (cur == null ||
        o.build > cur.build ||
        (o.build == cur.build && cur.fromPhone && !o.fromPhone)) {
      offer.value = o;
    }
  }

  /// Un téléphone sur le même Wi-Fi annonce sa version.
  void notePeer(InternetAddress ip, int build) {
    final host = ip.type == InternetAddressType.IPv6
        ? '[${ip.address}]'
        : ip.address;
    consider(
      UpdateOffer(
        build: build,
        apkUrl: 'http://$host:8080/fiwichat.apk',
        fromPhone: true,
      ),
    );
  }

  static int? parseVersion(String body) {
    try {
      final b = (jsonDecode(body) as Map<String, dynamic>)['build'];
      return b is num ? b.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  /// Regarde sur internet s'il existe une version plus récente. Sans internet : rien.
  Future<void> checkInternet() async {
    if (myBuild == null) return;
    final c = _client()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await c.getUrl(Uri.parse('$releaseBase/version.json'));
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return;
      final build = parseVersion(await utf8.decodeStream(res));
      if (build != null) {
        consider(
          UpdateOffer(
            build: build,
            apkUrl: '$releaseBase/fiwichat.apk',
            fromPhone: false,
          ),
        );
      }
    } catch (_) {
      // Pas d'internet : normal pour FIWICHAT.
    } finally {
      c.close(force: true);
    }
  }

  /// Télécharge la nouvelle version dans [dir]. Renvoie le fichier, ou null si échec.
  Future<File?> download(UpdateOffer o, Directory dir) async {
    final c = _client()..connectionTimeout = const Duration(seconds: 10);
    final f = File('${dir.path}/update.apk');
    progress.value = 0;
    try {
      final req = await c.getUrl(Uri.parse(o.apkUrl));
      final res = await req.close();
      if (res.statusCode != 200) return null;
      final total = res.contentLength;
      var got = 0;
      final sink = f.openWrite();
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) progress.value = got / total;
      }
      await sink.close();
      return got > 0 ? f : null;
    } catch (_) {
      return null;
    } finally {
      progress.value = null;
      c.close(force: true);
    }
  }

  /// Télécharge puis ouvre l'installation Android.
  /// Renvoie un message à afficher si quelque chose ne va pas, ou null si tout va bien.
  Future<String?> downloadAndInstall() async {
    final o = offer.value;
    if (o == null) return null;
    String? dirPath;
    try {
      dirPath = await _channel.invokeMethod<String>('shareDir');
    } catch (_) {}
    final f = await download(
      o,
      Directory(dirPath ?? Directory.systemTemp.path),
    );
    if (f == null) {
      return o.fromPhone
          ? 'Le téléphone d\'à côté ne répond plus. Réessaie près de lui.'
          : 'Téléchargement impossible. Vérifie internet et réessaie.';
    }
    String? r;
    try {
      r = await _channel.invokeMethod<String>('installApk', {'path': f.path});
    } catch (_) {}
    switch (r) {
      case 'ok':
        return null;
      case 'bad-signature':
      case 'invalid':
        if (o.fromPhone) offer.value = null;
        return 'Ce fichier ne vient pas de FIWICHAT : il a été refusé.';
      case 'not-newer':
        offer.value = null;
        return 'Tu as déjà la dernière version.';
      default:
        // Dernier recours : le navigateur télécharge, puis on ouvre le fichier.
        await openUrl(o.apkUrl);
        return null;
    }
  }
}

Future<bool> openUrl(String url) async {
  try {
    return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
  } catch (_) {
    return false;
  }
}
