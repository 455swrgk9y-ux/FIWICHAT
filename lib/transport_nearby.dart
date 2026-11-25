// FIWICHAT - transport "à proximité" (Android) : Google Nearby Connections.
// Les téléphones FIWICHAT proches se trouvent et se relient tout seuls
// (Bluetooth pour se trouver, Wi-Fi direct entre eux pour transmettre),
// sans box ni internet. Chaque téléphone relié devient un relais du maillage.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import 'mesh.dart';

const _serviceId = 'com.fiwichat.mesh';

class NearbyLink implements Link {
  NearbyLink(this.endpointId);
  final String endpointId;
  @override
  String get key => 'nb:$endpointId';
  @override
  String get kind => 'proche';
  @override
  void send(String frame) {
    Nearby()
        .sendBytesPayload(endpointId, Uint8List.fromList(utf8.encode(frame)))
        .catchError((_) {});
  }
}

class NearbyTransport {
  NearbyTransport(this.mesh);
  final MeshNode mesh;
  final _pending = <String>{};
  bool running = false;
  String? error;

  static Future<bool> requestPermissions() async {
    final statuses = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
    ].request();
    return statuses[Permission.location]?.isGranted == true ||
        statuses[Permission.nearbyWifiDevices]?.isGranted == true;
  }

  Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await requestPermissions();
      // Un nom neutre : on ne montre pas le pseudo aux appareils inconnus.
      const nick = 'fiwichat';
      await Nearby().startAdvertising(
        nick,
        Strategy.P2P_CLUSTER,
        serviceId: _serviceId,
        onConnectionInitiated: _onInitiated,
        onConnectionResult: _onResult,
        onDisconnected: _onDisconnected,
      );
      await Nearby().startDiscovery(
        nick,
        Strategy.P2P_CLUSTER,
        serviceId: _serviceId,
        onEndpointFound: (id, name, serviceId) {
          if (mesh.links.containsKey('nb:$id') || _pending.contains(id)) return;
          _pending.add(id);
          Nearby()
              .requestConnection(nick, id,
                  onConnectionInitiated: _onInitiated,
                  onConnectionResult: _onResult,
                  onDisconnected: _onDisconnected)
              .catchError((_) {
            _pending.remove(id);
            return false;
          });
        },
        onEndpointLost: (id) {
          if (id != null) _pending.remove(id);
        },
      );
      running = true;
    } catch (e) {
      error = '$e';
    }
  }

  void _onInitiated(String id, ConnectionInfo info) {
    Nearby().acceptConnection(id, onPayLoadRecieved: (endpointId, payload) {
      final bytes = payload.bytes;
      if (payload.type != PayloadType.BYTES || bytes == null) return;
      mesh.receive(utf8.decode(bytes), 'nb:$endpointId');
    }).catchError((_) => false);
  }

  void _onResult(String id, Status status) {
    _pending.remove(id);
    if (status == Status.CONNECTED) mesh.addLink(NearbyLink(id));
  }

  void _onDisconnected(String id) {
    _pending.remove(id);
    mesh.removeLink('nb:$id');
  }

  Future<void> stop() async {
    try {
      await Nearby().stopAdvertising();
      await Nearby().stopDiscovery();
      await Nearby().stopAllEndpoints();
    } catch (_) {}
  }
}
