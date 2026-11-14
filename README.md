# SparkRPGM

A Spark‑style RPG Maker player for iOS and iPadOS 15+. Import a game from
Files.app, play it full‑screen with on‑screen controls, and keep your saves in a
folder you can see and back up.

Built to run on a 3 GB iPad (iPadOS 15.6.1) and shipped as an unsigned `.ipa`
for TrollStore.

---

## What it plays

| Engine | Runtime | Notes |
| --- | --- | --- |
| RPG Maker MZ / MV | bundled `WKWebView` runtime | plays the game's own `index.html` |
| RPG Maker 2000 / 2003 | EasyRPG Player (WebAssembly) | fetched into the bundle by CI |
| RPG Maker XP / VX / VX Ace | optional `mkxp` module | shows an explainer card when mkxp is not compiled in |
| Any HTML5 build | `WKWebView` | `index.html` + assets |

Archives accepted by **+ Import Game**: `.zip`, `.apk`, `.7z`, `.rar`
(also `.cbz`, `.cb7`, `.cbr`, `.ipa`). Nested layouts are handled, including
APK `assets/www/` wrappers, `www/` folders and single‑directory archives.

## Build

The only supported build path is the GitHub Actions workflow
(`.github/workflows/build-ipa.yml`), which runs on `macos-latest` and produces
an **unsigned** `SparkRPGM.ipa` artifact:

1. installs XcodeGen and Pillow, generates the app icons;
2. downloads ogv.js `1.8.9` into `Resources/WebRuntime/ogv`;
3. clones `torahappy/easyrpg-web` with Git LFS into `Resources/WebRuntime/easyrpg`
   (the build still succeeds if that step fails — EasyRPG titles then show a
   runtime warning);
4. runs `xcodegen generate`;
5. builds Release with `CODE_SIGNING_ALLOWED=NO`;
6. wraps `Payload/SparkRPGM.app` into `SparkRPGM.ipa`.

To build locally (macOS with Xcode 15+):

```bash
brew install xcodegen
python3 -m venv .venv && . .venv/bin/activate && pip install pillow
python scripts/generate_icons.py --repo-root .
xcodegen generate
open SparkRPGM.xcodeproj
```

Set your own team and bundle identifier if you want to install it directly from
Xcode.

## Install (TrollStore)

1. Download `SparkRPGM.ipa` from the workflow run artifacts.
2. Open it with TrollStore (or TrollStore Lite) and confirm the install.
3. Launch SparkRPGM.

Alternate home‑screen icons are switched from **Paintbrush → App Icon**.

## Folders (Files.app)

`On My iPad / SparkRPGM`:

```
games/<Game Title>/          extracted game root
save/<Game Title>/           physical save files (file1.rpgsave, Save01.lsd, …)
backups/                     save archives created from a game's long-press menu
chocofilepickerfixfolder/    keeps the Files.app directory index alive
theme/wallpaper.jpg          launcher wallpaper
README.txt                   short in-app help
```

Drop an archive anywhere in this folder and import it, or copy an already
extracted game into `games/` and pull down to rescan the library.

Hidden scaffolding lives in `.spark/` (`metadata.json` with titles, covers,
playtime and line colours; custom covers; the nw.js write overlay) and
`.staging/` (temporary extraction space).

## Library

Two library styles, switchable from the top bar or from **Paintbrush**:

* **Spark Lines** — a fast, text‑first list with no cover art. Every row has a
  4 pt coloured accent line, the title, an engine badge, disk size and play
  time.
* **Prism Icons** — a multi‑column cover grid (Compact / Standard / Large
  cards) with artwork or an engine fallback badge.

Both styles show `size • playtime` (for example `4.2 GB • 3h 20m`, or
`4.2 GB • Unplayed`). Search and engine filter chips, plus sorting by name,
recently played, most played or size.

Long‑press a game for **Rename**, **Set Custom Cover**, **Remove Custom Cover**,
**Change Line Color**, **Backup Saves** and **Delete**. Pull down to rescan
`Documents/games`.

### Playtime

Foreground session time is accumulated while a game is open (paused whenever
the app leaves the foreground) and flushed to `Documents/.spark/metadata.json`
every 45 seconds, on pause and on exit.

### Accent line colours

