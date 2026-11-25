import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Person;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crypto.dart';
import 'guest_server.dart';
import 'mesh.dart';
import 'transport_lan.dart';
import 'transport_nearby.dart';

const _wifiChannel = MethodChannel('fiwichat/wifi');
const brand = Color(0xFF00897B);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FiwiApp());
}

class FiwiApp extends StatelessWidget {
  const FiwiApp({super.key, this.home});
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FIWICHAT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: brand, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: brand,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: home ?? const StartScreen(),
    );
  }
}

/// Tout ce qui tourne en arrière-plan : maillage, transports, page invité, notifications.
class AppServices {
  AppServices(this.mesh)
    : lan = LanTransport(mesh),
      nearby = NearbyTransport(mesh),
      guests = GuestServer(mesh);

  final MeshNode mesh;
  final LanTransport lan;
  final NearbyTransport nearby;
  final GuestServer guests;
  final _notifs = FlutterLocalNotificationsPlugin();
  int _notifId = 0;

  Timer? _saveTimer;

  Future<void> start() async {
    try {
      await _wifiChannel.invokeMethod('acquireMulticastLock');
    } catch (_) {}
    // Historique des conversations (gardé uniquement sur ce téléphone).
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('state');
    if (saved != null) mesh.importState(saved);
    mesh.changes.listen((_) {
      _saveTimer?.cancel();
      _saveTimer = Timer(
        const Duration(seconds: 2),
        () => prefs.setString('state', mesh.exportState()),
      );
    });
    mesh.start();
    await lan.start();
    try {
      await guests.startServer();
    } catch (_) {}
    await _initNotifications();
    await nearby.start();
    try {
      // Android : garde FIWICHAT actif en arrière-plan pour recevoir et relayer.
      await _wifiChannel.invokeMethod('startKeepAlive');
    } catch (_) {}
  }

  Future<void> _initNotifications() async {
    try {
      await _notifs.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      await _notifs
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      // Seuls les messages qui me sont destinés arrivent ici (jamais ceux que je relaie).
      mesh.notices.listen((n) {
        _notifs.show(
          id: _notifId++ % 1000,
          title: n.title,
          body: n.body,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'messages',
              'Messages',
              importance: Importance.high,
              priority: Priority.high,
            ),
            iOS: DarwinNotificationDetails(),
          ),
        );
      });
    } catch (_) {}
  }
}

// ======================= Écran de départ =======================

class StartScreen extends StatefulWidget {
  const StartScreen({super.key});
  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  final _name = TextEditingController();
  late Identity _identity;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    Identity? id;
    try {
      final sk = prefs.getString('secret');
      if (sk != null) id = Identity.fromBase64(sk);
    } catch (_) {
      // Ancienne version : nouvelle identité (et on repart d'un historique vide).
      await prefs.remove('state');
    }
    if (id == null) {
      id = Identity.generate();
      await prefs.setString('secret', id.secretBase64);
    }
    _identity = id;
    final saved = prefs.getString('name');
    if (saved != null && saved.isNotEmpty) {
      _name.text = saved;
      await _go();
      return;
    }
    setState(() => _loading = false);
  }

  Future<void> _go() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('name', name);
    final services = AppServices(MeshNode(me: _identity, myName: name));
    try {
      await services.start();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impossible de démarrer le réseau : $e')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HomeScreen(services: services)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: _loading
              ? const CircularProgressIndicator()
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_tethering, size: 72, color: brand),
                      const SizedBox(height: 12),
                      Text(
                        'FIWICHAT',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Discute par Wi-Fi, sans internet.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),
                      TextField(
                        controller: _name,
                        autofocus: true,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Ton pseudo',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _go(),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _go,
                          child: const Text('Commencer'),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// Ouvre l'écran « Partager FIWICHAT ».
void _share(BuildContext context, AppServices services) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => ShareAppScreen(services: services)));
}

