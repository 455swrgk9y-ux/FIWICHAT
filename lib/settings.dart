// FIWICHAT - réglages, présentation, et verrouillage par code PIN.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vault.dart';

const _brand = Color(0xFF00897B);

/// Réglages partagés par toute l'appli.
class AppConfig {
  AppConfig._();

  /// Taille du texte (1 = normal).
  static final textScale = ValueNotifier<double>(1.0);

  /// Vrai pendant que l'écran de code est affiché.
  static final locked = ValueNotifier<bool>(false);

  /// Vrai si un code PIN est choisi (les notifications cachent alors le texte).
  static bool pinSet = false;

  static Vault? vault;
  static SharedPreferences? prefs;

  static const scales = <(String, double)>[
    ('Petit', 0.9),
    ('Normal', 1.0),
    ('Grand', 1.2),
    ('Très grand', 1.45),
  ];

  static Future<void> load(SharedPreferences p, Vault v) async {
    prefs = p;
    vault = v;
    textScale.value = p.getDouble('textScale') ?? 1.0;
    pinSet = await v.hasPin();
    if (pinSet) locked.value = true;
  }

  static Future<void> setTextScale(double s) async {
    textScale.value = s;
    await prefs?.setDouble('textScale', s);
  }
}

/// Applique la taille du texte et l'écran de verrouillage à toute l'appli.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final AppLifecycleListener _life;
  DateTime? _leftAt;

  /// On laisse 30 s (choisir une photo fait quitter l'appli un instant).
  static const grace = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(
      onHide: () => _leftAt ??= DateTime.now(),
      onShow: () {
        final left = _leftAt;
        _leftAt = null;
        if (AppConfig.pinSet &&
            left != null &&
            DateTime.now().difference(left) >= grace) {
          AppConfig.locked.value = true;
        }
      },
    );
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: AppConfig.textScale,
      builder: (context, scale, _) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: ValueListenableBuilder<bool>(
          valueListenable: AppConfig.locked,
          builder: (context, locked, _) => Stack(
            children: [
              // Le maillage continue de relayer derrière l'écran verrouillé.
              Offstage(offstage: locked, child: widget.child),
              if (locked)
                Positioned.fill(
                  child: PinScreen(
                    key: const Key('lock-screen'),
                    title: 'FIWICHAT est verrouillé',
                    subtitle: 'Tape ton code pour ouvrir.',
                    onCode: (code) async {
                      final v = AppConfig.vault;
                      if (v == null || await v.checkPin(code)) {
                        AppConfig.locked.value = false;
                        return null;
                      }
                      final wait = v.waitBeforeTry();
                      if (wait > Duration.zero) {
                        return 'Trop d\'erreurs. Réessaie dans ${_human(wait)}.';
                      }
                      final left = kPinFreeTries - v.pinFails;
                      return left > 0
                          ? 'Code faux. Encore $left essai${left > 1 ? 's' : ''} avant une attente.'
                          : 'Code faux.';
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _human(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds + 1} s';
  return '${d.inMinutes + 1} min';
}

/// Clavier de code PIN (4 à 8 chiffres).
class PinScreen extends StatefulWidget {
  const PinScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onCode,
    this.onCancel,
  });
  final String title, subtitle;

  /// Renvoie null si le code est accepté, sinon le message d'erreur.
  final Future<String?> Function(String code) onCode;
  final VoidCallback? onCancel;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _code = '';
  String? _error;
  bool _busy = false;

  void _tap(String d) {
    if (_busy || _code.length >= 8) return;
    setState(() {
      _code += d;
      _error = null;
    });
  }

  Future<void> _ok() async {
    if (_busy) return;
    if (_code.length < 4) {
      setState(() => _error = 'Au moins 4 chiffres.');
      return;
    }
    setState(() => _busy = true);
    final err = await widget.onCode(_code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      _code = '';
    });
  }

  Widget _key(String label, {VoidCallback? onTap, Widget? child, Key? key}) {
    return Padding(
      padding: const EdgeInsets.all(5),
      child: SizedBox(
        width: 70,
        height: 70,
        child: FilledButton.tonal(
          key: key ?? Key('pin-$label'),
          style: FilledButton.styleFrom(shape: const CircleBorder()),
          onPressed: onTap ?? () => _tap(label),
          child:
              child ??
              Text(
                label,
                textScaler: TextScaler.noScaling,
                style: const TextStyle(fontSize: 28),
              ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onCancel != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      onPressed: widget.onCancel,
                      icon: const Icon(Icons.close),
                      tooltip: 'Annuler',
                    ),
                  ),
                const Icon(Icons.lock_outline, size: 56, color: _brand),
                const SizedBox(height: 12),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(widget.subtitle, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (
                      var i = 0;
                      i < (_code.length < 4 ? 4 : _code.length);
                      i++
                    )
                      Container(
                        margin: const EdgeInsets.all(6),
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < _code.length ? _brand : null,
                          border: Border.all(color: _brand, width: 2),
                        ),
                      ),
                  ],
                ),
                SizedBox(
                  height: 44,
                  child: Center(
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _error ?? '',
                            key: const Key('pin-error'),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.error),
                          ),
                  ),
                ),
                for (final row in const [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                ])
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [for (final d in row) _key(d)],
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _key(
                      'del',
                      onTap: () => setState(() {
                        if (_code.isNotEmpty) {
                          _code = _code.substring(0, _code.length - 1);
                        }
                      }),
                      child: const Icon(Icons.backspace_outlined),
                    ),
                    _key('0'),
                    _key(
                      'ok',
                      onTap: _ok,
                      child: const Icon(Icons.check, size: 30),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Choisir un nouveau code (tapé deux fois). Renvoie true s'il est enregistré.
Future<bool> choosePin(BuildContext context) async {
  String? first;
  final ok = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => PinScreen(
          key: ValueKey(first == null ? 'pin-new' : 'pin-confirm'),
          title: first == null ? 'Choisis un code' : 'Tape-le encore une fois',
          subtitle: first == null
              ? 'De 4 à 8 chiffres. Il sera demandé à chaque ouverture.'
              : 'Pour être sûr que tu ne t\'es pas trompé.',
          onCancel: () => Navigator.of(ctx).pop(false),
          onCode: (code) async {
            if (first == null) {
              setState(() => first = code);
              return null;
            }
            if (code != first) {
              setState(() => first = null);
              return 'Les deux codes sont différents. Recommence.';
            }
            await AppConfig.vault?.setPin(code);
            AppConfig.pinSet = true;
            if (ctx.mounted) Navigator.of(ctx).pop(true);
            return null;
          },
        ),
      ),
    ),
  );
  return ok ?? false;
}

