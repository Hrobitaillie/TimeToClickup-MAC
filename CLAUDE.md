# CLAUDE.md

Ce fichier sert de guide à Claude Code (claude.ai/code) lorsqu'il intervient sur ce dépôt.

## De quoi il s'agit

Une app menu-bar macOS 14+ (SwiftUI + AppKit) qui miroite une time entry ClickUp dans une overlay style « Dynamic Island » sous le notch, et miroite optionnellement le timer en cours dans un événement Google Calendar. Construite en un unique `executableTarget` SwiftPM — pas de projet Xcode. La majorité des chaînes côté UI et des messages de log sont en français : conserver cette convention en éditant.

## Build / run / release

```bash
swift build                       # debug
swift build -c release            # binaire release seul
./build_app.sh                    # release + assemble le bundle .app dans .build/release/
APP_VERSION=0.1.1 ./build_app.sh  # définit la version inscrite dans Info.plist
open .build/release/TimeToClickup.app

./release.sh 0.1.1                # build + zip dans dist/
./release.sh 0.1.1 --publish      # tag, push, et `gh release create` en plus
```

Il n'y a **aucune cible de test** — `Package.swift` ne déclare que la cible exécutable. Ne pas ajouter `swift test` aux instructions.

CI (`.github/workflows/release.yml`) se déclenche sur les tags `v*`, tourne sur `macos-14`, utilise l'Environment GitHub `app` pour injecter `GOOGLE_AUTH_CLIENT` / `GOOGLE_AUTH_SECRET` dans `.env` avant d'appeler `build_app.sh`. Voir `RELEASING.md` pour le runbook complet de release.

## Architecture

### Modèle process / fenêtre

