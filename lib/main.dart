import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Person;
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crypto.dart';
import 'guest_server.dart';
import 'media.dart';
import 'mesh.dart';
import 'radios.dart';
import 'settings.dart';
import 'vault.dart';
import 'updates.dart';
import 'voice.dart';
import 'transport_lan.dart';
import 'transport_nearby.dart';

const _wifiChannel = MethodChannel('fiwichat/wifi');
const brand = Color(0xFF00897B);

/// Pour ouvrir une conversation depuis une notification.
final navigatorKey = GlobalKey<NavigatorState>();

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
      navigatorKey: navigatorKey,
      builder: (context, child) => AppShell(child: child ?? const SizedBox()),
      home: home ?? const StartScreen(),
    );
  }
}

/// Tout ce qui tourne en arrière-plan : maillage, transports, page invité, notifications.
class AppServices {
  AppServices(this.mesh, {this.vault})
    : lan = LanTransport(mesh),
      nearby = NearbyTransport(mesh),
      guests = GuestServer(mesh) {
    current = this;
  }

  /// Les services en marche (un seul à la fois).
  static AppServices? current;

  final MeshNode mesh;

  /// Coffre-fort local (historique et identité chiffrés). Null dans les tests.
  final Vault? vault;
  AppLifecycleListener? _life;
  final LanTransport lan;
  final NearbyTransport nearby;
  final GuestServer guests;
  final _notifs = FlutterLocalNotificationsPlugin();
  bool _notifsReady = false;

  /// Cherche les nouvelles versions (internet ou téléphones d'à côté).
  final updater = Updater();

  /// État des radios (Bluetooth, Wi-Fi, localisation), relu toutes les 5 s.
  final radios = ValueNotifier<RadioStatus>(const RadioStatus());

  /// Vrai s'il manque une autorisation pour le Bluetooth (appareils à proximité).
  final permsMissing = ValueNotifier<bool>(false);

  /// Redemande les autorisations ; si elles ont été refusées pour de bon,
  /// ouvre les réglages de l'appli.
  Future<void> fixPermissions() async {
    final still = await nearby.checkPermissions(ask: true);
    if (still.isNotEmpty) {
      await NearbyTransport.openSettings();
    } else {
      await nearby.restartSearch();
    }
    permsMissing.value = still.isNotEmpty;
  }

  Timer? _radioTimer;
  int _radioTick = 0;

  Timer? _saveTimer;

