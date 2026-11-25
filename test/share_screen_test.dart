import 'package:fiwichat/crypto.dart';
import 'package:fiwichat/main.dart';
import 'package:fiwichat/mesh.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('le gros bouton « Partager FIWICHAT » envoie l\'appli', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('fiwichat/wifi'),
      (call) async {
        calls.add(call);
        return call.method == 'shareApk' ? 'direct' : null;
      },
    );
    final services = AppServices(MeshNode(me: Identity.generate(), myName: 'Moi'));
    await tester.pumpWidget(FiwiApp(home: HomeScreen(services: services)));
    await tester.pump();

    // Le bouton est bien visible, en bas au milieu.
    final big = find.byKey(const Key('share-big'));
    expect(big, findsOneWidget);
    expect(find.text('Partager FIWICHAT'), findsOneWidget);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(tester.getCenter(big).dx, closeTo(width / 2, 1));

    await tester.tap(big);
    await tester.pumpAndSettle();
    expect(find.text('Envoyer à côté'), findsOneWidget);
    expect(find.text('Avec un QR code'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Pour la personne qui reçoit'), 200);
    expect(find.textContaining('Installer quand même'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('share-quick')), -200);

    await tester.tap(find.byKey(const Key('share-quick')));
    await tester.pump();
    final share = calls.singleWhere((c) => c.method == 'shareApk');
    expect((share.arguments as Map)['via'], 'quickshare');
  });
}
