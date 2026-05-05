# TimeToClickup

Une app menu-bar macOS 14+ qui miroite tes time entries ClickUp dans une overlay style **« Dynamic Island »** sous le notch, avec sync optionnelle vers Google Calendar et alertes intelligentes pour ne plus jamais oublier ton timer.

## Capacités principales

- **Pill flottante sous le notch** — start/stop, recherche de tâche, description, switch de tâche, le tout sans quitter l'app que tu utilises.
- **Sync ClickUp dans les deux sens** — un timer démarré sur web/mobile remonte dans la pill ; ce que tu fais dans la pill part vers ClickUp en temps réel.
- **Sync Google Calendar** (optionnelle) — chaque timer crée un event « 🔴 Tracking en cours » qui s'étend automatiquement et se finalise au stop.
- **Alerte oubli timer (jaune)** — si tu n'as pas démarré de timer depuis 10 min, la pill devient jaune pétante et propose un démarrage rapide ou un snooze.
- **Alerte fin de journée (rouge)** — si le timer tourne après ton heure de fin, la pill devient rouge pour t'inviter à l'arrêter.
- **Démarrage backdaté** — « j'ai oublié, lance comme si j'avais commencé il y a 15 min ».
- **Snooze calendar-aware** — l'alerte sait que tu es en réunion et propose de la mettre en sourdine **jusqu'à la fin de cette réu** précisément.
- **Préfixes par liste** — chaque tâche d'une liste est préfixée dans le titre Calendar (ex. `[Pompotes] Fix login bug`).
- **Horaires par jour** — Lun-Jeu différent du Vendredi, week-end off, multi-édition pour changer plusieurs jours à la fois.
- **Choix de l'écran** — multi-moniteur supporté, fallback automatique sur l'écran principal si le préféré est débranché.

## Installation

Télécharge la dernière release : https://github.com/Hrobitaillie/TimeToClickup-MAC/releases

L'app est **ad-hoc signée seulement** (pas de Developer ID). Premier lancement :

1. Décompresse le `.zip`
2. Glisse `TimeToClickup.app` dans `/Applications`
3. **Clic droit → Ouvrir** (et confirme dans la boîte de dialogue) — sinon Gatekeeper bloque
4. Au lancement, l'icône timer apparaît dans la barre de menu et la pill s'affiche sous le notch

L'app est `LSUIElement` : **pas d'icône Dock**, juste l'item en barre de statut.

## Premier setup

### 1. Token ClickUp

ClickUp → Settings → Apps → API Token. Copie le token (commence par `pk_…`).

Dans l'app : status bar → **Settings…** → onglet **ClickUp** → colle le token → **Sauvegarder**. Les espaces se chargent automatiquement.

### 2. Whitelist (optionnel)

Toujours dans **ClickUp**, coche les Espaces / Sous-espaces / Listes que tu veux dans le scope de la recherche. Sans rien de coché, la recherche ramène **tes tâches assignées** par défaut.

### 3. Google Calendar (optionnel)

Onglet **Calendrier** → **Connecter Google**. OAuth s'ouvre dans le navigateur. Au retour, tes events Google se créent et se mettent à jour avec le timer.

## Utilisation au quotidien

### La pill

| Élément | Action |
| --- | --- |
| **▶ / ⏹** | Démarrer / arrêter le timer |
| **▾** (à côté du play) | Démarrer **dans le passé** : preset 5/10/15/30 min, 1 h, ou heure précise |
| **🔍** | Recherche de tâche (filtre par liste, recents prioritaires) |
| **📝** | Ajouter / éditer la description de la time entry |
| **📅** | Toggle la sync Google Calendar |

### Recherche de tâche

- Tape pour filtrer par nom (insensible aux accents, multi-mots)
- Pin une liste avec le filtre 🔽 pour scoper la recherche à une liste précise (recommandé pour les gros workspaces — ClickUp drop sinon des matches sur les requêtes multi-mots)
- Les listes ClickUp se chargent automatiquement à l'ouverture du panneau de recherche

### Démarrer dans le passé

Quand tu réalises que tu bossais déjà depuis 20 min sans timer :

1. Clique le **▾** à côté du play
2. Choisis « 30 minutes », ou « Heure précise… » → sheet avec time picker + preview
3. **Si tu as Google Calendar** et qu'une réunion vient de se terminer, un bouton « **Après une réunion** » apparaît avec le titre + heure de fin → un clic pour démarrer pile à la fin du meeting

