// FIWICHAT - serveur HTTP de la page invité (dart:io pur, testable sans Flutter).
import 'dart:io';

import 'mesh.dart';

const int kGuestPort = 8080;

class GuestLink implements Link {
  GuestLink(this.n, this.socket);
  final int n;
  final WebSocket socket;
  @override
  String get key => 'web:$n';
  @override
  String get kind => 'invite';
  @override
  void send(String frame) {
    try {
      socket.add(frame);
    } catch (_) {}
  }
}

/// Serveur HTTP de la page invité (séparé pour pouvoir le tester).
///  /            -> la page du chat
///  /nacl.js     -> la bibliothèque de chiffrement
///  /ws          -> la connexion en direct au maillage
///  /fiwichat.apk -> l'appli elle-même, pour l'installer sans internet
Future<HttpServer> serveGuests(
  MeshNode mesh, {
  required String html,
  required String nacl,
  required String? Function() apkPath,
  InternetAddress? address,
  int port = kGuestPort,
}) async {
  var n = 0;
  final http = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port, shared: true);
  http.listen((req) async {
    try {
      if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        final link = GuestLink(n++, ws);
        mesh.addLink(link);
        ws.listen(
          (data) {
            if (data is String) mesh.receive(data, link.key);
          },
          onDone: () => mesh.removeLink(link.key),
          onError: (_) => mesh.removeLink(link.key),
        );
        return;
      }
      final res = req.response;
      res.headers.set('Cache-Control', 'no-store');
      if (req.uri.path == '/fiwichat.apk') {
        final path = apkPath();
        final file = path == null ? null : File(path);
        if (file == null || !file.existsSync()) {
          res.statusCode = HttpStatus.notFound;
          res.headers.contentType = ContentType.text;
          res.write("L'appli n'est disponible que depuis un téléphone Android.");
        } else {
          res.headers.contentType = ContentType('application', 'vnd.android.package-archive');
          res.headers.set('Content-Disposition', 'attachment; filename="fiwichat.apk"');
          res.contentLength = file.lengthSync();
          await res.addStream(file.openRead());
        }
      } else if (req.uri.path == '/nacl.js') {
        res.headers.contentType = ContentType('application', 'javascript', charset: 'utf-8');
        res.write(nacl);
      } else {
        // Toute autre adresse renvoie la page du chat.
        res.headers.contentType = ContentType.html;
        res.write(html);
      }
      await res.close();
    } catch (_) {}
  });
  return http;
}
