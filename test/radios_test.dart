import 'package:fiwichat/crypto.dart';
import 'package:fiwichat/main.dart';
import 'package:fiwichat/mesh.dart';
import 'package:fiwichat/radios.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('les radios éteintes sont listées dans l\'ordre où les allumer', () {
    final r = RadioStatus.fromMap({
      'hasBluetooth': true,
      'bluetoothOn': false,
      'wifiOn': true,
      'locationOn': false,
    });
    expect(r.off, ['bluetooth', 'location']);
    expect(r.nearbyReady, isFalse);
    expect(const RadioStatus().off, isEmpty); // inconnu = pas d'alerte
  });

  testWidgets('Bluetooth éteint : un bandeau propose de l\'allumer', (tester) async {
    final opened = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('fiwichat/wifi'),
      (call) async {
        if (call.method == 'openRadioSettings') {
          opened.add((call.arguments as Map)['which'] as String);
        }
        return null;
      },
    );
    final services = AppServices(MeshNode(me: Identity.generate(), myName: 'Moi'));
    services.radios.value = RadioStatus.fromMap({'bluetoothOn': false});
    await tester.pumpWidget(FiwiApp(home: HomeScreen(services: services)));
    await tester.pump();
    expect(find.byKey(const Key('radios-banner')), findsOneWidget);
    await tester.tap(find.text('Allumer le Bluetooth'));
    expect(opened, ['bluetooth']);

    // Une fois allumé, le bandeau disparaît.
    services.radios.value = RadioStatus.fromMap({'bluetoothOn': true});
    await tester.pump();
    expect(find.byKey(const Key('radios-banner')), findsNothing);

    // L'écran Connexions montre chaque radio.
    await tester.tap(find.byKey(const Key('links-bar')));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi (même réseau)'), findsOneWidget);
    expect(find.text('Bluetooth'), findsOneWidget);
    expect(find.text('Wi-Fi Direct'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Et la radio ?'), 200);
    expect(find.text('Et la radio ?'), findsOneWidget);
  });
}
