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
///  /installer   -> une page toute simple : un gros bouton + les étapes d'installation
Future<HttpServer> serveGuests(
  MeshNode mesh, {
  required String html,
  required String nacl,
  required String? Function() apkPath,
  InternetAddress? address,
  int port = kGuestPort,
}) async {
  var n = 0;
  final http = await HttpServer.bind(
    address ?? InternetAddress.anyIPv4,
    port,
    shared: true,
  );
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
          res.write(
            "L'appli n'est disponible que depuis un téléphone Android.",
          );
        } else {
          res.headers.contentType = ContentType(
            'application',
            'vnd.android.package-archive',
          );
          res.headers.set(
            'Content-Disposition',
            'attachment; filename="fiwichat.apk"',
          );
          res.contentLength = file.lengthSync();
          await res.addStream(file.openRead());
        }
      } else if (req.uri.path == '/installer' ||
          req.uri.path == '/installer/') {
        res.headers.contentType = ContentType.html;
        res.write(kInstallerPage);
      } else if (req.uri.path == '/nacl.js') {
        res.headers.contentType = ContentType(
          'application',
          'javascript',
          charset: 'utf-8',
        );
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

/// Page d'installation, pensée pour quelqu'un qui n'y connaît rien.
const kInstallerPage = r"""<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Installer FIWICHAT</title>
<style>
:root{--brand:#0E7C66;--bg:#f4f7f6;--card:#fff;--txt:#1b2421;--muted:#55635e}
@media (prefers-color-scheme:dark){:root{--bg:#101614;--card:#1a2320;--txt:#e8efec;--muted:#9fb0aa}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);font:18px/1.45 system-ui,sans-serif}
main{max-width:520px;margin:0 auto;padding:20px 16px 40px}
h1{font-size:26px;margin:8px 0 4px;color:var(--brand)}p.sub{margin:0 0 20px;color:var(--muted)}
a.big{display:block;text-align:center;background:var(--brand);color:#fff;text-decoration:none;font-weight:700;font-size:22px;padding:20px;border-radius:16px;margin:0 0 24px}
ol{list-style:none;padding:0;margin:0;counter-reset:s}
li{background:var(--card);border-radius:14px;padding:14px 14px 14px 58px;margin:0 0 12px;position:relative;counter-increment:s}
li:before{content:counter(s);position:absolute;left:14px;top:14px;width:32px;height:32px;border-radius:50%;background:var(--brand);color:#fff;font-weight:700;display:flex;align-items:center;justify-content:center}
b.q{white-space:nowrap}.ios{display:none;background:var(--card);border-radius:14px;padding:14px}
</style></head><body><main>
<h1>Installer FIWICHAT</h1>
<p class="sub">Le chat qui marche sans internet. L'appli vient directement du téléphone d'à côté.</p>
<div id="android">
<a class="big" href="/fiwichat.apk" download="fiwichat.apk">⬇ Télécharger FIWICHAT</a>
<ol>
<li>Appuie sur le gros bouton vert. Si le téléphone demande, appuie sur <b class="q">« Télécharger quand même »</b>.</li>
<li>Quand c'est fini, appuie sur <b class="q">« Ouvrir »</b> (ou ouvre <b>fiwichat.apk</b> dans <b>Fichiers › Téléchargements</b>).</li>
<li>Si Android bloque : appuie sur <b class="q">« Paramètres »</b>, active <b class="q">« Autoriser cette source »</b>, puis reviens en arrière.</li>
<li>Appuie sur <b class="q">« Installer »</b>. Si <b>Play Protect</b> s'affiche : <b class="q">« Plus de détails »</b> puis <b class="q">« Installer quand même »</b>.</li>
<li>Ouvre FIWICHAT, choisis un pseudo et appuie sur <b class="q">« Autoriser »</b> partout.</li>
</ol>
<p class="sub" style="margin-top:16px">Ensuite, toi aussi tu pourras la donner à d'autres avec le bouton « Partager FIWICHAT ».</p>
</div>
<div class="ios" id="ios">Sur iPhone, l'appli ne s'installe pas comme ça. Mais tu peux discuter tout de suite : <a href="/">ouvrir le chat</a>.</div>
</main><script>
if(/iPhone|iPad|iPod/.test(navigator.userAgent)){document.getElementById('android').style.display='none';document.getElementById('ios').style.display='block'}
</script></body></html>""";
