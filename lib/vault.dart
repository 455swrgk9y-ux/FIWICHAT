// FIWICHAT - coffre-fort local : identité, historique et code PIN.
//
// * L'identité secrète et l'historique sont chiffrés (XSalsa20-Poly1305) avec une
//   clé aléatoire gardée dans le coffre du téléphone (Android Keystore). Même en
//   copiant les fichiers de l'appli, on ne peut rien lire sans ce téléphone.
// * Le code PIN n'est jamais enregistré : seulement une empreinte salée et lente
//   à calculer (PBKDF2, 30 000 tours). Après 5 erreurs, il faut attendre (de plus
//   en plus longtemps).
// * Si le coffre du téléphone ne marche pas (rare), on garde l'ancien format
//   plutôt que de perdre les conversations.
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/key_derivation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media.dart' show secretboxSeal, secretboxOpen;

const int kPinRounds = 30000;
const int kPinFreeTries = 5;

Uint8List _random(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List _derive((String, Uint8List, int) a) =>
    PBKDF2.hmac_sha256(Uint8List.fromList(utf8.encode(a.$1)), a.$2, a.$3, 32);

/// Empreinte d'un code PIN : "v1.tours.sel.empreinte".
Future<String> hashPin(
  String pin, {
  Uint8List? salt,
  int rounds = kPinRounds,
}) async {
  final s = salt ?? _random(16);
  final h = await Isolate.run(() => _derive((pin, s, rounds)));
  return 'v1.$rounds.${base64Encode(s)}.${base64Encode(h)}';
}

Future<bool> pinMatches(String pin, String stored) async {
  final parts = stored.split('.');
  if (parts.length != 4 || parts[0] != 'v1') return false;
  final rounds = int.tryParse(parts[1]) ?? 0;
  if (rounds < 1000) return false;
  final again = await hashPin(
    pin,
    salt: base64Decode(parts[2]),
    rounds: rounds,
  );
  // Comparaison à temps constant.
  final a = utf8.encode(again), b = utf8.encode(stored);
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

class Vault {
  Vault(this.prefs, {FlutterSecureStorage? secure})
    : secure =
          secure ??
          const FlutterSecureStorage(
            // Ne JAMAIS tout effacer en cas d'erreur : on perdrait l'identité.
            aOptions: AndroidOptions(resetOnError: false),
          );

  final SharedPreferences prefs;
  final FlutterSecureStorage secure;
  Uint8List? _key;

  /// Vrai si l'historique est chiffré sur ce téléphone.
  bool get encrypted => _key != null;

  static const _keyName = 'fiwichat-vault-key';

  /// Prépare la clé de chiffrement locale (la crée au premier lancement).
  Future<void> open() async {
    for (var attempt = 0; attempt < 3 && _key == null; attempt++) {
      try {
        final k = await secure.read(key: _keyName);
        if (k != null) {
          _key = base64Decode(k);
          break;
        }
        if (prefs.getString('secret.enc') != null) {
          // Le coffre répond mais la clé a disparu (appli restaurée sur un
          // autre téléphone...) : les données chiffrées sont illisibles.
          if (attempt < 2) continue;
          await prefs.remove('secret.enc');
          await prefs.remove('state.enc');
        }
        final fresh = _random(32);
        await secure.write(key: _keyName, value: base64Encode(fresh));
        // On ne s'en sert que si elle se relit bien.
        if (await secure.read(key: _keyName) == base64Encode(fresh)) {
          _key = fresh;
        }
        break;
      } catch (_) {
        // Coffre indisponible : on reste en mode simple.
      }
    }
  }

  String _seal(String plain) {
    final nonce = _random(24);
    final box = secretboxSeal(
      Uint8List.fromList(utf8.encode(plain)),
      nonce,
      _key!,
    );
    return '${base64Encode(nonce)}.${base64Encode(box)}';
  }

  String? _open(String sealed) {
    try {
      final parts = sealed.split('.');
      final out = secretboxOpen(
        base64Decode(parts[1]),
        base64Decode(parts[0]),
        _key!,
      );
      return out == null ? null : utf8.decode(out);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _read(String name) async {
    final enc = prefs.getString('$name.enc');
    if (_key != null && enc != null) return _open(enc);
    final plain = prefs.getString(name);
    // Ancienne version : on chiffre et on efface la copie lisible.
    if (_key != null && plain != null) await _write(name, plain);
    return plain;
  }

  Future<void> _write(String name, String value) async {
    if (_key == null) {
      await prefs.setString(name, value);
      return;
    }
    await prefs.setString('$name.enc', _seal(value));
    await prefs.remove(name);
  }

  Future<void> _delete(String name) async {
    await prefs.remove(name);
    await prefs.remove('$name.enc');
  }

  Future<String?> readSecret() => _read('secret');
  Future<void> writeSecret(String s) => _write('secret', s);
  Future<String?> readState() => _read('state');
  Future<void> writeState(String s) => _write('state', s);
  Future<void> deleteState() => _delete('state');

  /// Vrai s'il y a un secret chiffré qu'on ne peut plus ouvrir.
  bool get lostKey => _key == null && prefs.getString('secret.enc') != null;

  // ---------- Code PIN ----------

  Future<String?> _pinHash() async {
    try {
      final v = await secure.read(key: 'fiwichat-pin');
      if (v != null) return v;
    } catch (_) {}
    return prefs.getString('pin');
  }

  Future<bool> hasPin() async => (await _pinHash()) != null;

  /// Change le code PIN (null = plus de code).
  Future<void> setPin(String? pin) async {
    await prefs.remove('pin');
    await prefs.remove('pinFails');
    await prefs.remove('pinUntil');
    try {
      await secure.delete(key: 'fiwichat-pin');
    } catch (_) {}
    if (pin == null) return;
    final h = await hashPin(pin);
    try {
      await secure.write(key: 'fiwichat-pin', value: h);
      if (await secure.read(key: 'fiwichat-pin') == h) return;
    } catch (_) {}
    await prefs.setString('pin', h);
  }

  /// Temps à attendre avant de pouvoir réessayer (zéro si on peut).
  Duration waitBeforeTry([DateTime? now]) {
    final until = prefs.getInt('pinUntil') ?? 0;
    final left = until - (now ?? DateTime.now()).millisecondsSinceEpoch;
    return left > 0 ? Duration(milliseconds: left) : Duration.zero;
  }

  /// Vérifie le code. Après 5 erreurs : 30 s d'attente, puis 1 min, 2 min...
  Future<bool> checkPin(String pin, [DateTime? now]) async {
    if (waitBeforeTry(now) > Duration.zero) return false;
    final stored = await _pinHash();
    if (stored == null) return true;
    if (await pinMatches(pin, stored)) {
      await prefs.remove('pinFails');
      await prefs.remove('pinUntil');
      return true;
    }
    final fails = (prefs.getInt('pinFails') ?? 0) + 1;
    await prefs.setInt('pinFails', fails);
    if (fails >= kPinFreeTries) {
      final secs = 30 * (1 << min(fails - kPinFreeTries, 10));
      await prefs.setInt(
        'pinUntil',
        (now ?? DateTime.now()).millisecondsSinceEpoch + secs * 1000,
      );
    }
    return false;
  }

  int get pinFails => prefs.getInt('pinFails') ?? 0;
}
