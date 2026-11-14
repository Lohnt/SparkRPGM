import Foundation

/// Builds the generated documents that let an EasyRPG (RPG Maker 2000/2003)
/// game run inside the same `rpgm://` origin as the bundled wasm runtime.
///
/// Three resources are synthesised on demand by `RPGMSchemeHandler`:
///
/// * `__runtime__/easyrpg/host.html`            — loader + status UI
/// * `__runtime__/easyrpg/game-manifest.json`   — every game file to copy into
///                                                 the Emscripten filesystem
/// * `__runtime__/easyrpg/runtime-manifest.json`— what the CI fetched from
///                                                 `torahappy/easyrpg-web`
///
/// The host page copies the game into `/game`, pre-loads native saves, runs
/// the player, then polls `/game/Save*.lsd` and forwards changes to the native
/// save folder through `saveBridge`.
enum EasyRPGHostBuilder {

    // MARK: - Manifest limits

    /// A 2000/2003 title is usually tens of megabytes. This guard refuses the
    /// rare giant projects that would exhaust a 3 GB iPad when copied into the
    /// wasm heap.
    static let maxGameBytes: Int64 = 1_400 * 1024 * 1024
    static let maxFileCount = 40_000

    private static let skippedNames: Set<String> = [
        ".git", ".github", ".spark", "__macosx", "thumbs.db", ".ds_store",
        "desktop.ini", "node_modules",
    ]

    private static let skippedExtensions: Set<String> = [
        "zip", "7z", "rar", "apk", "ipa", "dmg", "iso",
    ]

    // MARK: - Host page

    static func hostHTML() -> Data {
        Data(hostTemplate.utf8)
    }

    // MARK: - Game manifest

    static func gameManifest(gameRoot: URL) -> Data {
        var files: [[String: Any]] = []
        var total: Int64 = 0
        var visited = 0
        var entry = "."
        var overflow = false

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(
            at: gameRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) {
            for case let url as URL in enumerator {
                visited += 1
                if visited > maxFileCount { overflow = true; break }

                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isDirectory = values?.isDirectory ?? false

                if isDirectory {
                    if skippedNames.contains(name.lowercased()) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                guard values?.isRegularFile == true else { continue }
                guard !skippedNames.contains(name.lowercased()) else { continue }
                guard !skippedExtensions.contains(url.pathExtension.lowercased()) else { continue }

                let size = Int64(values?.fileSize ?? 0)
                guard total + size <= maxGameBytes else {
                    overflow = true
                    continue
                }

                var relative = url.path
                let rootPath = gameRoot.path
                if relative.hasPrefix(rootPath) {
                    relative.removeFirst(rootPath.count)
                }
                while relative.hasPrefix("/") { relative.removeFirst() }
                guard !relative.isEmpty else { continue }

                if entry == "." {
                    let lower = relative.lowercased()
                    if lower == "rpg_rt.ldb" {
                        entry = relative
                    } else if lower.hasSuffix(".ldb") {
                        entry = relative
                    }
                }

                files.append(["path": relative, "size": size])
                total += size
            }
        }

        // EasyRPG Player takes a *game directory* on the command line, not the
        // .ldb path, so hand the host the folder that contains the database.
        var entryDirectory = "."
        if entry != "." {
            let slash = entry.lastIndex(of: "/")
            if let slash = slash, slash != entry.startIndex {
                entryDirectory = String(entry[entry.startIndex..<slash])
            }
        }

        let payload: [String: Any] = [
            "files": files,
            "entry": entry,
            "entryDirectory": entryDirectory,
            "totalBytes": total,
            "overflow": overflow,
            "maxBytes": maxGameBytes,
        ]
        return json(payload)
    }

    // MARK: - Runtime manifest

    static func runtimeManifest(runtimeRoot: URL?) -> Data {
        guard let runtimeRoot = runtimeRoot, AppPaths.isDirectory(runtimeRoot) else {
            return json(["files": [String](), "unavailable": true])
        }

        var files: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(
            at: runtimeRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name == "UNAVAILABLE.txt" { continue }
                guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }

                var relative = url.path
                let rootPath = runtimeRoot.path
                if relative.hasPrefix(rootPath) {
                    relative.removeFirst(rootPath.count)
                }
                while relative.hasPrefix("/") { relative.removeFirst() }
                guard !relative.isEmpty, !relative.contains("..") else { continue }
                files.append(relative)
            }
        }