// ======================= Liste des conversations =======================

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.services});
  final AppServices services;
  MeshNode get mesh => services.mesh;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: mesh.changes,
      builder: (context, _) {
        final online = mesh.people.values.where((p) => p.online).toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
        final offline = mesh.people.values
            .where(
              (p) =>
                  !p.online && (mesh.conversations[p.id]?.isNotEmpty ?? false),
            )
            .toList();
        final n = online.length;
        return Scaffold(
          appBar: AppBar(
            title: const Text('FIWICHAT'),
            actions: [
              IconButton(
                icon: const Icon(Icons.qr_code_2),
                tooltip: 'Inviter dans le navigateur',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => GuestScreen(services: services),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.info_outline),
                tooltip: 'Connexion manuelle',
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => ManualConnectDialog(services: services),
                ),
              ),
            ],
          ),
          floatingActionButtonLocation:
              FloatingActionButtonLocation.centerFloat,
          floatingActionButton: SizedBox(
            height: 64,
            child: FloatingActionButton.extended(
              key: const Key('share-big'),
              onPressed: () => _share(context, services),
              backgroundColor: brand,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.send_to_mobile, size: 28),
              label: const Text(
                'Partager FIWICHAT',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 110),
            children: [
              _LinksBar(mesh: mesh),
              if (mesh.nameUsedByOther(mesh.myName))
                Card(
                  margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber_rounded),
                    title: Text(
                      'Quelqu\'un d\'autre s\'appelle aussi « ${mesh.myName} »',
                    ),
                    subtitle: Text(
                      'Ton code #${mesh.myTag} vous distingue. Tu peux aussi changer de pseudo.',
                    ),
                    trailing: TextButton(
                      onPressed: () => showDialog(
                        context: context,
                        builder: (_) => ManualConnectDialog(services: services),
                      ),
                      child: const Text('Changer'),
                    ),
                  ),
                ),
              _tile(
                context,
                avatar: const Icon(Icons.groups),
                title: 'Salon général',
                subtitle: n == 0
                    ? 'Personne pour l\'instant'
                    : '$n personne${n > 1 ? 's' : ''} connectée${n > 1 ? 's' : ''}',
                convo: kGroupId,
                active: true,
              ),
              const Divider(),
              if (online.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text(
                        'Recherche des téléphones FIWICHAT autour de toi...\n\n'
                        'Ils apparaissent tout seuls s\'ils sont sur le même Wi-Fi, '
                        'ou à proximité avec FIWICHAT ouvert. '
                        'Quelqu\'un n\'a pas l\'appli ? Touche « Partager FIWICHAT » en bas.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              for (final p in online)
                _tile(
                  context,
                  avatar: Text(
                    p.name.isEmpty ? '?' : p.name[0].toUpperCase(),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  title: p.name,
                  subtitle:
                      '${mesh.isDuplicate(p) ? '⚠ Même pseudo qu\'un autre · ' : ''}#${p.tag}${p.verified ? ' ✓ vérifié' : ''} · en ligne${p.guest ? ' · invité' : ''}',
                  convoTitle: '${p.name} #${p.tag}',
                  convo: p.id,
                  active: true,
                ),
              for (final p in offline)
                _tile(
                  context,
                  avatar: Text(p.name.isEmpty ? '?' : p.name[0].toUpperCase()),
                  title: p.name,
                  subtitle:
                      '#${p.tag}${p.verified ? ' ✓ vérifié' : ''} · hors de portée',
                  convoTitle: '${p.name} #${p.tag}',
                  convo: p.id,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _tile(
    BuildContext context, {
    required Widget avatar,
    required String title,
    required String subtitle,
    required String convo,
    String? convoTitle,
    bool active = false,
  }) {
    final unread = mesh.unread[convo] ?? 0;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: active ? brand : Colors.grey,
        foregroundColor: Colors.white,
        child: avatar,
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      trailing: unread > 0
          ? Badge(label: Text('$unread'), backgroundColor: brand)
          : const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              ChatScreen(mesh: mesh, convo: convo, title: convoTitle ?? title),
        ),
      ),
    );
  }
}