The launcher‑wide line colour supports presets, a full `ColorPicker`, or
**Auto-colour by engine** (MV blue, MZ green, 2000 gold, XP purple…). Any single
game can override it from its long‑press menu → **Change Line Color**; the
override is stored as `accentColorHex` in the game's metadata.

## Launcher customization

**Paintbrush** opens the appearance panel:

* library style (Spark Lines / Prism Icons) and sort order;
* wallpaper from Photos or Files, background blur (0–30), dim overlay (0–85 %);
* card glass opacity, card size (Compact / Standard / Large);
* editable header title, 8 accent presets plus a full `ColorPicker`;
* accent line presets, custom colour and auto‑colour‑by‑engine;
* app icon switcher (Default / Midnight / Retro / Crimson / Neon / Minimal);
* one‑tap reset.

Everything is stored in `UserDefaults` under `sparkrpgm.launcher.settings.v1`
and survives launches.

## In‑game controls

The translucent overlay maps to the keyCodes RPG Maker listens for:

| Control | keyCode |
| --- | --- |
| D‑Pad | 38 / 40 / 37 / 39 |
| Z / OK | 90 (+ Enter 13) |
| X / Cancel | 88 (+ Escape 27) |
| Shift | 16 |
| Ctrl / Skip | 17 |

The top pill bar has back, orientation (Landscape / Portrait / Auto), reload,
**Customize Controls** and hide‑chrome. Tapping **Show** brings the chrome back.

**Customize Controls** lets you drag the D‑Pad and the action cluster, resize
them (0.6×–1.8×), change opacity (10–100 %), enable auto‑fade, 8‑way input,
haptics, mirroring, and show/hide Shift and Ctrl. Presses are dispatched through
`window.__sparkKey(type, code, keyCode, button)`, which forces `keyCode`/`which`
on a real `KeyboardEvent` and updates `Input._currentState` before dispatching.

Layouts are saved per game or globally (`sparkrpgm.controls.game.v1.<folder>`
and `sparkrpgm.controls.global.v1`).

## How games are served

Games are served to `WKWebView` through a custom `rpgm://game/<folder>/…`
scheme handler rather than `file://`:

* case‑insensitive path resolution (Windows‑authored games reference
  `IMG/Pictures/Foo.PNG` on a case‑sensitive APFS volume);
* `206 Partial Content` streaming in 256 KB chunks for audio and video, so a
  large `.webm` never becomes a single `Data`;
* explicit MIME types (`application/wasm`, JavaScript, fonts …);
* bundled runtimes (ogv.js, EasyRPG) are served from the same scheme and host
  under `__runtime__/`, keeping workers and `.wasm` fetches same‑origin.

Audio uses `AVAudioSession` `.playback` + `.mixWithOthers`, so the iPad's
mute switch does not silence BGM.

Saves are written through a native bridge straight into
`Documents/save/<Game Title>/`. MV's synchronous `StorageManager` reads saves
that were pre‑loaded before the engine booted; MZ's Promise‑based
`StorageManager` talks to the bridge directly. `.ogg`/`.webm` assets fall back to
ogv.js, and `decodeAudioData` failures degrade to silence instead of crashing a
scene.

## Memory notes (3 GB iPad)

* `devicePixelRatio` is capped at 1.5 and `webglcontextlost` is reported to the
  app instead of silently blanking.
* Covers and wallpapers are thumbnailed with ImageIO and cached in a 48 MB
  `NSCache`.
* Archives stream to disk; 7‑Zip inputs are memory‑mapped; RAR entries are
  extracted and released one at a time.
* The EasyRPG host refuses games larger than 1.4 GB / 40 000 files before
  copying them into the wasm filesystem.

## Layout

```
SparkRPGM/
  App/          app entry, paths, logging, audio session, orientation
  Models/       Game, GameEngine, GameStore, launcher + control settings
  Services/     archive import, detection, thumbnails, backups
  Views/        library, player, controls, customizer, pickers
  Web/          scheme handler, web context, EasyRPG host builder
  Resources/    assets, JS shims, fetched web runtimes
scripts/generate_icons.py
project.yml
```

## License

No license file is included yet; treat the sources as personal-use reference
until one is added. RPG Maker is a trademark of Gotcha Gotcha Games /
Enterbrain. EasyRPG Player, ogv.js, ZIPFoundation, SWCompression and Unrar.swift
keep their own licenses.