        let unavailable = files.contains(where: { $0.lowercased().hasSuffix(".js") }) == false
        return json([
            "files": files.sorted(),
            "unavailable": unavailable,
        ])
    }

    // MARK: - Helpers

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
    }

    // MARK: - Template

    /// Kept as a raw literal so no Swift interpolation can ever corrupt the
    /// JavaScript. Everything is resolved at runtime from `__SPARK_CONFIG__`.
    private static let hostTemplate = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="format-detection" content="telephone=no">
    <title>EasyRPG</title>
    <style>
      html, body {
        margin: 0; padding: 0; width: 100%; height: 100%;
        background: #000; overflow: hidden;
        -webkit-user-select: none; user-select: none; -webkit-touch-callout: none;
      }
      #canvas {
        display: block; width: 100vw; height: 100vh;
        background: #000; image-rendering: pixelated;
        image-rendering: -webkit-optimize-contrast;
        outline: none;
      }
      #spark-easyrpg-overlay {
        position: fixed; inset: 0; display: flex; align-items: center; justify-content: center;
        background: radial-gradient(circle at 50% 35%, #171426 0%, #08080d 70%);
        color: #fff; font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        z-index: 20; padding: 24px; box-sizing: border-box; text-align: center;
      }
      #spark-easyrpg-overlay.hidden { display: none; }
      .spark-card { max-width: 460px; width: 100%; }
      .spark-mark {
        width: 74px; height: 74px; margin: 0 auto 18px; border-radius: 20px;
        display: flex; align-items: center; justify-content: center;
        background: linear-gradient(145deg, rgba(124, 96, 255, .35), rgba(124, 96, 255, .08));
        border: 1px solid rgba(255, 255, 255, .12);
        font-size: 32px; line-height: 1;
      }
      .spark-title { font-size: 17px; font-weight: 700; letter-spacing: .1px; margin: 0 0 6px; }
      .spark-sub { font-size: 12px; color: rgba(255, 255, 255, .55); margin: 0 0 18px; line-height: 1.5; }
      .spark-bar { height: 4px; border-radius: 4px; background: rgba(255, 255, 255, .1); overflow: hidden; }
      .spark-bar > div { height: 100%; width: 4%; border-radius: 4px; background: #7c60ff; transition: width .18s ease; }
      .spark-detail { margin-top: 12px; font-size: 10px; color: rgba(255, 255, 255, .35); font-variant-numeric: tabular-nums; }
      .spark-error { color: #ffb4a2; font-size: 12px; line-height: 1.6; white-space: pre-wrap; text-align: left; margin-top: 14px; }
      #spark-easyrpg-status { margin-top: 10px; font-size: 11px; color: rgba(255, 255, 255, .45); }
      .spark-hint { margin-top: 16px; font-size: 10px; color: rgba(255, 255, 255, .32); line-height: 1.6; }
    </style>
    </head>
    <body>
    <canvas id="canvas" tabindex="-1" width="1280" height="720"></canvas>

    <div id="spark-easyrpg-overlay">
      <div class="spark-card">
        <div class="spark-mark">&#127918;</div>
        <h1 class="spark-title" id="spark-easyrpg-title">Starting EasyRPG Player</h1>
        <p class="spark-sub" id="spark-easyrpg-message">Preparing the RPG Maker 2000/2003 runtime…</p>
        <div class="spark-bar"><div id="spark-easyrpg-progress"></div></div>
        <div id="spark-easyrpg-status">Loading game data</div>
        <div class="spark-error" id="spark-easyrpg-error" hidden></div>
        <div class="spark-hint" id="spark-easyrpg-hint"></div>
      </div>
    </div>

    <script>
    (function () {
      'use strict';

      var cfg = window.__SPARK_CONFIG__ || {};
      var base = String(cfg.baseURL || '').replace(/\/+$/, '');
      var runtimeBase = base + '/__runtime__/easyrpg';
      var title = cfg.gameTitle || 'EasyRPG';

      var overlay = document.getElementById('spark-easyrpg-overlay');
      var titleNode = document.getElementById('spark-easyrpg-title');
      var messageNode = document.getElementById('spark-easyrpg-message');
      var statusNode = document.getElementById('spark-easyrpg-status');
      var progressNode = document.getElementById('spark-easyrpg-progress');
      var errorNode = document.getElementById('spark-easyrpg-error');
      var hintNode = document.getElementById('spark-easyrpg-hint');
      var canvas = document.getElementById('canvas');

      var pollTimer = 0;
      var lastSavePayload = Object.create(null);
      var playerModule = null;
      var finished = false;

      function log(text) {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sparkLog) {
            window.webkit.messageHandlers.sparkLog.postMessage('[EasyRPG] ' + text);
          }
        } catch (e) {}
        if (window.console) console.log('[EasyRPG]', text);
      }

      function setStatus(message, status, progress) {
        if (messageNode && message) messageNode.textContent = message;
        if (statusNode && status) statusNode.textContent = status;
        if (typeof progress === 'number' && progressNode) {
          progressNode.style.width = Math.max(4, Math.min(100, progress * 100)).toFixed(2) + '%';
        }
      }

      function showError(headline, detail, hint) {
        finished = true;
        if (overlay) overlay.classList.remove('hidden');
        if (titleNode) titleNode.textContent = headline || 'EasyRPG could not start';
        if (messageNode) messageNode.textContent = 'The game is still installed and your saves are safe.';
        if (errorNode) {
          errorNode.hidden = false;
          errorNode.textContent = String(detail || '');
        }
        if (hintNode) {
          hintNode.textContent = hint || '';
        }
        if (statusNode) statusNode.textContent = '';
        if (progressNode) progressNode.style.width = '100%';
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sparkLog) {
          window.webkit.messageHandlers.sparkLog.postMessage('[EasyRPG] fatal: ' + headline + ' — ' + detail);
        }
      }

      function hideOverlay() {
        if (overlay) overlay.classList.add('hidden');
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sparkReady) {
            window.webkit.messageHandlers.sparkReady.postMessage({ engine: 'easyrpg', title: title });
          }
        } catch (e) {}
      }

      function fetchJSON(url) {
        return fetch(url, { cache: 'no-store' }).then(function (response) {
          if (!response.ok) throw new Error('HTTP ' + response.status + ' for ' + url);
          return response.json();
        });
      }

      function encodePath(path) {
        return String(path).split('/').map(function (part) {
          return encodeURIComponent(part);
        }).join('/');
      }

      function base64ToBytes(b64) {
        var binary = atob(b64);
        var out = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
        return out;
      }

      function bytesToBase64(bytes) {
        var chunk = 0x8000;
        var parts = [];
        for (var i = 0; i < bytes.length; i += chunk) {
          parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + chunk)));
        }
        return btoa(parts.join(''));
      }

      // MARK: - Filesystem helpers

      function moduleFS(m) {
        if (m && m.FS) return m.FS;
        if (window.FS) return window.FS;
        return null;
      }

      function makeDirectory(m, path) {
        var FS = moduleFS(m);
        var parts = String(path).split('/').filter(Boolean);
        var current = '';
        for (var i = 0; i < parts.length; i++) {
          current += '/' + parts[i];
          if (FS) {
            try { FS.mkdir(current); } catch (e) {}
          } else if (typeof m.FS_createPath === 'function') {
            try { m.FS_createPath('/', current, true, true); } catch (e) {}
          }
        }
      }

      function writeVirtualFile(m, path, bytes) {
        var FS = moduleFS(m);
        var slash = path.lastIndexOf('/');
        var directory = slash > 0 ? path.substring(0, slash) : '/';
        var name = slash >= 0 ? path.substring(slash + 1) : path;

        makeDirectory(m, directory);

        if (FS) {
          FS.writeFile(path, bytes);
          return;
        }
        if (typeof m.FS_createDataFile === 'function') {
          m.FS_createDataFile(directory, name, bytes, true, true);
          return;
        }
        throw new Error('The EasyRPG runtime does not expose a filesystem (Module.FS is missing).');
      }

      function readVirtualFile(m, path) {
        var FS = moduleFS(m);
        if (!FS) return null;
        try { return FS.readFile(path); } catch (e) { return null; }
      }

      function listVirtualDirectory(m, path) {
        var FS = moduleFS(m);
        if (!FS) return [];
        try { return FS.readdir(path); } catch (e) { return []; }
      }

      // MARK: - Module boot

      function loadScript(src) {
        return new Promise(function (resolve, reject) {
          var script = document.createElement('script');
          script.src = src;
          script.async = true;
          script.onload = function () { resolve(); };
          script.onerror = function () { reject(new Error('Unable to load ' + src)); };
          document.head.appendChild(script);
        });
      }

      function pickRuntimeScript(files) {
        var scripts = files.filter(function (name) {
          return /\.js$/i.test(name) && !/worker|\.map$/i.test(name);
        });
        if (!scripts.length) return null;

        var preferred = [
          'index.js',
          'easyrpg-player.js',
          'easyrpg.js',
          'player.js',
          'game.js',
          'main.js'
        ];

        // Prefer the expected file name, breaking ties by the shallowest path.
        scripts.sort(function (a, b) {
          var aDepth = a.split('/').length;
          var bDepth = b.split('/').length;
          return aDepth - bDepth || a.length - b.length;
        });

        for (var i = 0; i < preferred.length; i++) {
          for (var j = 0; j < scripts.length; j++) {
            var lower = scripts[j].toLowerCase();
            var slash = lower.lastIndexOf('/');
            var baseName = slash >= 0 ? lower.substring(slash + 1) : lower;
            if (baseName === preferred[i]) return scripts[j];
          }
        }
        return scripts[0];
      }

      function runtimeDirectory(scriptName) {
        var slash = String(scriptName).lastIndexOf('/');
        return slash > 0 ? String(scriptName).substring(0, slash + 1) : '';
      }

      function moduleOptions(scriptName) {
        var assetDirectory = runtimeDirectory(scriptName);
        return {
          noInitialRun: true,
          arguments: ['.'],
          canvas: canvas,
          locateFile: function (path) { return runtimeBase + '/' + assetDirectory + path; },
          print: function (text) { log(String(text)); },
          printErr: function (text) { log('stderr: ' + String(text)); },
          onAbort: function (what) { log('aborted: ' + what); }
        };
      }

      function waitForRuntime(m) {
        return new Promise(function (resolve, reject) {
          if (!m) {
            reject(new Error('The EasyRPG runtime did not initialise.'));
            return;
          }
          if (m.calledRun || (m.FS && m._main)) {
            resolve(m);
            return;
          }

          var settled = false;
          var attempts = 0;

          function finish(error) {
            if (settled) return;
            settled = true;
            if (error) reject(error); else resolve(m);
          }

          m.onRuntimeInitialized = function () { finish(null); };

          var timer = setInterval(function () {
            attempts += 1;
            if (settled) { clearInterval(timer); return; }
            if (m.calledRun || (m.FS && m._main)) {
              clearInterval(timer);
              finish(null);
            } else if (attempts > 1200) {
              clearInterval(timer);
              finish(new Error('Timed out waiting for the EasyRPG runtime to initialise.'));
            }
          }, 100);
        });
      }

      function bootRuntime(scriptName) {
        setStatus('Loading EasyRPG Player…', 'Starting wasm runtime', 0.04);

        var options = moduleOptions(scriptName);
        window.Module = options;

        return loadScript(runtimeBase + '/' + encodePath(scriptName)).then(function () {
          var factory = null;
          if (typeof window.Module === 'function') factory = window.Module;
          if (!factory) {
            ['createEasyRPGModule', 'createModule', 'EasyRPGModule', 'EasyRPGFactory', 'createEasyRPG']
              .some(function (name) {
                if (typeof window[name] === 'function') { factory = window[name]; return true; }
                return false;
              });
          }

          if (factory) {
            return Promise.resolve(factory(options)).then(waitForRuntime);
          }
          return waitForRuntime(window.Module);
        });
      }

      // MARK: - Game data

      function copyGameFiles(m, manifest) {
        var files = (manifest && manifest.files) || [];
        if (!files.length) {
          return Promise.reject(new Error('No RPG Maker 2000/2003 files were found in this game folder.'));
        }

        var totalBytes = 0;
        for (var i = 0; i < files.length; i++) totalBytes += (files[i].size || 0);

        var maxBytes = (manifest.maxBytes || 1400 * 1024 * 1024);
        if (totalBytes > maxBytes) {
          return Promise.reject(new Error(
            'This game is ' + Math.round(totalBytes / (1024 * 1024)) + ' MB, which is too large for the in-browser EasyRPG runtime on this device.'
          ));
        }

        var queue = files.slice();
        var completed = 0;
        var completedBytes = 0;
        var workerCount = 4;

        function worker() {
          var item = queue.shift();
          if (!item) return Promise.resolve();
          var url = base + '/' + encodePath(item.path);

          return fetch(url, { cache: 'no-store' }).then(function (response) {
            if (!response.ok) throw new Error('HTTP ' + response.status + ' for ' + item.path);
            return response.arrayBuffer();
          }).then(function (buffer) {
            writeVirtualFile(m, '/game/' + item.path, new Uint8Array(buffer));
            completed += 1;
            completedBytes += buffer.byteLength;
            var fraction = 0.08 + 0.72 * (completed / files.length);
            setStatus(
              'Copying game data…',
              completed + ' / ' + files.length + ' files · ' +
                Math.round(completedBytes / (1024 * 1024)) + ' MB',
              fraction
            );
            return worker();
          });
        }

        var workers = [];
        for (var w = 0; w < Math.min(workerCount, files.length); w++) workers.push(worker());
        return Promise.all(workers);
      }

      function preloadSaves(m) {
        var saves = cfg.saves || {};
        var names = Object.keys(saves);
        if (!names.length) return;

        setStatus('Restoring save files…', names.length + ' save file(s)', 0.84);
        for (var i = 0; i < names.length; i++) {
          var name = names[i];
          if (!/^[A-Za-z0-9._ -]+$/.test(name) || name.indexOf('..') >= 0) continue;
          try {
            var bytes = base64ToBytes(saves[name]);
            writeVirtualFile(m, '/game/' + name, bytes);
            lastSavePayload[name] = saves[name];
          } catch (e) {
            log('Unable to restore save ' + name + ': ' + e);
          }
        }
      }

      // MARK: - Save polling

      function postSave(name, base64) {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveBridge) {
            window.webkit.messageHandlers.saveBridge.postMessage({
              action: 'save',
              name: name,
              data: base64,
              encoding: 'base64'
            });
          }
        } catch (e) {
          log('saveBridge failed for ' + name + ': ' + e);
        }
      }

      function pollSaves() {
        if (!playerModule || finished) return;
        var names = listVirtualDirectory(playerModule, '/game');
        if (!names || !names.length) return;

        for (var i = 0; i < names.length; i++) {
          var name = String(names[i]);
          if (!/^save[^/\\]*\.lsd$/i.test(name)) continue;
          var bytes = readVirtualFile(playerModule, '/game/' + name);
          if (!bytes || !bytes.length) continue;
          var encoded;
          try { encoded = bytesToBase64(bytes); } catch (e) { continue; }
          if (lastSavePayload[name] === encoded) continue;
          lastSavePayload[name] = encoded;
          postSave(name, encoded);
        }
      }

      function startSavePolling(m) {
        playerModule = m;
        pollTimer = setInterval(pollSaves, 1500);
        window.addEventListener('pagehide', pollSaves);
        window.addEventListener('beforeunload', pollSaves);
        document.addEventListener('visibilitychange', function () {
          if (document.visibilityState === 'hidden') pollSaves();
        });
      }

      // MARK: - Launch

      function launch(m, entry, entryDirectory) {
        playerModule = m;
        var FS = moduleFS(m);
        if (FS && typeof FS.chdir === 'function') {
          try { FS.chdir('/game'); } catch (e) { log('chdir failed: ' + e); }
        }

        setStatus('Starting player…', 'Handing over to EasyRPG', 0.94);

        setTimeout(function () {
          var attempted = false;
          var lastError = null;
          var argsList = [];
          var directory = entryDirectory || '.';
          // EasyRPG Player expects a game directory. Try the detected folder,
          // then the virtual root, then the build's built-in default.
          if (directory && directory !== '.') {
            argsList.push([directory]);
          }
          argsList.push(['.']);
          argsList.push([]);

          for (var i = 0; i < argsList.length && !attempted; i++) {
            try {
              if (typeof m.callMain === 'function') {
                m.callMain(argsList[i]);
              } else if (typeof m.run === 'function' && !m.calledRun) {
                m.run();
              } else if (m.calledRun) {
                // The build already started itself; nothing left to call.
              } else {
                throw new Error('The runtime does not export callMain().');
              }
              attempted = true;
            } catch (e) {
              lastError = e;
              // Emscripten throws on a normal game exit; treat that as a launch.
              if (e && (e.name === 'ExitStatus' || String(e).indexOf('ExitStatus') >= 0)) {
                attempted = true;
              }
            }
          }

          if (!attempted) {
            showError(
              'EasyRPG could not start',
              lastError ? String(lastError && lastError.stack ? lastError.stack : lastError) : 'Unknown runtime error',
              'The bundled EasyRPG web runtime may be incomplete. Rebuild the app so the workflow can fetch it again.'
            );
            return;
          }

          setStatus('Running', 'EasyRPG Player', 1);
          setTimeout(hideOverlay, 320);
        }, 120);
      }

      // MARK: - Entry point

      var watchdog = setTimeout(function () {
        if (!finished && overlay && !overlay.classList.contains('hidden')) {
          showError('EasyRPG is taking too long', 'The runtime did not finish loading within 120 seconds.');
        }
      }, 120000);

      Promise.all([
        fetchJSON(runtimeBase + '/game-manifest.json'),
        fetchJSON(runtimeBase + '/runtime-manifest.json')
      ]).then(function (results) {
        var gameManifest = results[0] || {};
        var runtimeManifest = results[1] || {};

        if (runtimeManifest.unavailable) {
          throw new Error(
            'The EasyRPG web runtime is not packaged in this build. ' +
            'Run the GitHub Actions workflow again so Resources/WebRuntime/easyrpg is populated.'
          );
        }

        var scriptName = pickRuntimeScript(runtimeManifest.files || []);
        if (!scriptName) {
          throw new Error('No EasyRPG JavaScript runtime was found in Resources/WebRuntime/easyrpg.');
        }

        if (gameManifest.overflow) {
          log('Game manifest was truncated; some large or excess files were skipped.');
        }

        if (titleNode) titleNode.textContent = title;
        setStatus('Loading EasyRPG Player…', 'Starting wasm runtime', 0.03);

        return bootRuntime(scriptName).then(function (m) {
          return copyGameFiles(m, gameManifest).then(function () {
            preloadSaves(m);
            startSavePolling(m);
            launch(m, gameManifest.entry, gameManifest.entryDirectory);
          });
        });
      }).catch(function (error) {
        clearTimeout(watchdog);
        showError(
          'EasyRPG could not start',
          String(error && error.stack ? error.stack : error),
          'Open this game folder in Files.app to confirm RPG_RT.ldb is present.'
        );
      }).then(function () {
        clearTimeout(watchdog);
      });
    })();
    </script>
    </body>
    </html>
    """#
}