/// Petite barre qui montre par où passent les messages.
class _LinksBar extends StatelessWidget {
  const _LinksBar({required this.mesh});
  final MeshNode mesh;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget chip(IconData icon, String label, int n) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Chip(
        avatar: Icon(icon, size: 18, color: n > 0 ? brand : scheme.outline),
        label: Text('$label $n'),
        visualDensity: VisualDensity.compact,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Wrap(
        runSpacing: 4,
        children: [
          chip(Icons.wifi, 'Wi-Fi', mesh.linkCount('wifi')),
          chip(Icons.bluetooth_searching, 'Proches', mesh.linkCount('proche')),
          chip(Icons.qr_code_2, 'Invités', mesh.linkCount('invite')),
        ],
      ),
    );
  }
}

// ======================= Conversation =======================

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.mesh,
    required this.convo,
    required this.title,
  });
  final MeshNode mesh;
  final String convo;
  final String title;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.mesh.openConversation = widget.convo;
    widget.mesh.markRead(widget.convo);
  }

  @override
  void dispose() {
    widget.mesh.openConversation = null;
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    widget.mesh.send(widget.convo, text);
  }

  @override
  Widget build(BuildContext context) {
    final isGroup = widget.convo == kGroupId;
    final scheme = Theme.of(context).colorScheme;
    final person = isGroup ? null : widget.mesh.people[widget.convo];
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(
              child: Text(widget.title, overflow: TextOverflow.ellipsis),
            ),
            if (person?.verified ?? false)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.verified, color: brand, size: 20),
              ),
          ],
        ),
        actions: [
          if (person != null)
            IconButton(
              icon: const Icon(Icons.verified_user_outlined),
              tooltip: 'Vérifier en face à face',
              onPressed: () async {
                await showDialog(
                  context: context,
                  builder: (_) =>
                      VerifyDialog(mesh: widget.mesh, person: person),
                );
                setState(() {});
              },
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: scheme.surfaceContainerHigh,
              child: Text(
                isGroup
                    ? 'Tout le monde voit les messages de ce salon.'
                    : '🔒 Privé et chiffré : seul(e) ${widget.title} peut lire. '
                          'Les téléphones qui relaient ne voient rien.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: StreamBuilder<void>(
                stream: widget.mesh.changes,
                builder: (context, _) {
                  final msgs = widget.mesh.conversations[widget.convo] ?? [];
                  if (msgs.isEmpty) {
                    return const Center(
                      child: Text('Aucun message. Dis bonjour !'),
                    );
                  }
                  return ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: msgs.length,
                    itemBuilder: (context, i) {
                      final m = msgs[msgs.length - 1 - i];
                      final time =
                          '${m.time.hour.toString().padLeft(2, '0')}:${m.time.minute.toString().padLeft(2, '0')}';
                      return Align(
                        alignment: m.mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.78,
                          ),
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: m.mine
                                ? scheme.primaryContainer
                                : scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (isGroup && !m.mine)
                                Text(
                                  '${m.fromName} #${shortTag(m.fromId)}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: scheme.primary,
                                    fontSize: 13,
                                  ),
                                ),
                              Text(
                                m.text,
                                style: const TextStyle(fontSize: 16),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                m.failed
                                    ? '$time · personne à portée'
                                    : (m.delivered ? '$time · ✓ reçu' : time),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: m.failed
                                      ? scheme.error
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      textCapitalization: TextCapitalization.sentences,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: 'Écris un message',
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Comparer les empreintes en face à face : si elles sont identiques sur les deux
/// téléphones, personne ne s'est glissé entre vous.
class VerifyDialog extends StatelessWidget {
  const VerifyDialog({super.key, required this.mesh, required this.person});
  final MeshNode mesh;
  final Person person;

  @override
  Widget build(BuildContext context) {
    const mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 18,
      fontWeight: FontWeight.bold,
    );
    return AlertDialog(
      title: Text('Vérifier ${person.name}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Mettez vos deux téléphones côte à côte. Sur son téléphone, '
              'cette personne ouvre ta conversation et touche aussi le bouclier.',
            ),
            const SizedBox(height: 12),
            Text('Son empreinte (${person.name})'),
            SelectableText(fingerprint(person.id), style: mono),
            const SizedBox(height: 12),
            Text('Ton empreinte (${mesh.myName})'),
            SelectableText(fingerprint(mesh.myId), style: mono),
            const SizedBox(height: 12),
            const Text(
              'Si les empreintes sont identiques des deux côtés, touche « C\'est bien elle/lui ».',
            ),
          ],
        ),
      ),
      actions: [
        if (person.verified)
          TextButton(
            onPressed: () {
              mesh.setVerified(person.id, false);
              Navigator.pop(context);
            },
            child: const Text('Retirer la vérification'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
        if (!person.verified)
          FilledButton(
            onPressed: () {
              mesh.setVerified(person.id, true);
              Navigator.pop(context);
            },
            child: const Text('C\'est bien elle/lui'),
          ),
      ],
    );
  }
}

// ======================= Mode invité =======================

class GuestScreen extends StatefulWidget {
  const GuestScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<GuestScreen> createState() => _GuestScreenState();
}

class _GuestScreenState extends State<GuestScreen> {
  bool _busy = false;
  GuestServer get guests => widget.services.guests;

  Future<void> _open() async {
    setState(() => _busy = true);
    await NearbyTransport.requestPermissions();
    await guests.openHotspot();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _close() async {
    await guests.closeHotspot();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final h = guests.hotspot;
    final lanIps = widget.services.lan.myAddresses.where(
      (a) => !a.startsWith('192.168.49.'),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Inviter quelqu\'un')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Quelqu\'un à côté de toi n\'a pas FIWICHAT ? Il peut discuter depuis son '
            'navigateur, sans rien installer et sans internet.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 20),
          if (h == null) ...[
            FilledButton.icon(
              onPressed: _busy ? null : _open,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering),
              label: const Text('Ouvrir le réseau Wi-Fi FIWICHAT'),
            ),
            if (guests.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  guests.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ] else ...[
            _Step(
              n: 1,
              title: 'Se connecter au Wi-Fi',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Réseau : ${h.ssid}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Mot de passe : ${h.password}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text('Ou scanner ce code avec l\'appareil photo :'),
                  const SizedBox(height: 8),
                  Center(child: _Qr(h.wifiQr)),
                ],
              ),
            ),
            _Step(
              n: 2,
              title: 'Ouvrir le chat dans le navigateur',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    h.url,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(child: _Qr(h.url)),
                  const SizedBox(height: 8),
                  const Text(
                    'Si le téléphone dit « pas d\'internet », choisir « Rester connecté ».',
                  ),
                ],
              ),
            ),
            _Step(
              n: 3,
              title: 'Installer FIWICHAT (Android)',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sur la page du chat, le bouton « Télécharger FIWICHAT » donne l\'appli. '
                    'Ou scanner ce code une fois connecté au Wi-Fi :',
                  ),
                  const SizedBox(height: 8),
                  Center(child: _Qr(h.installerUrl)),
                ],
              ),
            ),
            OutlinedButton(
              onPressed: _close,
              child: const Text('Fermer le réseau invité'),
            ),
          ],
          const SizedBox(height: 24),
          const Divider(),
          const Text(
            'Donner l\'appli à quelqu\'un à côté, sans internet :',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () => _share(context, widget.services),
            icon: const Icon(Icons.send_to_mobile),
            label: const Text('Partager FIWICHAT'),
          ),
          const SizedBox(height: 4),
          const Text(
            'Chaque personne qui l\'a reçue peut la redonner à son tour.',
            style: TextStyle(fontSize: 13),
          ),
          if (lanIps.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Divider(),
            const Text(
              'Déjà sur le même Wi-Fi que toi ? Il suffit d\'ouvrir :',
            ),
            for (final ip in lanIps)
              SelectableText(
                'http://$ip:$kGuestPort',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.title, required this.child});
  final int n;
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: brand,
                foregroundColor: Colors.white,
                child: Text('$n'),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class _Qr extends StatelessWidget {
  const _Qr(this.data);
  final String data;
  @override
  Widget build(BuildContext context) => Container(
    color: Colors.white,
    padding: const EdgeInsets.all(8),
    child: QrImageView(data: data, size: 180),
  );
}

