# FIWICHAT

Discuter entre téléphones **sans internet** : par le Wi-Fi, et de proche en proche.
Pas de serveur, pas de compte, pas de données mobiles.

## Ce que fait l'application

- **Salon général** : tout le monde à portée lit et écrit au même endroit.
- **Messages privés** : touche le nom d'une personne. Le message est **chiffré** : seule cette
  personne peut le lire. Un « ✓ reçu » s'affiche quand il est arrivé.
- **Relais automatique** : si Gaby est trop loin, le message passe par les téléphones FIWICHAT
  entre vous deux. Ces téléphones ne peuvent **ni lire le message, ni savoir pour qui il est**,
  et ils ne reçoivent **aucune notification**. Seul le destinataire est prévenu.
- **Mode invité** : bouton « Inviter ». Ton téléphone ouvre un Wi-Fi nommé **DIRECT-FC-FIWICHAT**
  (mot de passe **différent à chaque ouverture**, affiché avec un QR code). La personne s'y connecte, ouvre
  **http://192.168.49.1:8080** et discute dans son navigateur, sans rien installer.
  Les invités ont aussi le salon général et les messages privés chiffrés.
- **Donner l'appli sans internet** : sur la page invité, le bouton « Télécharger FIWICHAT »
  envoie l'appli directement depuis le téléphone (Android). Dans l'appli, « Partager l'appli »
  (icône de partage, ou dans « Inviter ») l'envoie par Quick Share, Bluetooth, etc.
  Chaque nouvel utilisateur peut la redonner à son tour.
