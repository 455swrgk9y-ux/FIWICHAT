// FIWICHAT - transport "même Wi-Fi" : téléphones sur la même box ou le même point d'accès.
//  * Découverte : un petit signal UDP "je suis là" toutes les 3 s (port 45454).
//  * Paquets : connexion TCP directe vers le voisin (port 45455), une ligne JSON par paquet.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mesh.dart';

const int kDiscoveryPort = 45454;
const int kChatPort = 45455;
const String kAppTag = 'fiwichat-v2';

class LanLink implements Link {
  LanLink(this.address, {this.manual = false});
  final InternetAddress address;
  final bool manual;
  DateTime lastSeen = DateTime.now();

  @override
  String get key => 'lan:${address.address}';
  @override
  String get kind => 'wifi';

  @override
  void send(String frame) {
    Socket.connect(address, kChatPort, timeout: const Duration(seconds: 4))
        .then((s) {
          s.write('$frame\n');
          return s.flush().then((_) => s.close());
        })
        .catchError((_) {});
  }
}

class LanTransport {
  LanTransport(this.mesh);
  final MeshNode mesh;

  RawDatagramSocket? _udp;
  ServerSocket? _server;
  Timer? _timer;
  List<InternetAddress> _targets = [];
  final Set<InternetAddress> _extraTargets = {};
  List<String> myAddresses = [];

  /// Mon numéro de version, annoncé aux voisins (pour les mises à jour sans internet).
  int? myBuild;

  /// Appelé quand un voisin annonce son numéro de version.
  void Function(InternetAddress address, int build)? onPeerBuild;
  int _tick = 0;

  String get _tag => mesh.myId.substring(0, 12);

  Future<void> start() async {
    await _refreshAddresses();
    _server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      kChatPort,
      shared: true,
    );
    _server!.listen(_onSocket);
    _udp = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      kDiscoveryPort,
      reuseAddress: true,
    );
    _udp!.broadcastEnabled = true;
    _udp!.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final dg = _udp!.receive();
      if (dg == null) return;
      try {
        final m = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (m['app'] != kAppTag || m['node'] == _tag) return;
        _touch(dg.address);
        final b = m['build'];
        if (b is int) onPeerBuild?.call(dg.address, b);
      } catch (_) {}
    });
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _beat());
    _beat();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _udp?.close();
    await _server?.close();
  }

  void _touch(InternetAddress addr, {bool manual = false}) {
    if (myAddresses.contains(addr.address)) return;
    final key = 'lan:${addr.address}';
    final existing = mesh.links[key];
    if (existing is LanLink) {
      existing.lastSeen = DateTime.now();
    } else {
      mesh.addLink(LanLink(addr, manual: manual));
    }
  }

  void _onSocket(Socket s) {
    final remote = s.remoteAddress;
    utf8.decoder
        .bind(s)
        .transform(const LineSplitter())
        .listen(
          (line) {
            _touch(remote);
            mesh.receive(line, 'lan:${remote.address}');
          },
          onDone: s.destroy,
          onError: (_) => s.destroy(),
        );
  }

  void _beat() {
    if (_tick++ % 5 == 0) _refreshAddresses();
    final data = utf8.encode(
      jsonEncode({
        'app': kAppTag,
        'node': _tag,
        'port': kChatPort,
        if (myBuild != null) 'build': myBuild,
      }),
    );
    for (final t in [..._targets, ..._extraTargets]) {
      try {
        _udp?.send(data, t, kDiscoveryPort);
      } catch (_) {}
    }
    // Oublie les voisins qui ne donnent plus signe de vie.
    final now = DateTime.now();
    for (final l in mesh.links.values.whereType<LanLink>().toList()) {
      if (!l.manual &&
          now.difference(l.lastSeen) > const Duration(seconds: 15)) {
        mesh.removeLink(l.key);
      }
    }
  }

  Future<void> _refreshAddresses() async {
    final targets = <String>{'255.255.255.255'};
    final mine = <String>[];
    try {
      for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final a in iface.addresses) {
          if (a.isLoopback) continue;
          mine.add(a.address);
          final p = a.address.split('.');
          if (p.length == 4) targets.add('${p[0]}.${p[1]}.${p[2]}.255');
        }
      }
    } catch (_) {}
    myAddresses = mine;
    _targets = targets.map(InternetAddress.new).toList();
  }

  /// Connexion manuelle par adresse (si la détection automatique est bloquée).
  bool connectManually(String ip) {
    final a = InternetAddress.tryParse(ip.trim());
    if (a == null) return false;
    _extraTargets.add(a);
    _touch(a, manual: true);
    _beat();
    return true;
  }
}