// ======================= Partager FIWICHAT =======================

class ShareAppScreen extends StatelessWidget {
  const ShareAppScreen({super.key, required this.services});
  final AppServices services;

  Future<void> _send(BuildContext context, String? via) async {
    final ok = await shareApp(via: via);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Ça n\'a pas marché ici. Utilise plutôt « Avec un QR code ».',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Partager FIWICHAT')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const Text(
            'Donne l\'appli à quelqu\'un à côté de toi. Pas besoin d\'internet.',
            style: TextStyle(fontSize: 17),
          ),
          const SizedBox(height: 16),
          _BigChoice(
            key: const Key('share-quick'),
            icon: Icons.near_me,
            title: 'Envoyer à côté',
            subtitle: 'Avec Quick Share. Le plus rapide.',
            onTap: () => _send(context, 'quickshare'),
          ),
          const SizedBox(height: 12),
          _BigChoice(
            key: const Key('share-qr'),
            icon: Icons.qr_code_2,
            title: 'Avec un QR code',
            subtitle: 'L\'autre scanne avec son appareil photo. Marche sur tous les Android.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => QrInstallScreen(services: services),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              TextButton.icon(
                onPressed: () => _send(context, 'bluetooth'),
                icon: const Icon(Icons.bluetooth),
                label: const Text('Par Bluetooth'),
              ),
              TextButton.icon(
                onPressed: () => _send(context, null),
                icon: const Icon(Icons.more_horiz),
                label: const Text('Autres façons'),
              ),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => GuestScreen(services: services),
                  ),
                ),
                icon: const Icon(Icons.phone_iphone),
                label: const Text('Il a un iPhone'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Avec Quick Share',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '• L\'autre téléphone doit avoir le Bluetooth et la localisation allumés.\n'
                    '• Sur l\'autre téléphone : glisser du haut de l\'écran, appuyer sur '
                    '« Quick Share » et choisir « Tout le monde ».\n'
                    '• Ici, choisis son téléphone dans la liste. Il appuie sur « Accepter ».\n'
                    '• Ça ne marche pas ? Prends « Avec un QR code ».',
                    style: TextStyle(color: muted, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const ReceiverSteps(),
        ],
      ),
    );
  }
}