ClickUp reçoit le start backdaté via `PUT /time_entries/{id}` (le start API endpoint ne prend pas de date custom mais le PUT si).

## Les alertes

### Alerte oubli (jaune)

Si tu n'as pas démarré de timer depuis **10 min**, la pill devient **jaune pétante avec bordure pulsée** et affiche « Tu as oublié le timer ».

- **Démarrer ▾** : start immédiat ou backdaté (mêmes options que le menu chevron normal)
- **Plus tard ▾** : snooze 5/15/30 min, 1 h, fin de journée, ou heure précise
  - **Si tu es en réunion en cours**, un bouton « **Fin d'une réunion** » apparaît à côté du picker — clic = snooze pile jusqu'à la fin du meeting

### Alerte fin de journée (rouge)

Si le timer **tourne encore** après ton heure de fin du jour courant, la pill devient **rouge avec bordure pulsée** et affiche « Fin de journée — pense au timer ».

- **Arrêter** : stop immédiat
- **Continuer ▾** : snooze 15/30/60/120 min ou jusqu'à demain (utile en cas d'overtime ponctuel)

### Configurer les horaires

Settings → onglet **Horaires** :

- Toggle global pour activer/désactiver toutes les alertes EOD
- 7 lignes (Lun → Dim) avec :
  - ☑ Jour ouvré (décoche pour off — pas d'alerte ce jour)
  - 4 horaires HH:MM : début matin → fin matin / début aprem → fin aprem
  - Le jour courant est mis en évidence
- **Multi-édition** : clique le cercle de gauche sur plusieurs jours, une toolbar bleue apparaît au-dessus → édite une fois, ça applique aux jours sélectionnés
- Boutons utilitaires : « Sélectionner les jours ouvrés » et « Reset par défaut »

Defaults : Lun-Jeu 9h-12h30 / 14h-18h, Vendredi 9h-12h30 / 14h-17h, week-end off.

## Préfixes pour les events Calendar

Settings → onglet **Préfixes** :

1. Cherche une liste dans le champ recherche (autocomplete)
2. Clique pour l'ajouter au tableau
3. Tape le préfixe (ex. `Pompotes`)
4. ⏎ ou clic ailleurs pour sauvegarder

Désormais chaque event Google Calendar pour une tâche de cette liste s'appellera **`[Pompotes] Nom de la tâche`** au lieu de juste `Nom de la tâche`.

## Affichage multi-moniteur

Settings → onglet **Affichage** :

- **Suivre le système** (défaut) — l'écran principal du moment
- Ou choisis un écran spécifique → la pill y reste fixée

Si l'écran préféré est débranché, fallback automatique sur l'écran principal. La pill se repositionne instantanément quand tu connectes/déconnectes un moniteur.

## Settings tabs

- **ClickUp** — token API + whitelist espaces/folders/listes
- **Calendrier** — connexion Google OAuth
- **Préfixes** — mapping liste → préfixe pour les events Calendar
- **Horaires** — horaires de travail par jour + alerte EOD
- **Affichage** — choix de l'écran de la pill
- **Tests** — outil de debug pour vérifier la recherche ClickUp

En haut de chaque onglet, une carte « **Statut des alertes** » affiche en temps réel :
- État de l'alerte oubli (programmée / en sourdine / active) + countdown
- État de l'alerte fin de journée (programmée / en attente / en sourdine / active) + heure cible

## Build local

Pas de projet Xcode — tout en SwiftPM, un unique `executableTarget`.

```bash
swift build                       # debug
swift build -c release            # binaire release
./build_app.sh                    # release + bundle .app
APP_VERSION=0.3.1 ./build_app.sh  # avec version custom
open .build/release/TimeToClickup.app
```

Pour faire une release :

```bash
./release.sh 0.3.1                # build + zip dans dist/
./release.sh 0.3.1 --publish      # tag, push, gh release create
```

Voir [RELEASING.md](RELEASING.md) pour le runbook complet.

## Stack technique

- **macOS 14+**, **Swift 6** (strict concurrency)
- SwiftUI + AppKit (`NSPanel` borderless, `NSHostingView`)
- ClickUp API v2
- Google Calendar API v3 (OAuth PKCE in-process via loopback server)
- Aucun framework externe — tout dans la stdlib + Apple frameworks
- App **ad-hoc signée** (`codesign --sign -`) — pas de Developer ID

Les détails d'archi sont dans [CLAUDE.md](CLAUDE.md).