  Future<void> start() async {
    try {
      await _wifiChannel.invokeMethod('acquireMulticastLock');
    } catch (_) {}
    // Historique des conversations (gardé uniquement sur ce téléphone).
    final prefs = await SharedPreferences.getInstance();
    final v = vault;
    final saved = v != null ? await v.readState() : prefs.getString('state');
    if (saved != null) mesh.importState(saved);
    // Nouvelle clé de chiffrement du jour : on la garde aussitôt.
    mesh.onIdentityChanged = () => v?.writeSecret(mesh.me.secretBase64);
    // Photos et vidéos : rangées dans l'espace privé de l'appli.
    try {
      final dir = await _wifiChannel.invokeMethod<String>('mediaDir');
      mesh.attachMedia(Directory(dir ?? '${Directory.systemTemp.path}/media'));
    } catch (_) {
      mesh.attachMedia(Directory('${Directory.systemTemp.path}/media'));
    }
    mesh.changes.listen((_) {
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(seconds: 2), () {
        final st = mesh.exportState();
        v != null ? v.writeState(st) : prefs.setString('state', st);
      });
    });
    mesh.start();
    await updater.start();
    lan
      ..myBuild = updater.myBuild
      ..onPeerBuild = updater.notePeer;
    await lan.start();
    try {
      await guests.startServer();
    } catch (_) {}
    await _initNotifications();
    await nearby.start();
    await _watchRadios();
    _radioTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _watchRadios(),
    );
    try {
      // Android : garde FIWICHAT actif en arrière-plan pour recevoir et relayer.
      await _wifiChannel.invokeMethod('startKeepAlive');
    } catch (_) {}
    // Économie de batterie : moins de signaux quand l'appli n'est pas à l'écran.
    _life = AppLifecycleListener(
      onHide: () => setBackground(true),
      onShow: () => setBackground(false),
    );
  }

  /// Arrière-plan : annonces et signaux Wi-Fi moins fréquents, radios non surveillées.
  void setBackground(bool bg) {
    mesh.setBackground(bg);
    lan.setBackground(bg);
    _radioTimer?.cancel();
    if (!bg) {
      _watchRadios();
      _radioTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _watchRadios(),
      );
    }
  }

  void stopWatchingRadios() => _radioTimer?.cancel();

  void dispose() {
    _life?.dispose();
    _radioTimer?.cancel();
  }

  /// Une notification par conversation (la nouvelle remplace l'ancienne).
  static int noticeId(String convo) => convo.hashCode & 0x7fffffff;

  /// Efface la notification d'une conversation qu'on vient d'ouvrir.
  void clearNotice(String convo) {
    if (!_notifsReady) return;
    try {
      unawaited(_notifs.cancel(id: noticeId(convo)).catchError((_) {}));
    } catch (_) {}
  }

  /// Nom affiché en haut d'une conversation.
  String titleOf(String convo) {
    if (convo == kGroupId) return 'Salon général';
    final p = mesh.people[convo];
    return p == null ? 'Conversation' : '${p.name} #${p.tag}';
  }

  /// Ouvre une conversation (après avoir touché une notification).
  void openConversation(String? convo) {
    if (convo == null || convo.isEmpty) return;
    if (convo != kGroupId && !mesh.people.containsKey(convo)) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    nav.popUntil((r) => r.isFirst);
    nav.push(
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(mesh: mesh, convo: convo, title: titleOf(convo)),
      ),
    );
  }

  /// Dès qu'une radio est rallumée, FIWICHAT relance la recherche tout seul.
  Future<void> _watchRadios() async {
    final before = radios.value;
    final now = await RadioStatus.read();
    if (Platform.isAndroid) await nearby.checkPermissions();
    radios.value = now;
    permsMissing.value = nearby.missing.isNotEmpty;
    if (!now.known) return;
    // Une radio allumée OU éteinte : on relance la recherche. Wi-Fi coupé =
    // FIWICHAT continue tout seul par Bluetooth.
    final changed =
        before.known &&
        (now.bluetoothOn != before.bluetoothOn ||
            now.locationOn != before.locationOn ||
            now.wifiOn != before.wifiOn);
    // Si la recherche a échoué, on réessaie calmement (toutes les minutes).
    final retry = !nearby.running && _radioTick++ % 12 == 0;
    if (now.nearbyReady && (changed || retry)) {
      await nearby.restartSearch();
    }
  }

  Future<void> _initNotifications() async {
    try {
      await _notifs.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (r) => openConversation(r.payload),
      );
      _notifsReady = true;
      await _notifs
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      // Seuls les messages qui me sont destinés arrivent ici (jamais ceux que je relaie).
      mesh.notices.listen((n) {
        // Avec un code PIN, la notification ne montre pas le message.
        final hidden = AppConfig.pinSet;
        _notifs.show(
          id: noticeId(n.convo),
          title: hidden ? 'FIWICHAT' : n.title,
          body: hidden ? 'Nouveau message' : n.body,
          payload: n.convo,
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
      // L'appli a été ouverte en touchant une notification.
      final launch = await _notifs.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        final payload = launch!.notificationResponse?.payload;
        Timer(
          const Duration(milliseconds: 600),
          () => openConversation(payload),
        );
      }
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
  late Vault _vault;
  bool _loading = true;
  bool _intro = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // Coffre-fort : identité et historique chiffrés sur ce téléphone.
    _vault = Vault(prefs);
    await _vault.open();
    await AppConfig.load(prefs, _vault);
    Identity? id;
    try {
      final sk = await _vault.readSecret();
      if (sk != null) id = Identity.fromBase64(sk);
    } catch (_) {}
    if (id == null) {
      // Première fois (ou clé illisible) : nouvelle identité, historique vide.
      await _vault.deleteState();
      id = Identity.generate();
      await _vault.writeSecret(id.secretBase64);
    }
    _identity = id;
    final saved = prefs.getString('name');
    if (saved != null && saved.isNotEmpty) {
      _name.text = saved;
      await _go();
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _intro = prefs.getBool('introSeen') != true;
    });
  }

  Future<void> _introDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('introSeen', true);
    if (mounted) setState(() => _intro = false);
  }

  Future<void> _go() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('name', name);
    final services = AppServices(
      MeshNode(me: _identity, myName: name),
      vault: _vault,
    );
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
    if (_intro && !_loading) return OnboardingScreen(onDone: _introDone);
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
                key: const Key('settings'),
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Réglages',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (ctx) => SettingsScreen(
                      encrypted: services.vault?.encrypted ?? false,
                      onShowIntro: () => Navigator.of(ctx).push(
                        MaterialPageRoute(
                          builder: (c2) => OnboardingScreen(
                            onDone: () => Navigator.of(c2).pop(),
                          ),
                        ),
                      ),
                    ),
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
              InkWell(
                key: const Key('links-bar'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ConnectionsScreen(services: services),
                  ),
                ),
                child: _LinksBar(mesh: mesh),
              ),
              _UpdateBanner(services: services),
              _RadiosBanner(services: services),
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
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          chip(Icons.wifi, 'Wi-Fi', mesh.linkCount('wifi')),
          chip(Icons.bluetooth_searching, 'Proches', mesh.linkCount('proche')),
          chip(Icons.qr_code_2, 'Invités', mesh.linkCount('invite')),
          Icon(Icons.chevron_right, color: scheme.outline),
        ],
      ),
    );
  }
}

