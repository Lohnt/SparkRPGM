# SparkRPGM

An RPG Maker player for iOS and iPadOS 15+, packaged as an unsigned `.ipa` for TrollStore.

The name, clean line-list layout, and visible `games/` + `save/` folder setup are inspired by **Spark - Ren'Py Novels** on iOS. Full transparency: this project was **vibecoded** to get RPG Maker games running smoothly on a 3 GB RAM iPad (iPadOS 15.6.1) with customizable on-screen controls and saves you can actually see and back up in Files.app.

---

## Supported Engines

| Engine | Runtime | Notes |
| --- | --- | --- |
| RPG Maker MZ / MV | Bundled `WKWebView` runtime | Runs the game's own `index.html` |
| RPG Maker 2000 / 2003 | EasyRPG Player (WebAssembly) | Fetched into the bundle by GitHub Actions |
| RPG Maker XP / VX / VX Ace | Optional `mkxp` module | Shows a status card if `mkxp` isn't compiled in |
| Plain HTML5 games | `WKWebView` | Any `index.html` + assets folder |

**+ Import Game** accepts `.zip`, `.apk`, `.7z`, and `.rar` (plus `.cbz`, `.cb7`, `.cbr`, `.ipa`). Nested folders—like APK `assets/www/` wrappers, `www/` subfolders, or single-root archives—are flattened automatically on import.

## Install (TrollStore)

1. Grab `SparkRPGM.ipa` from the latest **Actions** workflow run artifacts.
2. Share/open it in **TrollStore** (or TrollStore Lite) and tap Install.
3. Launch SparkRPGM (you can swap home-screen icons anytime under **Paintbrush → App Icon**).

## Folder Structure (`Files.app`)

Everything lives in `On My iPad / SparkRPGM`:

```text
games/<Game Title>/          Extracted game files
save/<Game Title>/           Save files (file1.rpgsave, Save01.lsd, etc.)
backups/                     Zipped save backups from the long-press menu
theme/wallpaper.jpg          Custom launcher wallpaper
chocofilepickerfixfolder/    Keeps the Files.app folder visible when empty
README.txt                   Quick in-app guide
```

You can either import archives through the **+** button or drop already-extracted game folders straight into `games/` and pull down to refresh the library. Internal metadata (covers, playtime, accent colors, and nw.js file overlays) lives in `.spark/`.

## Library & Launcher Customization

Switch between two layouts anytime from the top bar or the **Paintbrush** menu:

- **Spark Lines** — Fast, text-first rows inspired by Spark Ren'Py, with a `4 pt` colored accent stripe on the left, engine badge, disk size, playtime, and last-played date (`Played today`, `Played 3d ago`, etc.).
- **Prism Icons** — Multi-column cover grid (Compact / Standard / Large) with custom artwork or an engine badge fallback.

Long-press any game to **Rename**, **Set/Remove Custom Cover**, **Change Line Color**, **Backup Saves**, or **Delete**. Foreground playtime is tracked automatically and saved to `.spark/metadata.json`.

Inside **Paintbrush**, you can customize:
- Wallpaper (from Photos or Files), background blur (`0–30`), and dim overlay (`0–85%`)
- Card glass opacity, grid card size, and editable header title
- Accent colors and left-line colors (presets, full `ColorPicker`, or **Auto-color by engine**)
- Alternate app icons (`Default`, `Midnight`, `Retro`, `Crimson`, `Neon`, `Minimal`)

## In-Game Controls & Speed

The touch overlay maps directly to standard RPG Maker keyCodes (`D-Pad`, `Z / Enter`, `X / Escape`, `Shift`, and `Ctrl / Skip`).

- **Top Pill Bar:** Back, **1× / 2× / 3×** game speed toggle, orientation lock (`Landscape` / `Portrait` / `Auto`), reload, **Customize Controls**, and hide UI.
- **Fast-Forward (`1×–3×`):** Accelerates `SceneManager.updateScene` on MV/MZ (keeping BGM pitch normal) and `requestAnimationFrame` ticks on EasyRPG/HTML5 without needing a reload.
- **Control Editor:** Drag to reposition the D-Pad and action buttons, scale them (`0.6×–1.8×`), adjust opacity, toggle 8-way diagonals, haptics, or mirror the layout—saved globally or per game.

## Under the Hood (3 GB iPad Notes)

- **Custom `rpgm://` Scheme Handler:** Avoids `file://` CORS issues, resolves Windows-style case-insensitive asset paths on case-sensitive APFS storage, and streams large `.webm`/audio files via `206 Partial Content` in `256 KB` chunks so WebKit doesn't blow past memory limits.
- **Audio & Saves:** Configured with `AVAudioSession` `.playback` so the iPad mute switch doesn't kill BGM, with `ogv.js` fallback for `.ogg`/`.webm` playback. Saves bridge directly to `Documents/save/<Game Title>/`.
- **Memory Caps:** `devicePixelRatio` is capped at `1.5`, cover thumbnails are downsampled via ImageIO into a `48 MB` `NSCache`, and EasyRPG blocks games over `1.4 GB` / `40,000` files before loading into WebAssembly memory.

## Building

Builds run automatically on `macos-latest` via `.github/workflows/build-ipa.yml` on every push to `main`:
1. Generates app icons with Pillow (`scripts/generate_icons.py`).
2. Fetches `ogv.js 1.8.9` and `torahappy/easyrpg-web` into `Resources/WebRuntime/`.
3. Generates the Xcode project with `xcodegen generate` and compiles an unsigned Release `.ipa`.

To build locally on macOS (Xcode 15+):

```bash
brew install xcodegen
python3 -m venv .venv && . .venv/bin/activate && pip install pillow
python scripts/generate_icons.py --repo-root .
xcodegen generate
open SparkRPGM.xcodeproj
```

## Credits & License

- Inspired by **Spark - Ren'Py Novels** (iOS).
- Powered by **EasyRPG Player**, **ogv.js**, **ZIPFoundation**, **SWCompression**, and **Unrar.swift**, each governed by their own open-source licenses.
- RPG Maker is a trademark of Gotcha Gotcha Games / Enterbrain. No formal license file is included in this repo yet—feel free to use or adapt it for personal projects.