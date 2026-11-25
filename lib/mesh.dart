// FIWICHAT - le "maillage" : chaque téléphone fait suivre les paquets aux autres.
//
// Trois sortes de paquets circulent (en JSON) :
//  * "ann" : « je m'appelle X, voici ma clé publique » (pour la liste des gens).
//  * "grp" : un message du salon général (lisible par tous, c'est le but).
//  * "dm"  : un message privé, chiffré, SANS nom d'expéditeur ni de destinataire
//            visible. Chaque téléphone essaie de l'ouvrir avec sa clé : seul le
//            destinataire y arrive. Tous les téléphones (destinataire compris) le
//            font suivre de la même façon, donc personne ne peut savoir qui l'a lu,
//            et les relais ne voient rien et ne reçoivent aucune notification.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'crypto.dart';

const String kGroupId = 'tous';
const int kMaxHops = 10;
const int kMaxFrame = 16 * 1024; // taille max d'un paquet
const int kMaxText = 2000; // longueur max d'un message
const Duration kMaxAge = Duration(days: 2); // au-delà, un message est considéré comme rejoué

/// Une liaison vers un voisin (Wi-Fi local, Nearby, ou invité dans le navigateur).
abstract class Link {
  String get key;
  String get kind; // 'wifi', 'proche', 'invite'
  void send(String frame);
}

class Person {
  Person(this.id, this.name);
  final String id; // clé publique de signature
  String name;
  String? encId; // clé publique de chiffrement (annoncée et signée)
  int lastAnnTs = 0;
  bool verified = false; // codes comparés en face à face
  bool guest = false;
  DateTime lastSeen = DateTime.now();
  bool get online => DateTime.now().difference(lastSeen) < const Duration(seconds: 50);
  String get tag => shortTag(id);
}

class ChatMessage {
  ChatMessage({
    required this.fromId,
    required this.fromName,
    required this.text,
    required this.time,
    this.mine = false,
    this.mid,
    this.delivered = false,
    this.failed = false,
  });
  final String fromId, fromName, text;
  final DateTime time;
  final bool mine;
  final String? mid;
  bool delivered;
  bool failed;

  Map<String, dynamic> toJson() => {
        'f': fromId,
        'n': fromName,
        'x': text,
        't': time.millisecondsSinceEpoch,
        if (mine) 'm': true,
        if (mid != null) 'i': mid,
        if (delivered) 'd': true,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        fromId: j['f'] as String,
        fromName: j['n'] as String,
        text: j['x'] as String,
        time: DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
        mine: j['m'] == true,
        mid: j['i'] as String?,
        delivered: j['d'] == true,
      );
}

/// Notification à afficher (uniquement pour MES messages, jamais pour un relais).
class IncomingNotice {
  IncomingNotice(this.convo, this.title, this.body);
  final String convo, title, body;
}

class MeshNode {
  MeshNode({required this.me, required this.myName, this.guest = false});

  final Identity me;
  String myName;
  final bool guest;

  final Map<String, Link> links = {};
  final Map<String, Person> people = {};
  final Map<String, List<ChatMessage>> conversations = {kGroupId: []};
  final Map<String, int> unread = {};
  String? openConversation;

  /// Dernière annonce connue de chaque personne (pour présenter tout le monde aux nouveaux voisins).
  final Map<String, (String, DateTime)> _lastAnnounce = {};
  final LinkedHashSet<String> _seen = LinkedHashSet();
  final _rng = Random.secure();
  Timer? _timer;
  // Anti-spam : chaque liaison a un "seau" de jetons (60 paquets d'avance, +20 par seconde).
  final Map<String, (double, DateTime)> _buckets = {};
  int dropped = 0;

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  final _notices = StreamController<IncomingNotice>.broadcast();
  Stream<IncomingNotice> get notices => _notices.stream;

  String get myId => me.id;