// ======================= Radios / connexions =======================

/// Bandeau « Nouvelle version » sur l'accueil.
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.services});
  final AppServices services;

  Future<void> _go(BuildContext context) async {
    final msg = await services.updater.downloadAndInstall();
    if (msg != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = services.updater;
    return ValueListenableBuilder<UpdateOffer?>(
      valueListenable: u.offer,
      builder: (context, o, _) {
        if (o == null) return const SizedBox.shrink();
        return ValueListenableBuilder<double?>(
          valueListenable: u.progress,
          builder: (context, p, _) => Card(
            key: const Key('update-banner'),
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            color: brand,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.system_update, color: Colors.white),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Nouvelle version de FIWICHAT',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 17,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    o.fromPhone
                        ? 'Un téléphone à côté de toi l\'a. Tes messages sont gardés.'
                        : 'Elle s\'installe par-dessus celle-ci. Tes messages sont gardés.',
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 10),
                  if (p != null) ...[
                    LinearProgressIndicator(
                      value: p > 0 ? p : null,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Téléchargement… ${(p * 100).round()} %',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ] else
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: brand,
                      ),
                      onPressed: () => _go(context),
                      icon: const Icon(Icons.download),
                      label: const Text('Mettre à jour'),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Bandeau sur l'accueil quand une radio utile est éteinte.
class _RadiosBanner extends StatelessWidget {
  const _RadiosBanner({required this.services});
  final AppServices services;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<RadioStatus>(
    valueListenable: services.radios,
    builder: (context, r, _) {
      final off = r.off;
      if (services.permsMissing.value) {
        return Card(
          key: const Key('perms-banner'),
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          color: Theme.of(context).colorScheme.errorContainer,
          child: ListTile(
            leading: const Icon(Icons.bluetooth_disabled),
            title: const Text(
              'FIWICHAT n\'a pas le droit d\'utiliser le Bluetooth',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              'Sans cette autorisation, les messages ne passent que par le Wi-Fi. '
              'Touche « Autoriser » et accepte « Appareils à proximité ».',
            ),
            trailing: FilledButton(
              key: const Key('perms-fix'),
              onPressed: services.fixPermissions,
              child: const Text('Autoriser'),
            ),
          ),
        );
      }
      if (off.isEmpty) return const SizedBox.shrink();
      return Card(
        key: const Key('radios-banner'),
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        color: Theme.of(context).colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pour trouver plus de téléphones, allume : ${off.map(radioLabel).join(', ')}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final w in off)
                    TextButton.icon(
                      onPressed: () => openRadioSettings(w),
                      icon: Icon(_radioIcon(w)),
                      label: Text(radioAction(w)),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

IconData _radioIcon(String w) => switch (w) {
  'bluetooth' => Icons.bluetooth,
  'wifi' => Icons.wifi,
  _ => Icons.location_on,
};

/// Écran « Connexions » : toutes les façons dont FIWICHAT relie les téléphones.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key, required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final mesh = services.mesh;
    return Scaffold(
      appBar: AppBar(title: const Text('Connexions')),
      body: StreamBuilder<void>(
        stream: mesh.changes,
        builder: (context, _) => ValueListenableBuilder<RadioStatus>(
          valueListenable: services.radios,
          builder: (context, r, _) {
            final nearbyOk = r.nearbyReady;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                const Text(
                  'FIWICHAT utilise toutes les radios de ton téléphone en même temps, '
                  'et choisit toute seule la meilleure. Tu n\'as rien à régler : '
                  'il suffit que tout soit allumé.',
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  'Version de FIWICHAT : 1.0.${services.updater.myBuild ?? '?'}'
                  '${Platform.isAndroid ? ' · Bluetooth : ${services.nearby.running ? 'actif' : 'inactif'}, ${services.nearby.connectedCount} relié(s), ${services.nearby.waitingCount} en cours' : ''}',
                  key: const Key('version-line'),
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                _RadioRow(
                  icon: Icons.wifi,
                  title: 'Wi-Fi (même réseau)',
                  detail:
                      'Téléphones sur la même box, sur le partage de connexion d\'un '
                      'téléphone, ou sur le Wi-Fi FIWICHAT.',
                  on: r.wifiOn,
                  count: mesh.linkCount('wifi'),
                  fix: 'wifi',
                ),
                _RadioRow(
                  icon: Icons.bluetooth,
                  title: 'Bluetooth',
                  detail: r.hasBle
                      ? 'Bluetooth classique et basse consommation (BLE). Trouve les '
                            'téléphones autour de toi, environ 10 à 50 m.'
                      : 'Trouve les téléphones autour de toi, environ 10 m.',
                  on: r.bluetoothOn,
                  available: r.hasBluetooth,
                  count: mesh.linkCount('proche'),
                  fix: 'bluetooth',
                ),
                _RadioRow(
                  icon: Icons.wifi_tethering,
                  title: 'Wi-Fi Direct',
                  detail:
                      'Wi-Fi de téléphone à téléphone, sans box. Plus rapide et plus loin '
                      'que le Bluetooth. S\'active tout seul après le Bluetooth.',
                  on: nearbyOk && r.wifiOn,
                  available: r.hasWifiDirect,
                  fix: r.wifiOn
                      ? (r.bluetoothOn ? 'location' : 'bluetooth')
                      : 'wifi',
                ),
                if (r.hasWifiAware)
                  _RadioRow(
                    icon: Icons.radar,
                    title: 'Wi-Fi Aware',
                    detail: 'Ton téléphone sait aussi se relier en Wi-Fi Aware. Automatique.',
                    on: nearbyOk && r.wifiOn,
                    fix: r.wifiOn
                        ? (r.bluetoothOn ? 'location' : 'bluetooth')
                        : 'wifi',
                  ),
                _RadioRow(
                  icon: Icons.location_on,
                  title: 'Localisation',
                  detail:
                      'Android l\'exige pour chercher les appareils proches. FIWICHAT '
                      'n\'utilise pas ta position et ne l\'envoie à personne.',
                  on: r.locationOn,
                  fix: 'location',
                ),
                _RadioRow(
                  icon: Icons.qr_code_2,
                  title: 'Navigateur (invités)',
                  detail: 'Les personnes sans l\'appli discutent depuis leur navigateur.',
                  on: true,
                  count: mesh.linkCount('invite'),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.cell_tower),
                            SizedBox(width: 8),
                            Text(
                              'Et la radio ?',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Les téléphones n\'ont pas de radio libre pour discuter entre eux : '
                          'leurs seules radios sont le Wi-Fi, le Bluetooth${r.hasNfc ? ', le NFC (quelques centimètres)' : ''} '
                          'et le réseau mobile (qui passe par l\'opérateur). FIWICHAT utilise '
                          'déjà toutes celles qui marchent sans internet.\n\n'
                          'Pour aller beaucoup plus loin, il faut chaîner les téléphones : '
                          'chaque téléphone FIWICHAT relaie les messages des autres, donc '
                          'plus il y a de monde, plus ça porte loin.',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RadioRow extends StatelessWidget {
  const _RadioRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.on,
    this.available = true,
    this.count,
    this.fix,
  });
  final IconData icon;
  final String title, detail;
  final bool on, available;
  final int? count;
  final String? fix;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String status;
    final Color color;
    if (!available) {
      status = 'Pas sur ce téléphone';
      color = scheme.outline;
    } else if (!on) {
      status = 'Éteint';
      color = scheme.error;
    } else {
      final n = count;
      status = n == null
          ? 'Actif'
          : n == 0
          ? 'Actif · personne pour l\'instant'
          : 'Actif · $n téléphone${n > 1 ? 's' : ''}';
      color = brand;
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: available && on
                  ? brand
                  : scheme.surfaceContainerHighest,
              foregroundColor: available && on ? Colors.white : scheme.outline,
              child: Icon(icon),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  if (available && !on && fix != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: FilledButton.tonalIcon(
                        onPressed: () => openRadioSettings(fix!),
                        icon: Icon(_radioIcon(fix!)),
                        label: Text(radioAction(fix!)),
                      ),
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
  final _voice = VoiceRecorder();
  Timer? _voiceTimer;

  /// Bouton micro : démarre l'enregistrement (2 minutes au plus).
  Future<void> _startVoice() async {
    try {
      if (!await _voice.start()) {
        _toast('Autorise le micro pour envoyer un message vocal.');
        return;
      }
    } catch (_) {
      _toast('Le micro ne répond pas.');
      return;
    }
    _voiceTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (_voice.elapsed >= kMaxVoice) {
        _stopVoice(send: true);
      } else {
        setState(() {});
      }
    });
    setState(() {});
  }

  Future<void> _stopVoice({required bool send}) async {
    _voiceTimer?.cancel();
    _voiceTimer = null;
    if (!send) {
      await _voice.cancel();
      if (mounted) setState(() {});
      return;
    }
    final r = await _voice.stop();
    if (mounted) setState(() {});
    if (r == null) {
      _toast('Message vocal trop court.');
      return;
    }
    final (file, d) = r;
    final bytes = await file.readAsBytes();
    try {
      file.deleteSync();
    } catch (_) {}
    final ok = await widget.mesh.sendMedia(
      widget.convo,
      bytes,
      kind: 'audio',
      mime: 'audio/mp4',
      durationMs: d.inMilliseconds,
    );
    if (!ok)
      _toast('Envoi impossible : la personne n\'est pas encore connue ici.');
  }

  Widget _recordingBar() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('recording'),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Annuler',
            onPressed: () => _stopVoice(send: false),
            icon: Icon(Icons.delete_outline, color: scheme.error, size: 28),
          ),
          Icon(Icons.fiber_manual_record, color: scheme.error, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Enregistrement… ${clock(_voice.elapsed)} / ${clock(kMaxVoice)}',
              style: const TextStyle(fontSize: 16),
            ),
          ),
          IconButton.filled(
            key: const Key('voice-send'),
            tooltip: 'Envoyer le vocal',
            onPressed: () => _stopVoice(send: true),
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    widget.mesh.openConversation = widget.convo;
    widget.mesh.markRead(widget.convo);
    AppServices.current?.clearNotice(widget.convo);
  }

  /// Appui long sur un message : copier ou effacer.
  Future<void> _messageMenu(ChatMessage m) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.text.isNotEmpty)
              ListTile(
                key: const Key('msg-copy'),
                leading: const Icon(Icons.copy),
                title: const Text('Copier le texte'),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
            if (m.mine && !m.delivered && widget.convo != kGroupId)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Renvoyer maintenant'),
                onTap: () => Navigator.pop(context, 'resend'),
              ),
            ListTile(
              key: const Key('msg-delete'),
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Effacer de mon téléphone'),
              subtitle: const Text('Les autres gardent leur copie.'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.text));
      _toast('Texte copié.');
    } else if (choice == 'delete') {
      widget.mesh.deleteMessage(widget.convo, m);
      _toast('Message effacé.');
    } else if (choice == 'resend') {
      final n = widget.mesh.resendPending(widget.convo, force: true);
      _toast(n > 0 ? 'Renvoyé.' : 'Personne à portée pour l\'instant.');
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vider la conversation ?'),
        content: const Text(
          'Tous les messages, photos et vocaux de cette conversation seront effacés de ton téléphone. '
          'Les autres gardent leur copie.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            key: const Key('clear-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Vider'),
          ),
        ],
      ),
    );
    if (ok == true) widget.mesh.clearConversation(widget.convo);
  }

  @override
  void dispose() {
    widget.mesh.openConversation = null;
    _voiceTimer?.cancel();
    _voice.dispose();
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    widget.mesh.send(widget.convo, text);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Choisir ou prendre une photo / vidéo, puis l'envoyer (le texte tapé sert de légende).
  Future<void> _pickMedia() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Photo de la galerie'),
              onTap: () => Navigator.pop(context, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.video_library),
              title: const Text('Vidéo de la galerie'),
              onTap: () => Navigator.pop(context, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Filmer une vidéo'),
              subtitle: const Text('30 secondes maximum'),
              onTap: () => Navigator.pop(context, 'film'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    final picker = ImagePicker();
    XFile? file;
    try {
      if (choice == 'photo' || choice == 'camera') {
        // Photo réduite et compressée : ~200 Ko, rapide même en Bluetooth.
        file = await picker.pickImage(
          source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 70,
        );
      } else {
        file = await picker.pickVideo(
          source: choice == 'film' ? ImageSource.camera : ImageSource.gallery,
          maxDuration: const Duration(seconds: 30),
        );
      }
    } catch (_) {
      _toast('Impossible d\'ouvrir la galerie ou l\'appareil photo.');
      return;
    }
    if (file == null) return;
    final isVideo = choice == 'video' || choice == 'film';
    final size = await file.length();
    if (size > kMaxMediaBytes) {
      _toast(
        isVideo
            ? 'Vidéo trop lourde (8 Mo maximum). Filme une vidéo plus courte.'
            : 'Photo trop lourde (8 Mo maximum).',
      );
      return;
    }
    final bytes = await file.readAsBytes();
    final caption = _text.text.trim();
    _text.clear();
    final ok = await widget.mesh.sendMedia(
      widget.convo,
      bytes,
      kind: isVideo ? 'video' : 'photo',
      mime: _mimeOf(file.name, isVideo),
      caption: caption.length > kMaxText
          ? caption.substring(0, kMaxText)
          : caption,
    );
    if (!ok)
      _toast('Envoi impossible : la personne n\'est pas encore connue ici.');
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
          PopupMenuButton<String>(
            key: const Key('chat-menu'),
            onSelected: (v) {
              if (v == 'clear') _clearAll();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'clear',
                child: Text('Vider la conversation'),
              ),
            ],
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
                        child: GestureDetector(
                          key: Key('msg-${m.mid ?? i}'),
                          onLongPress: () => _messageMenu(m),
                          child: Container(
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.78,
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
                                if (m.media != null)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: 4,
                                      bottom: 4,
                                    ),
                                    child: MediaBubble(message: m),
                                  ),
                                if (m.text.isNotEmpty)
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
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            if (_voice.recording)
              _recordingBar()
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Row(
                  children: [
                    IconButton(
                      key: const Key('attach'),
                      onPressed: _pickMedia,
                      tooltip: 'Envoyer une photo ou une vidéo',
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 28,
                      ),
                    ),
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
                    IconButton(
                      key: const Key('mic'),
                      onPressed: _startVoice,
                      tooltip: 'Message vocal',
                      icon: const Icon(Icons.mic_none, size: 28),
                    ),
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

String _mimeOf(String name, bool video) {
  final ext = name.split('.').last.toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    '3gp' => 'video/3gpp',
    'mp4' || 'm4v' => 'video/mp4',
    _ => video ? 'video/mp4' : 'image/jpeg',
  };
}

String _sizeLabel(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} Mo'
    : '${(bytes / 1024).ceil()} Ko';

Future<void> _openFile(String path, String mime) async {
  try {
    await _wifiChannel.invokeMethod('openFile', {'path': path, 'mime': mime});
  } catch (_) {}
}

Future<void> _shareFile(String path, String mime) async {
  try {
    await _wifiChannel.invokeMethod('shareFile', {'path': path, 'mime': mime});
  } catch (_) {}
}

/// Photo ou vidéo dans une bulle de conversation.
class MediaBubble extends StatelessWidget {
  const MediaBubble({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final m = message.media!;
    final path = message.path;
    final progress = message.progress;
    final scheme = Theme.of(context).colorScheme;
    final ready = path != null && File(path).existsSync();
    Widget body;
    if (m.isAudio) {
      body = VoiceBubble(message: message, ready: ready);
    } else if (ready && !m.isVideo) {
      body = GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PhotoScreen(path: path, mime: m.mime),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320, minWidth: 120),
            child: Image.file(
              File(path),
              fit: BoxFit.cover,
              cacheWidth: 900,
              errorBuilder: (_, _, _) => const _MediaTile(
                icon: Icons.broken_image_outlined,
                label: 'Photo illisible',
              ),
            ),
          ),
        ),
      );
    } else if (ready) {
      body = InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openFile(path, m.mime),
        child: _MediaTile(
          icon: Icons.play_circle_fill,
          label: 'Vidéo · ${_sizeLabel(m.size)}',
          dark: true,
        ),
      );
    } else {
      final pct = progress == null ? null : (progress * 100).round();
      final what = m.isVideo ? 'Vidéo' : 'Photo';
      body = _MediaTile(
        icon: m.isVideo ? Icons.videocam_outlined : Icons.photo_outlined,
        label: pct == null
            ? '$what en attente… (${_sizeLabel(m.size)})'
            : 'Réception de la ${what.toLowerCase()} · $pct %',
        progress: progress,
      );
    }
    // Chez l'expéditeur : la photo s'affiche tout de suite, avec la progression de l'envoi.
    if (ready && message.mine && progress != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          body,
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress),
          Text(
            'Envoi… ${(progress * 100).round()} %',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }
    return body;
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({
    required this.icon,
    required this.label,
    this.progress,
    this.dark = false,
  });
  final IconData icon;
  final String label;
  final double? progress;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = dark ? Colors.white : scheme.onSurfaceVariant;
    return Container(
      width: 220,
      height: 150,
      decoration: BoxDecoration(
        color: dark ? Colors.black87 : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: fg),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(color: fg),
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
          ],
        ],
      ),
    );
  }
}

/// Photo en plein écran (on peut zoomer), avec « Partager ».
class PhotoScreen extends StatelessWidget {
  const PhotoScreen({super.key, required this.path, required this.mime});
  final String path, mime;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      actions: [
        IconButton(
          icon: const Icon(Icons.share),
          tooltip: 'Partager ou enregistrer',
          onPressed: () => _shareFile(path, mime),
        ),
      ],
    ),
    body: Center(
      child: InteractiveViewer(maxScale: 5, child: Image.file(File(path))),
    ),
  );
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
    await widget.services.nearby.checkPermissions(ask: true);
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
    await widget.services.nearby.checkPermissions(ask: true);
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
                    ? 'Bluetooth : actif · ${nearby.connectedCount} téléphone(s) relié(s)${nearby.waitingCount > 0 ? ' · ${nearby.waitingCount} en cours' : ''}'
                    : 'Bluetooth : inactif${nearby.error != null ? ' (${nearby.error})' : ''}',
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
