import 'package:fiwichat/crypto.dart';
import 'package:fiwichat/main.dart';
import 'package:fiwichat/mesh.dart';
import 'package:fiwichat/settings.dart';
import 'package:fiwichat/vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppConfig.locked.value = false;
    AppConfig.pinSet = false;
    AppConfig.textScale.value = 1.0;
  });

  testWidgets('premier lancement : présentation puis choix du pseudo', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(const FiwiApp());
    await tester.pumpAndSettle();
    expect(find.text('Bienvenue sur FIWICHAT'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('onboarding-next')));
      await tester.pumpAndSettle();
    }
    expect(find.text('Invite tes amis'), findsOneWidget);
    expect(find.text('C\'est parti !'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Ton pseudo'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('introSeen'), isTrue);
    // L'identité est rangée chiffrée, pas en clair.
    expect(prefs.getString('secret'), isNull);
    expect(prefs.getString('secret.enc'), isNotNull);
  });

  testWidgets('taille du texte réglable', (tester) async {
    await phone(tester);
    final prefs = await SharedPreferences.getInstance();
    AppConfig.prefs = prefs;
    await tester.pumpWidget(const FiwiApp(home: SettingsScreen()));
    await tester.pumpAndSettle();
    final sample = find.textContaining('Exemple');
    final before = tester.getSize(sample).height;
    await tester.tap(find.byKey(const Key('text-Très grand')));
    await tester.pumpAndSettle();
    expect(AppConfig.textScale.value, 1.45);
    expect(tester.getSize(sample).height, greaterThan(before * 1.3));
    expect(prefs.getDouble('textScale'), 1.45);
  });

  testWidgets('code PIN : choisir, verrouiller, se tromper, ouvrir', (
    tester,
  ) async {
    await phone(tester);
    final prefs = await SharedPreferences.getInstance();
    final vault = Vault(prefs);
    await tester.runAsync(vault.open);
    await AppConfig.load(prefs, vault);
    await tester.pumpWidget(const FiwiApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    Future<void> type(String code) async {
      for (final d in code.split('')) {
        await tester.tap(find.byKey(Key('pin-$d')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('pin-ok')));
      await tester.runAsync(() => Future.delayed(const Duration(seconds: 2)));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('pin-switch')));
    await tester.pumpAndSettle();
    expect(find.text('Choisis un code'), findsOneWidget);
    await type('2580');
    expect(find.text('Tape-le encore une fois'), findsOneWidget);
    await type('2580');
    expect(AppConfig.pinSet, isTrue);
    expect(await tester.runAsync(vault.hasPin), isTrue);

    await tester.pump(const Duration(seconds: 6)); // le petit message disparaît
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verrouiller maintenant'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-screen')), findsOneWidget);
    expect(
      find.text('Réglages'),
      findsNothing,
      reason: 'rien ne se voit derrière',
    );
    await type('1111');
    expect(find.textContaining('Code faux'), findsOneWidget);
    expect(AppConfig.locked.value, isTrue);
    await type('2580');
    expect(AppConfig.locked.value, isFalse);
    expect(find.byKey(const Key('lock-screen')), findsNothing);
  });

  testWidgets(
    'appui long : copier et effacer un message, vider la conversation',
    (tester) async {
      await phone(tester);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'] as String;
          return null;
        },
      );
      final mesh = MeshNode(me: Identity.generate(), myName: 'Moi');
      mesh.send(kGroupId, 'premier');
      mesh.send(kGroupId, 'second');
      await tester.pumpWidget(
        FiwiApp(
          home: ChatScreen(mesh: mesh, convo: kGroupId, title: 'Salon général'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.text('premier'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('msg-copy')));
      await tester.pumpAndSettle();
      expect(copied, 'premier');

      await tester.longPress(find.text('premier'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('msg-delete')));
      await tester.pumpAndSettle();
      expect(find.text('premier'), findsNothing);
      expect(find.text('second'), findsOneWidget);

      await tester.tap(find.byKey(const Key('chat-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vider la conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clear-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Aucun message. Dis bonjour !'), findsOneWidget);
    },
  );

  testWidgets('toucher une notification ouvre la bonne conversation', (
    tester,
  ) async {
    await phone(tester);
    final mesh = MeshNode(me: Identity.generate(), myName: 'Moi');
    final friend = Identity.generate();
    mesh.people[friend.id] = Person(friend.id, 'Karim')..encId = friend.encId;
    final services = AppServices(mesh);
    await tester.pumpWidget(FiwiApp(home: HomeScreen(services: services)));
    await tester.pumpAndSettle();
    services.openConversation(friend.id);
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.textContaining('Karim #'), findsWidgets);
    // Une notification du salon pendant qu'on est dans une autre conversation.
    services.openConversation(kGroupId);
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.text('Salon général'), findsOneWidget);
    // Une notification inconnue ne fait rien.
    services.openConversation('inconnu');
    await tester.pumpAndSettle();
    expect(find.text('Salon général'), findsOneWidget);
  });
}