  void start() {
    _announce();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      _announce();
      _notify();
    });
  }

  void stop() => _timer?.cancel();

  String _newId() => List.generate(12, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  bool _markSeen(String id) {
    if (_seen.contains(id)) return false;
    _seen.add(id);
    if (_seen.length > 5000) _seen.remove(_seen.first);
    return true;
  }

  // ---------- Liaisons ----------

  void addLink(Link link) {
    final isNew = !links.containsKey(link.key);
    links[link.key] = link;
    if (isNew) {
      // On se présente, et on présente les gens qu'on connaît déjà.
      _announce();
      final now = DateTime.now();
      for (final (f, at) in _lastAnnounce.values) {
        // Seulement les gens encore là (vus récemment).
        if (now.difference(at) < const Duration(seconds: 50)) link.send(f);
      }
    }
    _notify();
  }

  void removeLink(String key) {
    links.remove(key);
    _notify();
  }

  String get myTag => shortTag(myId);

  static String _norm(String n) => n.trim().toLowerCase();

  /// Vrai si une autre personne (en ligne ou avec qui j'ai parlé) a ce pseudo.
  bool nameUsedByOther(String name, {String? exceptId}) => people.values.any((p) =>
      p.id != exceptId && _norm(p.name) == _norm(name) && (p.online || (conversations[p.id]?.isNotEmpty ?? false)));

  /// Vrai si ce pseudo est porté par plusieurs personnes (moi compris).
  bool isDuplicate(Person p) =>
      _norm(p.name) == _norm(myName) || nameUsedByOther(p.name, exceptId: p.id);

  int linkCount(String kind) => links.values.where((l) => l.kind == kind).length;

  void _flood(String frame, {String? except}) {
    for (final l in links.values.toList()) {
      if (l.key == except) continue;
      try {
        l.send(frame);
      } catch (_) {}
    }
  }

  // ---------- Réception ----------

  /// Appelé par les transports pour chaque paquet reçu.
  void receive(String frame, String fromLink) {
    if (frame.length > kMaxFrame || !_allow(fromLink)) {
      dropped++;
      return;
    }
    Map<String, dynamic> p;
    try {
      p = jsonDecode(frame) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = p['id'];
    if (id is! String || !_markSeen(id)) return;
    final hops = (p['h'] as num?)?.toInt() ?? 0;

    // Les paquets mal signés ou trop vieux ne sont ni affichés ni relayés.
    final ok = switch (p['t']) {
      'ann' => _onAnnounce(p, frame),
      'grp' => _onGroup(p),
      'dm' => _onPrivate(p),
      _ => false,
    };
    if (!ok) return;
    if (hops + 1 < kMaxHops) {
      p['h'] = hops + 1;
      _flood(jsonEncode(p), except: fromLink);
    }
  }

  bool _allow(String link) {
    final now = DateTime.now();
    final (tokens, at) = _buckets[link] ?? (60.0, now);
    final t = (tokens + now.difference(at).inMilliseconds / 50).clamp(0, 60).toDouble();
    if (t < 1) {
      _buckets[link] = (t, now);
      return false;
    }
    _buckets[link] = (t - 1, now);
    return true;
  }

  static List<Object?> annFields(Map<String, dynamic> p) =>
      ['ann', p['id'], p['src'], p['x'], p['name'], p['guest'] == true, p['ts']];
  static List<Object?> grpFields(Map<String, dynamic> p) =>
      ['grp', p['id'], p['src'], p['name'], p['text'], p['ts']];

  bool _tooOld(int ts) =>
      DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts)) > kMaxAge;

  bool _onAnnounce(Map<String, dynamic> p, String frame) {
    final src = p['src'], name = p['name'], x = p['x'], ts = p['ts'];
    if (src is! String || name is! String || x is! String || ts is! int) return false;
    if (name.trim().isEmpty || name.length > 40) return false;
    if (!verifySig(src, annFields(p), p['sig'])) return false;
    if (src == myId) return true;
    final person = people.putIfAbsent(src, () => Person(src, name));
    // Une vieille annonce rejouée ne peut pas remettre un ancien pseudo.
    if (ts < person.lastAnnTs) return false;
    person
      ..lastAnnTs = ts
      ..name = name
      ..encId = x
      ..guest = p['guest'] == true
      ..lastSeen = DateTime.now();
    _lastAnnounce[src] = (frame, DateTime.now());
    _notify();
    return true;
  }

  bool _onGroup(Map<String, dynamic> p) {
    final src = p['src'], name = p['name'], text = p['text'], ts = p['ts'], id = p['id'];
    if (src is! String || name is! String || text is! String || ts is! int) return false;
    if (text.length > kMaxText || _tooOld(ts)) return false;
    if (!verifySig(src, grpFields(p), p['sig'])) return false;
    if (src == myId) return true;
    // Déjà reçu (même après un redémarrage) : c'est un rejeu, on l'ignore.
    if ((conversations[kGroupId] ?? const []).any((m) => m.mid == id && m.fromId == src)) {
      return false;
    }
    people.putIfAbsent(src, () => Person(src, name)).lastSeen = DateTime.now();
    _addMessage(
        kGroupId,
        ChatMessage(
            fromId: src,
            fromName: name,
            text: text,
            mid: id as String,
            time: DateTime.fromMillisecondsSinceEpoch(ts)));
    if (openConversation != kGroupId) {
      _notices.add(IncomingNotice(kGroupId, 'Salon général', '$name #${shortTag(src)} : $text'));
    }
    return true;
  }

  bool _onPrivate(Map<String, dynamic> p) {
    final e = p['e'], c = p['c'];
    if (e is! String || c is! String) return false;
    final opened = openPrivate(me, e, c);
    if (opened == null) return true; // pas pour moi : je fais juste suivre, sans rien afficher.
    final convo = conversations[opened.fromId] ?? const <ChatMessage>[];
    if (_tooOld(opened.ts)) return true;
    final person = people.putIfAbsent(opened.fromId, () => Person(opened.fromId, opened.fromName));
    person.lastSeen = DateTime.now();
    if (opened.ack != null) {
      // Accusé de réception : le destinataire a bien reçu mon message.
      for (final m in convo) {
        if (m.mine && m.mid == opened.ack) m.delivered = true;
      }
      _notify();
      return true;
    }
    final text = opened.text;
    if (text == null || text.length > kMaxText) return true;
    // Déjà reçu : rejeu, on ne l'affiche pas deux fois (mais on renvoie l'accusé).
    final dup = opened.mid != null && convo.any((m) => !m.mine && m.mid == opened.mid);
    // On répond "bien reçu", lui aussi chiffré : les relais ne voient pas la différence.
    if (opened.mid != null && person.encId != null) {
      final ack = _seal({'ack': opened.mid}, opened.fromId);
      if (ack != null) _flood(ack);
    }
    if (dup) return true;
    _addMessage(
        opened.fromId,
        ChatMessage(
            fromId: opened.fromId,
            fromName: opened.fromName,
            text: text,
            mid: opened.mid,
            time: DateTime.fromMillisecondsSinceEpoch(opened.ts)));
    if (openConversation != opened.fromId) {
      _notices.add(
          IncomingNotice(opened.fromId, '${opened.fromName} #${shortTag(opened.fromId)}', text));
    }
    return true;
  }

  /// Fabrique un paquet privé chiffré et signé (null si la clé du destinataire est inconnue).
  String? _seal(Map<String, String?> body, String to, {String? text, int? ts}) {
    final enc = people[to]?.encId;
    if (enc == null) return null;
    final p = {
      't': 'dm',
      'id': _newId(),
      'h': 0,
      ...sealPrivate(
          me: me,
          myName: myName,
          recipientId: to,
          recipientEncId: enc,
          text: text,
          ts: ts ?? DateTime.now().millisecondsSinceEpoch,
          mid: body['mid'],
          ack: body['ack']),
    };
    _markSeen(p['id'] as String);
    return jsonEncode(p);
  }

  // ---------- Envoi ----------

  void _announce() {
    final p = <String, dynamic>{
      't': 'ann',
      'id': _newId(),
      'h': 0,
      'src': myId,
      'x': me.encId,
      'name': myName,
      if (guest) 'guest': true,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    p['sig'] = me.sign(annFields(p));
    final frame = jsonEncode(p);
    _markSeen(p['id'] as String);
    _flood(frame);
  }

  /// Envoie un message dans le salon général ([convo] == kGroupId) ou en privé.
  void send(String convo, String text) {
    final now = DateTime.now();
    final mid = _newId();
    final msg =
        ChatMessage(fromId: myId, fromName: myName, text: text, time: now, mine: true, mid: mid);
    _addMessage(convo, msg);
    final String? frame;
    if (convo == kGroupId) {
      final p = <String, dynamic>{
        't': 'grp',
        'id': mid,
        'h': 0,
        'src': myId,
        'name': myName,
        'text': text,
        'ts': now.millisecondsSinceEpoch,
      };
      p['sig'] = me.sign(grpFields(p));
      _markSeen(mid);
      frame = jsonEncode(p);
    } else {
      frame = _seal({'mid': mid}, convo, text: text, ts: now.millisecondsSinceEpoch);
    }
    if (links.isEmpty || frame == null) msg.failed = true;
    if (frame != null) _flood(frame);
    _notify();
  }

  void rename(String name) {
    myName = name;
    _announce();
  }

  void _addMessage(String convo, ChatMessage msg) {
    conversations.putIfAbsent(convo, () => []).add(msg);
    if (!msg.mine && openConversation != convo) {
      unread[convo] = (unread[convo] ?? 0) + 1;
    }
    _notify();
  }

  /// Sauvegarde (conversations + noms) pour retrouver l'historique après redémarrage.
  String exportState() => jsonEncode({
        'people': {
          for (final p in people.values)
            p.id: {'n': p.name, 'g': p.guest, 'x': p.encId, 'v': p.verified, 'a': p.lastAnnTs}
        },
        'convos': conversations.map((k, v) =>
            MapEntry(k, v.skip(v.length > 300 ? v.length - 300 : 0).map((m) => m.toJson()).toList())),
      });

  void importState(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      (j['people'] as Map<String, dynamic>).forEach((id, v) {
        final p = people.putIfAbsent(id, () => Person(id, (v as Map)['n'] as String));
        p.guest = (v as Map)['g'] == true;
        p.encId = v['x'] as String?;
        p.verified = v['v'] == true;
        p.lastAnnTs = (v['a'] as num?)?.toInt() ?? 0;
        p.lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
      });
      (j['convos'] as Map<String, dynamic>).forEach((k, v) {
        conversations[k] = (v as List)
            .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
            .toList();
      });
      conversations.putIfAbsent(kGroupId, () => []);
    } catch (_) {}
    _notify();
  }

  void setVerified(String id, bool v) {
    people[id]?.verified = v;
    _notify();
  }

  void markRead(String convo) {
    unread.remove(convo);
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
