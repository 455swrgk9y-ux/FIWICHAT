// FIWICHAT - état des radios du téléphone (Bluetooth, Wi-Fi, localisation).
//
// FIWICHAT utilise toutes les radios qu'un téléphone permet d'utiliser :
//  * Wi-Fi « même réseau » (box, point d'accès d'un téléphone, Wi-Fi FIWICHAT) ;
//  * Bluetooth classique et Bluetooth basse consommation (BLE) ;
//  * Wi-Fi Direct et Wi-Fi Aware, de téléphone à téléphone, sans box.
// Les trois derniers passent par Google Nearby Connections, qui choisit tout seul
// la meilleure radio disponible. Android exige la localisation allumée pour
// chercher les appareils proches.
import 'package:flutter/services.dart';

const _channel = MethodChannel('fiwichat/wifi');

class RadioStatus {
  const RadioStatus({
    this.known = false,
    this.hasBluetooth = true,
    this.hasBle = true,
    this.hasWifiDirect = true,
    this.hasWifiAware = false,
    this.hasNfc = false,
    this.bluetoothOn = true,
    this.wifiOn = true,
    this.locationOn = true,
  });

  /// false quand on n'a pas pu interroger le téléphone (ex. tests, iPhone).
  final bool known;
  final bool hasBluetooth, hasBle, hasWifiDirect, hasWifiAware, hasNfc;
  final bool bluetoothOn, wifiOn, locationOn;

  /// Les radios utiles qui sont éteintes, dans l'ordre où les allumer.
  List<String> get off => [
    if (hasBluetooth && !bluetoothOn) 'bluetooth',
    // Wi-Fi éteint : pas grave si le Bluetooth marche (FIWICHAT passe par lui).
    if (!wifiOn && !(hasBluetooth && bluetoothOn)) 'wifi',
    if (!locationOn) 'location',
  ];

  /// Nearby (Bluetooth / Wi-Fi Direct) peut chercher les téléphones proches.
  /// La localisation aide sur les anciens Android, mais n'est pas obligatoire.
  bool get nearbyReady => bluetoothOn;

  factory RadioStatus.fromMap(Map<String, dynamic> m) {
    bool b(String k, bool d) => m[k] is bool ? m[k] as bool : d;
    return RadioStatus(
      known: true,
      hasBluetooth: b('hasBluetooth', true),
      hasBle: b('hasBle', true),
      hasWifiDirect: b('hasWifiDirect', true),
      hasWifiAware: b('hasWifiAware', false),
      hasNfc: b('hasNfc', false),
      bluetoothOn: b('bluetoothOn', true),
      wifiOn: b('wifiOn', true),
      locationOn: b('locationOn', true),
    );
  }

  static Future<RadioStatus> read() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('radioStatus');
      return m == null ? const RadioStatus() : RadioStatus.fromMap(m);
    } catch (_) {
      return const RadioStatus();
    }
  }

  @override
  bool operator ==(Object o) =>
      o is RadioStatus &&
      o.known == known &&
      o.bluetoothOn == bluetoothOn &&
      o.wifiOn == wifiOn &&
      o.locationOn == locationOn;

  @override
  int get hashCode => Object.hash(known, bluetoothOn, wifiOn, locationOn);
}

/// Ouvre l'écran Android pour allumer 'bluetooth', 'wifi' ou 'location'.
Future<void> openRadioSettings(String which) async {
  try {
    await _channel.invokeMethod('openRadioSettings', {'which': which});
  } catch (_) {}
}

String radioLabel(String which) => switch (which) {
  'bluetooth' => 'Bluetooth',
  'wifi' => 'Wi-Fi',
  'location' => 'Localisation',
  _ => which,
};

String radioAction(String which) => switch (which) {
  'bluetooth' => 'Allumer le Bluetooth',
  'wifi' => 'Allumer le Wi-Fi',
  'location' => 'Allumer la localisation',
  _ => 'Ouvrir les réglages',
};
