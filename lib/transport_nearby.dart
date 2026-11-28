// FIWICHAT - transport "à proximité" (Android) : Google Nearby Connections.
// Les téléphones FIWICHAT proches se trouvent et se relient tout seuls
// (Bluetooth pour se trouver, puis Bluetooth ou Wi-Fi direct pour transmettre),
// sans box ni internet. Chaque téléphone relié devient un relais du maillage.
//
// Points importants (corrigés après les essais sur de vrais téléphones) :
//  * Deux téléphones qui se trouvent en même temps ne doivent pas s'appeler tous
//    les deux : les deux appels se percutent et la liaison échoue. Chacun a un
//    petit numéro tiré au hasard ; seul le plus petit appelle (l'autre attend,
//    puis appelle quand même s'il ne se passe rien).
//  * Un appel raté est réessayé toutes les quelques secondes, tant que l'autre
//    téléphone est visible.
//  * Les autorisations (appareils à proximité, localisation) sont vérifiées et
//    l'appli explique lesquelles manquent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import 'mesh.dart';

const _serviceId = 'com.fiwichat.mesh';
const _prefix = 'fw:';

/// Nom annoncé : "fw:" + numéro au hasard (jamais le pseudo).
String nearbyName(String token) => '$_prefix$token';

/// Vrai si c'est à MOI d'appeler l'autre téléphone (le plus petit numéro appelle).
/// Un ancien FIWICHAT (sans numéro) : on appelle toujours.
bool shouldInitiate(String myToken, String theirName) {
  if (!theirName.startsWith(_prefix)) return true;
  final theirs = theirName.substring(_prefix.length);
  if (theirs.isEmpty || theirs == myToken) return true;
  return myToken.compareTo(theirs) < 0;
}

class NearbyLink implements Link {
  NearbyLink(this.endpointId, {this.onError});
  final String endpointId;
  final void Function(String endpointId)? onError;
  @override
  String get key => 'nb:$endpointId';
  @override
  String get kind => 'proche';
  @override
  void send(String frame) {
    Nearby()
        .sendBytesPayload(endpointId, Uint8List.fromList(utf8.encode(frame)))
        .catchError((_) => onError?.call(endpointId));
  }
}

/// Un téléphone FIWICHAT vu à proximité, pas encore (ou plus) relié.
class _Seen {
  _Seen(this.name);
  final String name;
  final DateTime found = DateTime.now();
  DateTime? lastTry;
  int tries = 0;
}

class NearbyTransport {
  NearbyTransport(this.mesh);
  final MeshNode mesh;

  /// Mon numéro pour cette session (sert à décider qui appelle).
  final String token = List.generate(
    8,
    (_) => Random.secure().nextInt(16).toRadixString(16),
  ).join();

  final Map<String, _Seen> _seen = {};
  final Set<String> _connecting = {};
  final Set<String> _connected = {};

  /// Pour chaque téléphone relié : son nom et le dernier paquet reçu de lui.
  final Map<String, String> _names = {};
  final Map<String, DateTime> _lastRx = {};

  /// Une liaison qui ne reçoit plus rien depuis 75 s est à moitié cassée
  /// (un seul des deux téléphones la croit ouverte) : on la refait.
  static const Duration kSilent = Duration(seconds: 75);
  Timer? _timer;
  bool running = false;
  String? error;

  /// Autorisations encore refusées (vide si tout va bien).
  List<Permission> missing = [];

  /// Nombre de téléphones reliés par Bluetooth / Wi-Fi direct.
  int get connectedCount => _connected.length;

  /// Nombre de téléphones vus mais pas encore reliés.
  int get waitingCount => _seen.length;

  static List<Permission> get needed => [
    Permission.locationWhenInUse,
    Permission.bluetoothScan,
    Permission.bluetoothAdvertise,
    Permission.bluetoothConnect,
    Permission.nearbyWifiDevices,
  ];

  /// Vérifie (et demande si [ask]) les autorisations nécessaires.
  Future<List<Permission>> checkPermissions({bool ask = false}) async {
    if (!Platform.isAndroid) return const [];
    final out = <Permission>[];
    try {
      if (ask) await needed.request();
      for (final p in needed) {
        final s = await p.status;
        // "restricted"/"limited" n'existent pas sur Android ; une autorisation
        // qui n'existe pas sur cette version d'Android est déjà "accordée".
        if (!s.isGranted) out.add(p);
      }
    } catch (_) {}
    missing = out;
    return out;
  }

  /// Ouvre les réglages de l'appli (si une autorisation a été refusée pour de bon).
  static Future<void> openSettings() async {
    try {
      await openAppSettings();
    } catch (_) {}
  }