- `App.swift` impose **une seule instance** en terminant les autres processus avec le même bundle id avant `NSApp.run()` — sans ça on se retrouve avec plusieurs status items et overlays empilés sous le notch.
- `LSUIElement = true` + `app.setActivationPolicy(.accessory)` → pas d'icône Dock, juste l'item en barre de statut. `AppDelegate.setupMainMenu()` installe quand même un menu Edit pour que ⌘C/⌘V/⌘X/⌘A fonctionnent dans les TextFields (les apps accessory ne l'ont pas par défaut).
- L'overlay est un `NSPanel` borderless (`OverlayPanel`) à `level = .statusBar` avec `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`. Il doit avoir `canBecomeKey == true` (combiné à `.nonactivatingPanel`) pour que le champ de recherche reçoive les frappes sans activer l'app.
- Le panel garde une **taille fixe 360×80** ; la `OverlayView` SwiftUI morphe compact↔étendu via une géométrie partagée (`@Namespace`). Ne pas redimensionner le panel au hover — c'est ça qui cause le flicker.
- Les popovers de recherche/description sont des `NSPanel` séparés ancrés à l'overlay ; `BackdropPanel` est un piège-à-clic transparent qui les ferme.

### Flux d'état

`TimerState` (singleton, `@MainActor`) est la source de vérité et **miroite exactement une time entry ClickUp à la fois** :

- L'utilisateur clique play → le timer local démarre tout de suite, puis `POST /time_entries/start` part dans un `Task`. Le timer local n'est **tué par un poll serveur que si `currentEntryId` est défini** — sinon un start refusé arrêterait silencieusement l'horloge locale de l'utilisateur.
- Un `syncTimer` à 15s interroge `GET /team/{id}/time_entries/current` pour que les timers démarrés/arrêtés sur web/mobile remontent ici. Règle de conflit : quand on a à la fois un `startedAt` local et une entry serveur, **la plus ancienne gagne** (branche `preferLocal` dans `apply(serverEntry:)`) pour que l'horloge affichée ne saute jamais en arrière.
- Attacher une tâche à une entry déjà en cours utilise `PUT /time_entries/{id}` avec `tid=...` — jamais stop+start, ça perdrait le temps écoulé.

### Service ClickUp (`ClickUpService.swift`)

- Un seul fichier contient le bootstrap team/user, la whitelist du workspace (Spaces/Folders/Lists dans `UserDefaults`), la recherche, et le CRUD des time entries. Ne pas le splitter à la légère — les liaisons `@Published` ↔ UI dépendent du fait que c'est un unique ObservableObject.
- **La recherche a deux modes.** Quand une liste unique est épinglée (`searchListFilter`), il tire toutes les tâches de cette liste via `GET /list/{id}/task` et filtre côté client — le filtre `name=` au niveau team de ClickUp drop silencieusement certains matches. Sinon il tape `GET /team/{id}/task?name=...` paginé jusqu'à 3 pages, plus un fallback en un seul mot (le token le plus long ≥ 4 caractères) mergé pour récupérer les matches que le filtre substring rate sur les requêtes multi-mots. Le re-classement se fait localement avec un scoring insensible aux diacritiques (`score()`, buckets 0–5).
- Toutes les erreurs passent par `report()`, qui **avale les cancellations** (chaque frappe annule la recherche en vol via `inflightSearch?.cancel()`).

### Sync Google Calendar (`Services/Google/`)

- `GoogleAuthService` lance **OAuth PKCE in-process** en faisant tourner `LocalLoopbackServer` sur `127.0.0.1:<port aléatoire>` pour attraper le redirect. Les tokens vont dans `UserDefaults`, rafraîchis à la demande.
- `CalendarSyncCoordinator` est branché depuis `TimerState.{start,stop,attach,setDescription}`. Pendant que ça tourne, il PATCH le `end` de l'événement à `now + 15min` toutes les 15 min pour que le créneau lise comme « en cours » avec le préfixe `🔴 ` ; au stop, il retire le préfixe et fixe le vrai end time. Toujours appeler `timerWillStop()` **avant** de vider les champs de `TimerState` — le coordinator capture task/description de manière synchrone.
- Les client_id / client_secret OAuth ne sont pas par-utilisateur. Ils vivent dans `.env` à la racine du repo (gitignoré), que `build_app.sh` copie vers `Resources/credentials.env` pour qu'ils soient embarqués dans le `.app`. `AppCredentials` lit ce fichier bundlé au runtime ; les valeurs saisies par l'utilisateur dans Settings servent de fallback. La CI les injecte depuis l'Environment GitHub `app`.

### Stockage des tokens

`KeychainHelper` n'est **volontairement pas** le Keychain macOS — c'est un wrapper fin sur `UserDefaults` (`~/Library/Preferences/<bundle>.plist`). Le vrai Keychain affiche une boîte de dialogue système d'autorisation à chaque lecture pour les apps non signées, ce qui vole le focus du popover de recherche. Ne pas « corriger » ça en passant à `Security.framework` sans résoudre le problème de vol de focus.

### Concurrence

Propre vis-à-vis de la strict concurrency Swift 6. La plupart des singletons sont `@MainActor` ; les jobs longs tournent dans des blocs `Task { ... }` qui capturent `[weak self]` et reviennent au main via `Task { @MainActor in ... }`. `LocalLoopbackServer` a été retravaillé spécifiquement pour la strict concurrency Swift 6 (voir commit `fcf2f5a`) — préserver son isolation d'acteur en éditant.

## Conventions

- Ne pas introduire un nouveau singleton de premier niveau si `TimerState` / `ClickUpService` / `SearchController` / `CalendarSyncCoordinator` / `GoogleAuthService` couvre déjà la responsabilité.
- Les chaînes visibles par l'utilisateur et les messages `LogStore` sont en français. Les identifiants de code et les commentaires sont en anglais.
- L'app est **ad-hoc signée seulement** (`codesign --sign -`). Ne pas ajouter de dépendance dure à un Developer ID — le flux de premier lancement assume la danse clic-droit → Ouvrir.
- `assets/AppIcon.icns` est un artefact de build regénéré à partir de `assets/icon-source.png` par `build_app.sh` ; il est gitignoré. Pour changer l'icône, remplacer le PNG.
- apres chaque nouvelle fonctionnalité ou update, propose moi la commande a entrer dans la console pour fermer toute instance de l'application et réouvrir a version qu'on vient de builder.

pkill -f "TimeToClickup.app" 2>/dev/null; sleep 1; defaults write com.local.timetoclickup idle_alert_last_activity -date "$(date -u -v-30M'+%Y-%m-%d %H:%M:%S +0000')" && echo "lastActivity = $(defaults read com.local.timetoclickup idle_alert_last_activity)" && open "/Users/hugo/Documents/GitHub/TimeToClickupDesktop/.build/release/TimeToClickup.app"
