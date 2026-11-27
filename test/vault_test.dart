import 'package:fiwichat/crypto.dart';
import 'package:fiwichat/vault.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ancienne version : identité et historique sont chiffrés au démarrage',
    () async {
      final id = Identity.generate();
      SharedPreferences.setMockInitialValues({
        'secret': id.secretBase64,
        'state': '{"secret":"historique"}',
      });
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final v = Vault(prefs);
      await v.open();
      expect(v.encrypted, isTrue);
      expect(await v.readSecret(), id.secretBase64);
      expect(await v.readState(), '{"secret":"historique"}');
      // Plus rien de lisible dans les préférences.
      expect(prefs.getString('secret'), isNull);
      expect(prefs.getString('state'), isNull);
      final raw = prefs.getKeys().map((k) => '${prefs.get(k)}').join();
      expect(raw.contains('historique'), isFalse);
      expect(raw.contains(id.secretBase64.split('.').first), isFalse);
      // Au prochain lancement, tout se relit.
      final v2 = Vault(prefs);
      await v2.open();
      expect(await v2.readSecret(), id.secretBase64);
      await v2.writeState('nouveau');
      expect(await v2.readState(), 'nouveau');
    },
  );

  test('coffre du téléphone en panne : on garde les données en clair, sans rien perdre', () async {
    SharedPreferences.setMockInitialValues({'secret': 'abc.def'});
    final prefs = await SharedPreferences.getInstance();
    final v = Vault(prefs, secure: _Broken());
    await v.open();
    expect(v.encrypted, isFalse);
    expect(await v.readSecret(), 'abc.def');
    await v.writeState('x');
    expect(await v.readState(), 'x');
  });

  test('code PIN : empreinte salée, attente après 5 erreurs', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final v = Vault(prefs);
    await v.open();
    expect(await v.hasPin(), isFalse);
    await v.setPin('1234');
    expect(await v.hasPin(), isTrue);
    expect(
      prefs.getKeys().map((k) => '${prefs.get(k)}').join().contains('1234'),
      isFalse,
    );
    expect(await v.checkPin('1234'), isTrue);
    final t = DateTime.now();
    for (var i = 0; i < 5; i++) {
      expect(await v.checkPin('0000', t), isFalse);
    }
    expect(v.waitBeforeTry(t), const Duration(seconds: 30));
    // Même le bon code est refusé pendant l'attente.
    expect(await v.checkPin('1234', t), isFalse);
    final later = t.add(const Duration(seconds: 31));
    expect(await v.checkPin('1234', later), isTrue);
    expect(v.pinFails, 0);
    // Deux personnes avec le même code n'ont pas la même empreinte.
    expect(await hashPin('1234'), isNot(await hashPin('1234')));
    await v.setPin(null);
    expect(await v.hasPin(), isFalse);
  });
}

class _Broken extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw Exception('panne');
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw Exception('panne');
  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw Exception('panne');
}