  Future<void> start({bool askPermissions = true}) async {
    if (!Platform.isAndroid) return;
    error = null;
    await checkPermissions(ask: askPermissions);
    // On s'arrête d'abord proprement (sinon "déjà en cours" fait tout échouer).
    try {
      await Nearby().stopAdvertising();
      await Nearby().stopDiscovery();
    } catch (_) {}
    final name = nearbyName(token);
    var ok = 0;
    try {
      await Nearby().startAdvertising(
        name,
        Strategy.P2P_CLUSTER,
        serviceId: _serviceId,
        onConnectionInitiated: _onInitiated,
        onConnectionResult: _onResult,
        onDisconnected: _onDisconnected,
      );
      ok++;
    } catch (e) {
      error = 'annonce : ${_short(e)}';
    }
    try {
      await Nearby().startDiscovery(
        name,
        Strategy.P2P_CLUSTER,
        serviceId: _serviceId,
        onEndpointFound: (id, theirName, serviceId) {
          if (_connected.contains(id)) return;
          _seen[id] = _Seen(theirName);
          _names[id] = theirName;
          if (shouldInitiate(token, theirName)) _call(id);
        },
        onEndpointLost: (id) {
          if (id != null) _seen.remove(id);
        },
      );
      ok++;
    } catch (e) {
      error = 'recherche : ${_short(e)}';
    }
    running = ok > 0;
    _timer ??= Timer.periodic(const Duration(seconds: 4), (_) => _retry());
  }

  static String _short(Object e) {
    final s = '$e';
    return s.length > 120 ? s.substring(0, 120) : s;
  }

  /// Réessaie les téléphones vus mais pas reliés.
  void _retry() {
    final now = DateTime.now();
    for (final id in _connected.toList()) {
      final last = _lastRx[id];
      if (last != null && now.difference(last) > kSilent) _reconnect(id);
    }
    for (final e in _seen.entries.toList()) {
      final id = e.key, s = e.value;
      if (_connected.contains(id) || _connecting.contains(id)) continue;
      // Si c'est à l'autre d'appeler, on lui laisse 8 secondes.
      final mine = shouldInitiate(token, s.name);
      if (!mine && now.difference(s.found) < const Duration(seconds: 8)) {
        continue;
      }
      // Attente croissante entre deux essais : 4 s, 8 s, 16 s... (60 s max).
      final wait = Duration(seconds: min(60, 4 << min(s.tries, 4)));
      if (s.lastTry != null && now.difference(s.lastTry!) < wait) continue;
      _call(id);
    }
  }

  void _call(String id) {
    if (_connecting.contains(id) || _connected.contains(id)) return;
    _connecting.add(id);
    final s = _seen[id];
    if (s != null) {
      s.lastTry = DateTime.now();
      s.tries++;
    }
    Nearby()
        .requestConnection(
          nearbyName(token),
          id,
          onConnectionInitiated: _onInitiated,
          onConnectionResult: _onResult,
          onDisconnected: _onDisconnected,
        )
        .catchError((Object e) {
          _connecting.remove(id);
          return false;
        });
  }

  void _onInitiated(String id, ConnectionInfo info) {
    _connecting.add(id);
    _names[id] = info.endpointName;
    Nearby()
        .acceptConnection(
          id,
          onPayLoadRecieved: (endpointId, payload) {
            final bytes = payload.bytes;
            if (payload.type != PayloadType.BYTES || bytes == null) return;
            _lastRx[endpointId] = DateTime.now();
            try {
              mesh.receive(utf8.decode(bytes), 'nb:$endpointId');
            } catch (_) {}
          },
        )
        .catchError((_) {
          _connecting.remove(id);
          return false;
        });
  }

  void _onResult(String id, Status status) {
    _connecting.remove(id);
    if (status == Status.CONNECTED) {
      _connected.add(id);
      _seen.remove(id);
      _lastRx[id] = DateTime.now();
      mesh.addLink(NearbyLink(id, onError: _onSendError));
    }
    // Sinon : l'essai suivant se fera tout seul (_retry).
  }

  void _onDisconnected(String id) {
    _connecting.remove(id);
    _connected.remove(id);
    _lastRx.remove(id);
    mesh.removeLink('nb:$id');
    // On le garde dans la liste : il sera rappelé s'il est encore là.
    final name = _names[id];
    if (name != null) _seen.putIfAbsent(id, () => _Seen(name));
  }

  /// Coupe une liaison muette et la refait.
  void _reconnect(String id) {
    try {
      Nearby().disconnectFromEndpoint(id);
    } catch (_) {}
    _onDisconnected(id);
    _seen[id]?.lastTry = null;
  }

  /// Un envoi impossible : la liaison est sûrement coupée.
  void _onSendError(String id) {
    if (!_connected.contains(id)) return;
    _reconnect(id);
  }

  /// Relance la recherche (ex. quand le Bluetooth ou la localisation vient d'être allumé).
  /// Les liens déjà établis restent en place.
  Future<void> restartSearch({bool askPermissions = false}) async {
    if (!Platform.isAndroid) return;
    _seen.clear();
    _connecting.clear();
    running = false;
    await start(askPermissions: askPermissions);
  }

  Future<void> stop() async {
    running = false;
    _timer?.cancel();
    _timer = null;
    try {
      await Nearby().stopAdvertising();
      await Nearby().stopDiscovery();
      await Nearby().stopAllEndpoints();
    } catch (_) {}
    _connected.clear();
  }
}
