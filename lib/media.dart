// FIWICHAT - photos et vidéos.
//
// Un fichier est d'abord chiffré en entier (XSalsa20-Poly1305, clé jetable),
// puis découpé en petits morceaux de 9 Ko qui circulent dans le maillage comme
// les messages ("fc"). La clé, la liste des empreintes des morceaux et le type
// de fichier voyagent dans le message lui-même :
//  * salon général : message signé (tout le monde peut voir la photo, c'est le but) ;
//  * privé : dans l'enveloppe chiffrée, donc seul le destinataire peut ouvrir la photo.
// Les relais font suivre des morceaux illisibles, sans savoir à qui ils sont.
// Si des morceaux se perdent, le destinataire redemande seulement ceux-là ("fneed").
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pinenacl/tweetnacl.dart';

const int kChunkBytes = 9000; // morceau chiffré : ~12 Ko une fois en texte
const int kMaxChunks = 1000;
const int kMaxMediaBytes = kChunkBytes * kMaxChunks - 64; // ~8,5 Mo
const int _hashLen = 6; // empreinte de chaque morceau (6 octets = 8 caractères)

Uint8List _rand(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List _sha512(Uint8List data) {
  final out = Uint8List(64);
  TweetNaCl.crypto_hash(out, data);
  return out;
}

/// Chiffre [plain] (même format que nacl.secretbox de tweetnacl-js).
Uint8List secretboxSeal(Uint8List plain, Uint8List nonce, Uint8List key) {
  final m = Uint8List(32 + plain.length)
    ..setRange(32, 32 + plain.length, plain);
  final c = Uint8List(m.length);
  return TweetNaCl.crypto_secretbox(c, m, m.length, nonce, key);
}

/// Déchiffre ; renvoie null si le contenu a été modifié.
Uint8List? secretboxOpen(Uint8List box, Uint8List nonce, Uint8List key) {
  if (box.length < 16) return null;
  final c = Uint8List(16 + box.length)..setRange(16, 16 + box.length, box);
  final m = Uint8List(c.length);
  try {
    return TweetNaCl.crypto_secretbox_open(m, c, c.length, nonce, key);
  } catch (_) {
    return null;
  }
}

String chunkHash(Uint8List chunk) =>
    base64Encode(_sha512(chunk).sublist(0, _hashLen));

/// Description d'une photo ou vidéo, envoyée avec le message.
class MediaMeta {
  MediaMeta({
    required this.fid,
    required this.kind,
    required this.mime,
    required this.size,
    required this.n,
    required this.key,
    required this.nonce,
    required this.hashes,
    this.durationMs,
  });

  final String fid; // identifiant aléatoire du fichier
  final String kind; // 'photo', 'video' ou 'audio' (message vocal)
  final String mime;
  final int size; // taille du fichier en clair
  final int n; // nombre de morceaux
  final String key, nonce; // base64
  final String hashes; // n empreintes de 8 caractères, à la suite

  /// Durée d'un message vocal (millisecondes), si connue.
  final int? durationMs;

  bool get isVideo => kind == 'video';
  bool get isAudio => kind == 'audio';
  String hashOf(int i) => hashes.substring(i * 8, i * 8 + 8);

  String get extension => switch (mime) {
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'video/webm' => 'webm',
    'video/quicktime' => 'mov',
    'video/3gpp' => '3gp',
    'audio/webm' => 'webm',
    'audio/ogg' => 'ogg',
    'audio/aac' => 'aac',
    'audio/mpeg' => 'mp3',
    _ => isAudio ? 'm4a' : (isVideo ? 'mp4' : 'jpg'),
  };

  Map<String, dynamic> toJson() => {
    'f': fid,
    'k': kind,
    't': mime,
    's': size,
    'n': n,
    'key': key,
    'no': nonce,
    'hs': hashes,
    if (durationMs != null) 'ms': durationMs,
  };

  /// Lit et vérifie une description reçue (null si elle est invalide).
  static MediaMeta? fromJson(Object? j) {
    if (j is! Map) return null;
    final fid = j['f'], kind = j['k'], mime = j['t'], size = j['s'], n = j['n'];
    final key = j['key'], nonce = j['no'], hs = j['hs'];
    if (fid is! String || fid.isEmpty || fid.length > 40) return null;
    if (kind != 'photo' && kind != 'video' && kind != 'audio') return null;
    final ms = j['ms'];
    if (ms != null && (ms is! int || ms < 0 || ms > 3600000)) return null;
    if (mime is! String || mime.length > 40) return null;
    if (size is! int || n is! int || n < 1 || n > kMaxChunks) return null;
    if (size < 0 || size > kMaxMediaBytes) return null;
    if ((size + 16 + kChunkBytes - 1) ~/ kChunkBytes != n) return null;
    if (key is! String ||
        nonce is! String ||
        hs is! String ||
        hs.length != n * 8)
      return null;
    try {
      if (base64Decode(key).length != 32 || base64Decode(nonce).length != 24)
        return null;
    } catch (_) {
      return null;
    }
    return MediaMeta(
      fid: fid,
      kind: kind as String,
      mime: mime,
      size: size,
      n: n,
      key: key,
      nonce: nonce,
      hashes: hs,
      durationMs: ms as int?,
    );
  }
}

/// Résultat du chiffrement d'un fichier à envoyer.
class PreparedMedia {
  PreparedMedia(this.meta, this.chunks);
  final MediaMeta meta;
  final List<Uint8List> chunks;
}

List<Uint8List> _split(Uint8List box) => [
  for (var i = 0; i < box.length; i += kChunkBytes)
    Uint8List.sublistView(box, i, min(i + kChunkBytes, box.length)),
];

PreparedMedia _prepare((Uint8List, String, String, String, int?) a) {
  final (plain, kind, mime, fid, ms) = a;
  final key = _rand(32), nonce = _rand(24);
  final chunks = _split(secretboxSeal(plain, nonce, key));
  final meta = MediaMeta(
    fid: fid,
    kind: kind,
    mime: mime,
    size: plain.length,
    n: chunks.length,
    key: base64Encode(key),
    nonce: base64Encode(nonce),
    hashes: chunks.map(chunkHash).join(),
    durationMs: ms,
  );
  return PreparedMedia(meta, chunks);
}

/// Lance [f] dans un autre fil. Fonction à part : la tâche n'emporte que [f] et [arg].
Future<T> _bg<A, T>(T Function(A) f, A arg) => Isolate.run(() => f(arg));

/// Chiffre et découpe un fichier (dans un fil séparé pour ne pas figer l'écran).
Future<PreparedMedia> prepareMedia(
  Uint8List plain,
  String kind,
  String mime, {
  int? durationMs,
}) {
  final fid = base64Url.encode(_rand(12));
  return _bg(_prepare, (plain, kind, mime, fid, durationMs));
}

Uint8List? _assemble((List<Uint8List>, String, String) a) {
  final (chunks, key, nonce) = a;
  final total = chunks.fold<int>(0, (s, c) => s + c.length);
  final box = Uint8List(total);
  var o = 0;
  for (final c in chunks) {
    box.setRange(o, o + c.length, c);
    o += c.length;
  }
  return secretboxOpen(box, base64Decode(nonce), base64Decode(key));
}

List<Uint8List> _reseal((Uint8List, String, String) a) {
  final (plain, key, nonce) = a;
  return _split(secretboxSeal(plain, base64Decode(nonce), base64Decode(key)));
}

class _Incoming {
  _Incoming();
  MediaMeta? meta;
  final Map<int, Uint8List> chunks = {};
  DateTime firstSeen = DateTime.now(), lastChunk = DateTime.now();
  int bytes = 0;
  int asks = 0;
  bool assembling = false;
  int get got => chunks.length;
}

/// Reçoit les morceaux, reconstitue les fichiers, et renvoie les morceaux perdus.
class MediaStore {
  MediaStore(this.dir, {required this.sendFrame, this.newId});

  /// Dossier où les photos et vidéos sont rangées.
  final Directory dir;

  /// Envoie un paquet à tous les voisins (fourni par le maillage).
  final void Function(String frame) sendFrame;
  final String Function()? newId;

  /// Fichier reconstitué : identifiant -> chemin.
  void Function(String fid, String path)? onComplete;

  /// Progression d'un fichier en cours : identifiant -> (reçus, total).
  void Function(String fid, int got, int n)? onProgress;

  final Map<String, _Incoming> _incoming = {};

  /// Fichiers complets que je peux renvoyer : identifiant -> (description, chemin).
  final Map<String, (MediaMeta, String)> _held = {};
  final Map<String, DateTime> _lastAnswer = {};
  (String, List<Uint8List>)? _cache; // derniers morceaux recalculés

  /// Morceaux récemment vus (identifiant:numéro) pour ne pas relayer des doublons.
  final Map<String, DateTime> _recent = {};

  Timer? _timer;
  int _totalBytes = 0;
  static const int _maxBuffered = 48 * 1024 * 1024;
  final _rng = Random.secure();

  String _id() =>
      newId?.call() ??
      List.generate(
        12,
        (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 3), (_) => tick());
  }

  void stop() => _timer?.cancel();

  String pathFor(MediaMeta m) => '${dir.path}/${m.fid}.${m.extension}';

  bool isComplete(String fid) => _held.containsKey(fid);

  /// Progression connue d'un fichier en cours (null s'il n'est pas en cours).
  double? progressOf(String fid) {
    final inc = _incoming[fid];
    final m = inc?.meta;
    if (inc == null || m == null) return null;
    return inc.got / m.n;
  }

  /// Un fichier que j'envoie (ou que j'avais déjà) : je peux le renvoyer à la demande.
  void hold(MediaMeta m, String path) => _held[m.fid] = (m, path);

  /// Oublie un fichier (effacé par l'utilisateur) : on ne le renvoie plus.
  void forget(String fid) {
    _held.remove(fid);
    _drop(fid);
    if (_cache?.$1 == fid) _cache = null;
  }

  /// Un message annonce ce fichier : on attend (ou on a déjà) ses morceaux.
  void expect(MediaMeta m) {
    if (_held.containsKey(m.fid)) return;
    final path = pathFor(m);
    if (File(path).existsSync()) {
      hold(m, path);
      onComplete?.call(m.fid, path);
      return;
    }
    final inc = _incoming.putIfAbsent(m.fid, _Incoming.new);
    if (inc.meta != null) return;
    inc.meta = m;
    inc.lastChunk = DateTime.now();
    // Les morceaux arrivés avant le message doivent avoir la bonne empreinte.
    inc.chunks.removeWhere((i, c) {
      final bad = i >= m.n || chunkHash(c) != m.hashOf(i);
      if (bad) {
        inc.bytes -= c.length;
        _totalBytes -= c.length;
      }
      return bad;
    });
    onProgress?.call(m.fid, inc.got, m.n);
    _maybeAssemble(m.fid, inc);
  }

  /// Un morceau reçu. Renvoie false s'il ne faut pas le relayer (doublon récent ou invalide).
  bool onChunk(String fid, int i, Uint8List data) {
    if (fid.isEmpty || fid.length > 40 || i < 0 || i >= kMaxChunks)
      return false;
    if (data.isEmpty || data.length > kChunkBytes) return false;
    final rk = '$fid:$i';
    final now = DateTime.now();
    final seenAt = _recent[rk];
    // Doublon tout récent (plusieurs chemins dans le maillage) : on ne le relaie pas.
    // Fenêtre courte, pour laisser passer les morceaux renvoyés plus tard.
    if (seenAt != null && now.difference(seenAt) < const Duration(seconds: 3))
      return false;
    _recent[rk] = now;
    final held = _held[fid];
    if (held != null) {
      // Déjà complet chez moi : je fais juste suivre, si le morceau est le bon.
      final m = held.$1;
      return i < m.n && chunkHash(data) == m.hashOf(i);
    }
    final inc = _incoming.putIfAbsent(fid, _Incoming.new);
    final m = inc.meta;
    if (m != null && (i >= m.n || chunkHash(data) != m.hashOf(i))) {
      return false; // morceau faux : ni gardé, ni relayé
    }
    if (!inc.chunks.containsKey(i)) {
      inc.chunks[i] = Uint8List.fromList(data);
      inc.bytes += data.length;
      _totalBytes += data.length;
      inc.lastChunk = now;
      if (m != null) onProgress?.call(fid, inc.got, m.n);
      _prune();
    }
    _maybeAssemble(fid, inc);
    return true;
  }

  /// Quelqu'un redemande des morceaux : si j'ai le fichier, je les renvoie.
  Future<void> onNeed(String fid, List<int> missing) async {
    final held = _held[fid];
    if (held == null || missing.isEmpty) return;
    final now = DateTime.now();
    final askedAt = now;
    final last = _lastAnswer[fid];
    if (last != null && now.difference(last) < const Duration(seconds: 3))
      return;
    _lastAnswer[fid] = now;
    // Petite attente au hasard : si un autre téléphone répond avant, on ne double pas.
    await Future.delayed(Duration(milliseconds: _rng.nextInt(1200)));
    final chunks = await _chunksOf(held.$1, held.$2);
    if (chunks == null) return;
    for (final i in missing.take(300)) {
      if (i < 0 || i >= chunks.length) continue;
      // Un autre téléphone l'a déjà renvoyé depuis la demande : inutile de doubler.
      final seenAt = _recent['$fid:$i'];
      if (seenAt != null && seenAt.isAfter(askedAt)) continue;
      sendChunk(fid, i, chunks[i]);
      await Future.delayed(const Duration(milliseconds: 40));
    }
  }

  Future<List<Uint8List>?> _chunksOf(MediaMeta m, String path) async {
    final c = _cache;
    if (c != null && c.$1 == m.fid) return c.$2;
    try {
      final plain = await File(path).readAsBytes();
      final chunks = await _bg(_reseal, (plain, m.key, m.nonce));
      _cache = (m.fid, chunks);
      return chunks;
    } catch (_) {
      return null;
    }
  }

  void sendChunk(String fid, int i, Uint8List data) {
    _recent['$fid:$i'] = DateTime.now();
    sendFrame(
      jsonEncode({
        't': 'fc',
        'id': _id(),
        'h': 0,
        'f': fid,
        'i': i,
        'd': base64Encode(data),
      }),
    );
  }

  /// Envoie tous les morceaux d'un fichier, doucement (25 par seconde),
  /// pour ne pas saturer le Bluetooth.
  Future<void> sendAll(
    PreparedMedia p, {
    void Function(double)? progress,
  }) async {
    for (var i = 0; i < p.chunks.length; i++) {
      sendChunk(p.meta.fid, i, p.chunks[i]);
      progress?.call((i + 1) / p.chunks.length);
      await Future.delayed(const Duration(milliseconds: 40));
    }
  }

  void _maybeAssemble(String fid, _Incoming inc) {
    final m = inc.meta;
    if (m == null || inc.assembling || inc.got < m.n) return;
    inc.assembling = true;
    final ordered = [for (var i = 0; i < m.n; i++) inc.chunks[i]!];
    _bg(_assemble, (ordered, m.key, m.nonce)).then((plain) async {
      if (plain == null || plain.length != m.size) {
        // Impossible normalement (empreintes vérifiées) : on recommence à zéro.
        _drop(fid);
        return;
      }
      await dir.create(recursive: true);
      final path = pathFor(m);
      await File(path).writeAsBytes(plain, flush: true);
      _drop(fid);
      hold(m, path);
      onComplete?.call(fid, path);
    });
  }

  void _drop(String fid) {
    final inc = _incoming.remove(fid);
    if (inc != null) _totalBytes -= inc.bytes;
  }

  /// Garde la mémoire sous contrôle : on oublie d'abord les morceaux sans message.
  void _prune() {
    if (_totalBytes <= _maxBuffered) return;
    final order = _incoming.entries.toList()
      ..sort((a, b) {
        final am = a.value.meta == null ? 0 : 1,
            bm = b.value.meta == null ? 0 : 1;
        if (am != bm) return am - bm;
        return a.value.lastChunk.compareTo(b.value.lastChunk);
      });
    for (final e in order) {
      if (_totalBytes <= _maxBuffered * 3 ~/ 4) break;
      _drop(e.key);
    }
  }

  /// Toutes les 3 s : redemande les morceaux manquants, oublie les vieux restes.
  void tick({DateTime? at}) {
    final now = at ?? DateTime.now();
    _recent.removeWhere(
      (_, t) => now.difference(t) > const Duration(seconds: 30),
    );
    for (final e in _incoming.entries.toList()) {
      final inc = e.value, m = inc.meta;
      if (m == null) {
        // Des morceaux sans message (pas pour moi, ou message pas encore arrivé).
        if (now.difference(inc.lastChunk) > const Duration(minutes: 10))
          _drop(e.key);
        continue;
      }
      if (inc.assembling) continue;
      final wait = Duration(seconds: 6 * (1 << min(inc.asks, 4)));
      if (now.difference(inc.lastChunk) < wait) continue;
      if (inc.asks >= 12)
        continue; // on a assez insisté ; on réessaiera au prochain message
      inc.asks++;
      inc.lastChunk = now;
      final missing = [
        for (var i = 0; i < m.n; i++)
          if (!inc.chunks.containsKey(i)) i,
      ];
      sendFrame(
        jsonEncode({
          't': 'fneed',
          'id': _id(),
          'h': 0,
          'f': e.key,
          'miss': missing.take(300).toList(),
        }),
      );
    }
  }

  /// Relance la demande des morceaux manquants (ex. quand un voisin réapparaît).
  void retryAll() {
    for (final inc in _incoming.values) {
      inc.asks = 0;
      inc.lastChunk = DateTime.fromMillisecondsSinceEpoch(0);
    }
  }
}
