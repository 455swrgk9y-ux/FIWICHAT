// FIWICHAT - mode invité.
// Le téléphone crée un réseau Wi-Fi "DIRECT-FC-FIWICHAT". Quelqu'un sans l'appli
// s'y connecte puis ouvre la page http://192.168.49.1:8080 dans son navigateur.
// La page invité est un vrai membre du maillage : elle a sa propre clé et
// chiffre/déchiffre elle-même ses messages privés. Le téléphone hôte ne fait
// que passer les paquets, il ne peut pas lire les messages privés.
import 'dart:io';

import 'package:flutter/services.dart';

import 'guest_http.dart';
import 'mesh.dart';

export 'guest_http.dart';

const _channel = MethodChannel('fiwichat/wifi');

class GuestHotspot {
  GuestHotspot(this.ssid, this.password, this.ip);
  final String ssid, password, ip;
  String get url => 'http://$ip:$kGuestPort';
  String get wifiQr => 'WIFI:T:WPA;S:$ssid;P:$password;;';
  String get installerUrl => '$url/installer';
}

class GuestServer {
  GuestServer(this.mesh);
  final MeshNode mesh;
  HttpServer? _http;
  GuestHotspot? hotspot;
  String? error;

  bool get active => hotspot != null;

  /// Chemin du fichier d'installation de l'appli (l'APK) sur ce téléphone.
  String? apkPath;

  /// Le serveur de la page invité tourne tout le temps (aussi pour les gens sur la même box).
  Future<void> startServer() async {
    final html = await rootBundle.loadString('assets/guest/index.html');
    final nacl = await rootBundle.loadString('assets/guest/nacl-fast.min.js');
    try {
      apkPath = await _channel.invokeMethod<String>('getApkPath');
    } catch (_) {}
    _http = await serveGuests(
      mesh,
      html: html,
      nacl: nacl,
      apkPath: () => apkPath,
    );
  }

  /// Ouvre le réseau Wi-Fi invité (Android 10+).
  Future<bool> openHotspot() async {
    error = null;
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>(
        'startGuestHotspot',
      );
      if (r == null) return false;
      hotspot = GuestHotspot(
        r['ssid'] as String,
        r['password'] as String,
        (r['ip'] as String?) ?? '192.168.49.1',
      );
      return true;
    } on PlatformException catch (e) {
      error = e.message ?? e.code;
      return false;
    } catch (e) {
      error = '$e';
      return false;
    }
  }

  Future<void> closeHotspot() async {
    hotspot = null;
    try {
      await _channel.invokeMethod('stopGuestHotspot');
    } catch (_) {}
  }

  Future<void> stop() async {
    await closeHotspot();
    await _http?.close(force: true);
  }
}

/// Envoie l'APK. [via] = 'quickshare' ou 'bluetooth' ouvre directement cette appli
/// si elle existe, sinon (ou avec null) le menu de partage Android complet.
Future<bool> shareApp({String? via}) async {
  try {
    return await _channel.invokeMethod<String>('shareApk', {'via': via}) !=
        null;
  } catch (_) {
    return false;
  }
}