class _BigChoice extends StatelessWidget {
  const _BigChoice({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: brand,
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(icon, size: 44, color: Colors.white),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white, size: 30),
          ],
        ),
      ),
    ),
  );
}

/// Ce que doit faire la personne qui reçoit le fichier (à lui montrer).
class ReceiverSteps extends StatelessWidget {
  const ReceiverSteps({super.key});
  static const steps = [
    'Ouvrir le fichier fiwichat.apk reçu (notification, ou Fichiers › Téléchargements).',
    'Si Android bloque : « Paramètres », activer « Autoriser cette source », puis revenir.',
    'Appuyer sur « Installer ».',
    'Si Play Protect s\'affiche : « Plus de détails » puis « Installer quand même ».',
    'Ouvrir FIWICHAT, choisir un pseudo, et appuyer sur « Autoriser » partout.',
  ];
  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Pour la personne qui reçoit',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: brand,
                    foregroundColor: Colors.white,
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(steps[i], style: const TextStyle(fontSize: 15)),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

/// Partage par QR code : le téléphone ouvre son propre Wi-Fi, l'autre scanne deux codes.
class QrInstallScreen extends StatefulWidget {
  const QrInstallScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<QrInstallScreen> createState() => _QrInstallScreenState();
}

class _QrInstallScreenState extends State<QrInstallScreen> {
  bool _busy = false;
  GuestServer get guests => widget.services.guests;

  @override
  void initState() {
    super.initState();
    if (guests.hotspot == null) _open();
  }