- **Pseudos en double** : chaque personne a un code unique tiré de sa clé (ex. « Léa #4F2A9C »),
  affiché partout. Si deux personnes ont le même pseudo, un ⚠ le signale et le code les
  distingue. Les messages privés vont à la bonne personne (le code, pas le pseudo).
  Changer de pseudo pour un nom déjà pris à portée est refusé.
- L'historique reste sur le téléphone. L'appli continue de recevoir et relayer écran éteint.

## Photos et vidéos

Bouton 🖼 à gauche du champ de texte : photo de la galerie, photo prise sur le moment, vidéo de la
galerie ou vidéo filmée (30 s). Ça marche dans le salon général, en privé et sur la page invité.
Les photos sont réduites (1600 px, ~200 Ko) ; la taille maximale est de 8 Mo.
Le fichier est chiffré, découpé en morceaux de 9 Ko et envoyé doucement pour passer aussi en
Bluetooth. Les morceaux perdus sont redemandés automatiquement. En privé, seul le destinataire
peut ouvrir la photo : les relais transportent des morceaux illisibles.

## Sécurité

- **Tout est signé** : présence, salon, messages privés. Personne ne peut écrire sous le nom
  d'un autre, changer son pseudo, ni modifier un message en route. Un faux est rejeté et
  n'est même pas relayé.
- **Messages privés chiffrés de bout en bout**, y compris pour les invités du navigateur
  (le chiffrement se fait dans leur page). Les relais ne voient ni le texte, ni qui écrit à qui.
- **Anti-rejeu** : un message déjà reçu, ou vieux de plus de 2 jours, est ignoré. Une vieille
  annonce ne peut pas remettre un ancien pseudo.
- **Anti-spam** : chaque voisin est limité en débit (60 paquets d'avance, puis 20 par seconde),
  et les paquets et messages trop gros sont refusés.
- **Wi-Fi invité** : nouveau mot de passe aléatoire à chaque ouverture.
- **Vérification en face à face** : dans une conversation privée, le bouclier affiche vos deux
  empreintes. Si elles sont identiques sur les deux téléphones, touchez « C'est bien elle/lui » :
  un badge ✓ vérifié apparaît.
- Le **salon général** est public par nature : tout le monde à portée peut le lire. Pour un
  secret, utiliser les messages privés.
- Les invités reçoivent la page du téléphone hôte : ils doivent faire confiance à cette
  personne. Pour une sécurité maximale, installer l'appli.

## Comment les téléphones se trouvent

1. **Même Wi-Fi** (une box, même sans abonnement, ou le partage de connexion d'un téléphone) :
   détection automatique.
2. **À proximité** (Android) : les téléphones FIWICHAT se relient tout seuls entre eux
   (Bluetooth pour se trouver, Wi-Fi direct pour transmettre). C'est ce qui permet le relais
   de proche en proche. Il faut accepter les autorisations « Appareils à proximité » /
   « Localisation » au premier lancement.
3. **Invités** : par le réseau DIRECT-FC-FIWICHAT, voir plus haut.
4. Si rien n'apparaît : bouton ⓘ, puis taper l'adresse de l'autre téléphone.

Radios utilisées, toutes en même temps : Wi-Fi (même réseau, partage de connexion, Wi-Fi
FIWICHAT), Bluetooth classique, Bluetooth basse consommation (BLE), Wi-Fi Direct et Wi-Fi Aware
(ces quatre-là via Nearby Connections, qui choisit la meilleure). Touche la barre
« Wi-Fi / Proches / Invités » pour voir l'écran **Connexions**. Si le Bluetooth, le Wi-Fi ou la
localisation est éteint, l'accueil propose de l'allumer, et la recherche repart toute seule.
Les téléphones n'ont pas d'autre radio utilisable entre eux (le NFC ne porte qu'à quelques
centimètres, le réseau mobile passe par l'opérateur).

## Installer sur Android

L'APK (le fichier d'installation) est fabriqué automatiquement par GitHub :

1. Mettre ce dossier dans un dépôt GitHub (branche `main`).
2. Attendre environ 10 minutes, puis télécharger :
   `https://github.com/<ton-compte>/<ton-dépôt>/releases/latest/download/fiwichat.apk`
3. Ouvrir le fichier sur le téléphone et autoriser « Installer des applis inconnues ».

Android 10 ou plus récent est nécessaire.

## Limites à connaître

- Android impose que le nom du réseau invité commence par « DIRECT-xx- » : il s'appelle donc
  **DIRECT-FC-FIWICHAT**, pas juste « FIWICHAT ». Un mot de passe est aussi obligatoire.
- Le téléphone de l'invité peut dire « pas d'internet » : il faut choisir « rester connecté ».
  La page ne s'ouvre pas toute seule, il faut taper l'adresse ou scanner le 2e QR code.
- Les messages ne sont transmis que si l'appli est ouverte (ou en arrière-plan) sur les
  téléphones qui relaient. Un message envoyé quand personne n'est à portée n'est pas gardé
  pour plus tard.
- Le salon général n'est pas chiffré (tout le monde doit pouvoir le lire).
- Les invités dans le navigateur ne peuvent pas relayer pour les autres, ni recevoir de
  notification quand la page est fermée.
- iPhone : le code est prévu, mais l'installation demande un Mac et un compte développeur
  Apple, et le relais « à proximité » n'existe que sur Android.

## Pour les développeurs

Flutter (Dart). Dossier `lib/` :
- `mesh.dart` : le maillage (inondation avec anti-doublons, 10 sauts max). Paquets `ann`
  (présence), `grp` (salon), `dm` (privé).
- `crypto.dart` : identité = clé Ed25519 (signature), plus une clé X25519 (chiffrement)
  annoncée et signée. `ann` et `grp` sont signés sur une liste JSON de champs. Un `dm` contient
  un corps signé (`['dm', de, à, mid, texte, ack, ts]`) enfermé dans une boîte NaCl avec une clé
  jetable vers la clé X25519 du destinataire, sans aucun identifiant visible. Chaque nœud essaie
  d'ouvrir chaque `dm` et le fait suivre dans tous les cas, destinataire compris : les relais
  ne peuvent pas savoir qui l'a lu. Les accusés de réception sont des `dm` comme les autres.
- `transport_lan.dart` : même Wi-Fi (UDP 45454 pour la découverte, TCP 45455 pour les paquets).
- `transport_nearby.dart` : Google Nearby Connections, stratégie P2P_CLUSTER.
- `guest_http.dart` (serveur, testable) + `guest_server.dart` + `assets/guest/` : page invité
  (HTTP + WebSocket sur le port 8080, et `/fiwichat.apk` qui sert l'appli installée).
  La page utilise tweetnacl-js, même format de chiffrement que l'appli.
- Android natif (`MainActivity.kt`, `KeepAliveService.kt`) : groupe Wi-Fi Direct pour les
  invités, verrou multicast, service de premier plan.

Commandes : `flutter test`, `flutter analyze`, `flutter build apk --release`.
