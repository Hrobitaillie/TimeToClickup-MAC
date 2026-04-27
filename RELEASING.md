# Publier une release

Trois fichiers gèrent le cycle de release :

| Fichier | Rôle |
| --- | --- |
| `build_app.sh` | Compile en release et assemble le `.app` (Info.plist, icône, signature ad-hoc). Lit `APP_VERSION` / `APP_BUILD` en variables d'env. |
| `release.sh <version>` | Wrapper local : appelle `build_app.sh`, zip via `ditto`, calcule SHA-256, optionnellement tag + push + crée la release GitHub. |
| `.github/workflows/release.yml` | Sur push d'un tag `vX.Y.Z`, build sur `macos-14`, publie le zip en asset de la release auto-créée. |

## TL;DR — release rapide

Choisir une version (semver, ex `0.1.1` après un patch) puis :

```bash
cd "/Users/hugo/Documents/GitHub/TimeToClickup Desktop"
git tag -a v0.1.1 -m "Release v0.1.1"
git push origin v0.1.1
```

Le workflow GitHub Actions prend la suite : build, package, release.
Vérifier sur https://github.com/Hrobitaillie/TimeToClickup-MAC/actions

## Avant de tagger

```bash
# 1. Tout est commité et poussé
git status
git push origin main

# 2. Build local pour valider
APP_VERSION="0.1.1" ./build_app.sh
open .build/release/TimeToClickup.app
# → Tester start/stop, recherche, settings, etc.

# 3. Verifier le compte GitHub actif (si on utilise gh)
gh auth status
```

## Choisir la version (semver)

- `0.x.y` → tant que c'est pré-1.0
- Bumper la **patch** (`0.1.0 → 0.1.1`) : bug fixes uniquement
- Bumper la **minor** (`0.1.0 → 0.2.0`) : nouvelle feature non-breaking
- Bumper la **major** (`0.x.y → 1.0.0`) : breaking change ou première version stable

Le tag git porte un `v` devant : `v0.1.1`. Le workflow le retire pour passer la version pure à `build_app.sh`.

## Voie A — release via GitHub Actions (recommandé)

```bash
git tag -a v0.1.1 -m "Release v0.1.1"
git push origin v0.1.1
```

Ce qui se passe ensuite :

1. Le workflow `release.yml` se déclenche sur le tag `v*`
2. Runner `macos-14` checkout, lit la version depuis `${GITHUB_REF}`
3. Lance `build_app.sh` avec `APP_VERSION` et `APP_BUILD` (numéro de run)
4. Génère `AppIcon.icns` à partir de `assets/icon-source.png`
5. Zip via `ditto` → `dist/TimeToClickup-v0.1.1.zip`
6. `softprops/action-gh-release` crée la release GitHub avec les notes auto-générées et y attache le zip

Suivre l'exécution :

```bash
gh run watch          # ou onglet Actions sur GitHub
```

## Voie B — release locale via `release.sh`

Utile quand le workflow CI est en panne ou pour publier vite :

```bash
./release.sh 0.1.1            # build + zip seulement
./release.sh 0.1.1 --publish  # build + zip + tag + push + gh release create
```

Sortie attendue avec `--publish` :

- Crée le tag git `v0.1.1` (skip si déjà présent)
- Push le tag
- Crée la release GitHub via `gh release create` avec le `.app` zippé
- Génère les release notes automatiquement depuis les commits

`gh` doit être authentifié sur le bon compte (`gh auth status` pour vérifier, `gh auth switch` pour changer).

## Vérifier la release

Une fois la release publiée :

```bash
# Lister
gh release list

# Voir les détails
gh release view v0.1.1

# Télécharger l'asset depuis quelque part
curl -L -o /tmp/timetoclickup.zip \
  "https://github.com/Hrobitaillie/TimeToClickup-MAC/releases/download/v0.1.1/TimeToClickup-v0.1.1.zip"

# Tester l'install
unzip -q /tmp/timetoclickup.zip -d /tmp/test-install
xattr -cr /tmp/test-install/TimeToClickup.app
open /tmp/test-install/TimeToClickup.app
```

L'icône colorée doit apparaître dans le Dock / Finder. Settings → API token → recherche → start/stop : tout doit fonctionner.

## Si le workflow échoue

1. Ouvrir la run rouge sur https://github.com/Hrobitaillie/TimeToClickup-MAC/actions
2. Cliquer le job `build` puis l'étape rouge → copier les ~30 dernières lignes
3. Corriger le code, commit, push
4. Re-tagger sur le nouveau commit :

```bash
git tag -d v0.1.1
git push origin :refs/tags/v0.1.1
git tag -a v0.1.1 -m "Release v0.1.1"
git push origin v0.1.1
```

Ou bumper directement à la version suivante (`v0.1.2`) — plus propre historiquement.

## Supprimer une release

```bash
gh release delete v0.1.1 --yes              # release seulement
git push origin :refs/tags/v0.1.1           # tag remote
git tag -d v0.1.1                           # tag local
```

## Notes

- L'app est **ad-hoc-signée** : pas de Gatekeeper en clair. Au premier lancement les utilisateurs doivent faire clic-droit → Ouvrir, ou `xattr -cr TimeToClickup.app` puis `open`.
- Pour notariser proprement (skip Gatekeeper) il faut un Apple Developer Program (99 €/an) + ajouter une étape `xcrun notarytool` dans le workflow avec les secrets GitHub.
- L'icône `assets/AppIcon.icns` est régénérée à chaque build depuis `assets/icon-source.png` — pour changer l'icône, remplacer juste le PNG source et committer.