  Future<void> _open() async {
    setState(() => _busy = true);
    await NearbyTransport.requestPermissions();
    await guests.openHotspot();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final h = guests.hotspot;
    return Scaffold(
      appBar: AppBar(title: const Text('Partager avec un QR code')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (h == null) ...[
            const SizedBox(height: 24),
            if (_busy) ...[
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              const Text(
                'Préparation du Wi-Fi FIWICHAT…',
                textAlign: TextAlign.center,
              ),
            ] else ...[
              Text(
                guests.error == null
                    ? 'Le Wi-Fi FIWICHAT n\'a pas pu s\'ouvrir.'
                    : 'Le Wi-Fi FIWICHAT n\'a pas pu s\'ouvrir : ${guests.error}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Vérifie que le Wi-Fi et la localisation sont allumés, puis réessaie.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _open, child: const Text('Réessayer')),
            ],
          ] else ...[
            const Text(
              'Montre cet écran à l\'autre personne. Elle ouvre son appareil photo et scanne.',
              style: TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 12),
            _Step(
              n: 1,
              title: 'Scanner pour se connecter au Wi-Fi',
              child: Column(
                children: [
                  Center(child: _Qr(h.wifiQr)),
                  const SizedBox(height: 8),
                  const Text(
                    'Puis appuyer sur « Se connecter ». S\'il dit « pas d\'internet », '
                    'choisir « Rester connecté ».',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Ou à la main : réseau ${h.ssid}, mot de passe ${h.password}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
            _Step(
              n: 2,
              title: 'Scanner pour télécharger',
              child: Column(
                children: [
                  Center(child: _Qr(h.installerUrl)),
                  const SizedBox(height: 8),
                  const Text(
                    'Une page s\'ouvre avec un gros bouton vert « Télécharger FIWICHAT ».',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'La page ne s\'ouvre pas ? Couper les données mobiles un instant, ou taper '
                    '${h.installerUrl}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
            const ReceiverSteps(),
          ],
        ],
      ),
    );
  }
}

// ======================= Connexion manuelle =======================

class ManualConnectDialog extends StatefulWidget {
  const ManualConnectDialog({super.key, required this.services});
  final AppServices services;
  @override
  State<ManualConnectDialog> createState() => _ManualConnectDialogState();
}

class _ManualConnectDialogState extends State<ManualConnectDialog> {
  final _ip = TextEditingController();
  String? _result;

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: widget.services.mesh.myName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nouveau pseudo'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 30,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    final n = name?.trim() ?? '';
    if (n.isEmpty) return;
    if (widget.services.mesh.nameUsedByOther(n)) {
      setState(
        () => _result =
            '« $n » est déjà pris par quelqu\'un à portée. Choisis un autre pseudo.',
      );
      return;
    }
    widget.services.mesh.rename(n);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('name', n);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final addrs = widget.services.lan.myAddresses;
    final nearby = widget.services.nearby;
    return AlertDialog(
      title: const Text('Connexion'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Tu es « ${widget.services.mesh.myName} » #${widget.services.mesh.myTag}',
                  ),
                ),
                TextButton(onPressed: _rename, child: const Text('Changer')),
              ],
            ),
            const SizedBox(height: 8),
            if (Platform.isAndroid)
              Text(
                nearby.running
                    ? 'Relais à proximité : actif'
                    : 'Relais à proximité : inactif${nearby.error != null ? ' (${nearby.error})' : ''}',
              ),
            const SizedBox(height: 8),
            const Text('Mon adresse Wi-Fi :'),
            SelectableText(
              addrs.isEmpty ? 'Pas de Wi-Fi détecté' : addrs.join('\n'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 16),
            const Text('Un téléphone n\'apparaît pas ? Tape son adresse :'),
            const SizedBox(height: 8),
            TextField(
              controller: _ip,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                hintText: 'ex : 192.168.1.23',
                border: OutlineInputBorder(),
              ),
            ),
            if (_result != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_result!),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
        FilledButton(
          onPressed: () => setState(
            () => _result = widget.services.lan.connectManually(_ip.text)
                ? 'Demande envoyée. La personne va apparaître si FIWICHAT est ouvert.'
                : 'Adresse invalide.',
          ),
          child: const Text('Se connecter'),
        ),
      ],
    );
  }
}