// ======================= Présentation =======================

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;

  static const _content = [
    (
      Icons.wifi_tethering,
      'Bienvenue sur FIWICHAT',
      'Discute avec les gens autour de toi, sans internet et sans carte SIM.',
    ),
    (
      Icons.hub_outlined,
      'Les téléphones se passent les messages',
      'Par Wi-Fi et Bluetooth, chaque téléphone FIWICHAT fait suivre les messages. '
          'Plus il y a de monde, plus ça va loin.',
    ),
    (
      Icons.lock_outline,
      'Tes messages privés sont secrets',
      'Ils sont chiffrés : seule la bonne personne peut les lire. '
          'Les téléphones qui les font passer ne voient rien.',
    ),
    (
      Icons.send_to_mobile,
      'Invite tes amis',
      'Touche « Partager FIWICHAT » pour leur envoyer l\'appli. '
          'Sans l\'appli, ils peuvent aussi discuter depuis le navigateur.',
    ),
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _content.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('onboarding-skip'),
                onPressed: widget.onDone,
                child: const Text('Passer'),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  for (final (icon, title, text) in _content)
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        children: [
                          const SizedBox(height: 24),
                          CircleAvatar(
                            radius: 64,
                            backgroundColor: _brand.withValues(alpha: 0.12),
                            child: Icon(icon, size: 72, color: _brand),
                          ),
                          const SizedBox(height: 32),
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            text,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 18, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _content.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.all(4),
                    width: i == _page ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _page ? _brand : Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  key: const Key('onboarding-next'),
                  onPressed: last
                      ? widget.onDone
                      : () => _pages.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        ),
                  child: Text(
                    last ? 'C\'est parti !' : 'Suivant',
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================= Réglages =======================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.encrypted = true, this.onShowIntro});

  /// Vrai si l'historique est chiffré sur ce téléphone.
  final bool encrypted;
  final VoidCallback? onShowIntro;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  void _toast(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _Header('Taille du texte'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<double>(
              valueListenable: AppConfig.textScale,
              builder: (context, scale, _) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (label, s) in AppConfig.scales)
                    ChoiceChip(
                      key: Key('text-$label'),
                      label: Text(label),
                      selected: (scale - s).abs() < 0.01,
                      onSelected: (_) => AppConfig.setTextScale(s),
                    ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Exemple : Salut ! On se retrouve à la place du marché ?',
              style: TextStyle(fontSize: 16),
            ),
          ),
          const Divider(height: 32),
          const _Header('Verrouillage'),
          SwitchListTile(
            key: const Key('pin-switch'),
            secondary: const Icon(Icons.pin_outlined),
            title: const Text('Code pour ouvrir FIWICHAT'),
            subtitle: const Text(
              'Demandé à chaque ouverture. Les notifications ne montrent plus le texte des messages.',
            ),
            value: AppConfig.pinSet,
            onChanged: (on) async {
              if (on) {
                if (await choosePin(context)) _toast('Code enregistré.');
              } else {
                await AppConfig.vault?.setPin(null);
                AppConfig.pinSet = false;
                _toast('Code retiré.');
              }
              if (mounted) setState(() {});
            },
          ),
          if (AppConfig.pinSet)
            ListTile(
              leading: const Icon(Icons.password),
              title: const Text('Changer le code'),
              onTap: () async {
                if (await choosePin(context))
                  _toast('Nouveau code enregistré.');
              },
            ),
          if (AppConfig.pinSet)
            ListTile(
              leading: const Icon(Icons.lock_clock_outlined),
              title: const Text('Verrouiller maintenant'),
              onTap: () {
                Navigator.of(context).popUntil((r) => r.isFirst);
                AppConfig.locked.value = true;
              },
            ),
          const Divider(height: 32),
          const _Header('Ta protection'),
          _Shield(
            ok: widget.encrypted,
            title: widget.encrypted
                ? 'Historique chiffré sur ce téléphone'
                : 'Historique non chiffré',
            text: widget.encrypted
                ? 'Tes conversations et ta clé secrète sont enfermées avec une clé gardée par le téléphone.'
                : 'Ce téléphone n\'a pas de coffre-fort disponible.',
          ),
          const _Shield(
            ok: true,
            title: 'Nouvelle clé secrète chaque jour',
            text: 'Les anciennes sont effacées après 3 jours : même avec ton téléphone, personne ne pourra lire les vieux messages privés captés en route.',
          ),
          const _Shield(
            ok: true,
            title: 'Anti-spam',
            text: 'Quelqu\'un qui envoie trop de messages est freiné par tous les téléphones.',
          ),
          const _Shield(
            ok: true,
            title: 'Économie de batterie',
            text: 'Quand FIWICHAT n\'est pas à l\'écran, il continue de recevoir mais consomme moins.',
          ),
          const Divider(height: 32),
          ListTile(
            leading: Icon(Icons.school_outlined, color: scheme.primary),
            title: const Text('Revoir la présentation'),
            onTap: widget.onShowIntro,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.bold,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _Shield extends StatelessWidget {
  const _Shield({required this.ok, required this.title, required this.text});
  final bool ok;
  final String title, text;
  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(
      ok ? Icons.verified_user : Icons.warning_amber_rounded,
      color: ok ? _brand : Theme.of(context).colorScheme.error,
    ),
    title: Text(title),
    subtitle: Text(text),
  );
}
