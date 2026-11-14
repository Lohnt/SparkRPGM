/* SparkRPGM — native save shim.
 *
 * RPG Maker MV save files are LZString-compressed JSON text (.rpgsave); MZ
 * files are deflated blobs (.rmmzsave). Both are stored in
 * Documents/save/<GameFolder> so they survive app updates and are visible in
 * Files.app.
 *
 * MV's StorageManager is synchronous, so every save is pre-loaded into memory
 * by GameWebContext before the engine starts. MZ's StorageManager is
 * Promise-based and talks to the native bridge directly.
 */
(function () {
  'use strict';

  var cfg = window.__SPARK_CONFIG__ || {};
  var Spark = window.Spark = window.Spark || {};
  var log = Spark.log || function (text) { try { console.log(text); } catch (e) {} };

  var engine = String(cfg.engine || '').toUpperCase();
  var saveExtension = String(cfg.saveExtension || 'rpgsave').replace(/^\./, '');
  var handlers = (window.webkit && window.webkit.messageHandlers) || null;
  var hasBridge = !!(handlers && handlers.saveBridge);

  var bytesCache = Object.create(null);
  var textCache = Object.create(null);
  var knownNames = Object.create(null);

  var readCallbacks = Object.create(null);
  var listCallbacks = [];
  var nextID = 1;

  function post(message) {
    if (!hasBridge) return false;
    try {
      handlers.saveBridge.postMessage(message);
      return true;
    } catch (error) {
      log('saveBridge post failed: ' + error);
      return false;
    }
  }

  // MARK: - Encoding

  function utf8Bytes(text) {
    if (window.TextEncoder) return new TextEncoder().encode(String(text));
    var encoded = unescape(encodeURIComponent(String(text)));
    var bytes = new Uint8Array(encoded.length);
    for (var i = 0; i < encoded.length; i++) bytes[i] = encoded.charCodeAt(i);
    return bytes;
  }

  function utf8String(bytes) {
    if (!bytes) return '';
    if (window.TextDecoder) return new TextDecoder('utf-8').decode(bytes);
    var binary = '';
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    try { return decodeURIComponent(escape(binary)); } catch (error) { return binary; }
  }

  function bytesFromBase64(text) {
    var binary = atob(text);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  function base64FromBytes(bytes) {
    var chunk = 0x8000;
    var parts = [];
    for (var i = 0; i < bytes.length; i += chunk) {
      parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + chunk)));
    }
    return btoa(parts.join(''));
  }

  // MARK: - Cache

  function rememberBytes(name, bytes) {
    if (!name) return;
    bytesCache[name] = bytes;
    textCache[name] = utf8String(bytes);
    knownNames[name] = true;
  }

  function rememberText(name, text) {
    if (!name) return;
    rememberBytes(name, utf8Bytes(text));
  }

  (function preload() {
    var saves = cfg.saves || {};
    for (var name in saves) {
      if (!Object.prototype.hasOwnProperty.call(saves, name)) continue;
      try {
        rememberBytes(name, bytesFromBase64(saves[name]));
      } catch (error) {
        log('save preload failed for ' + name + ': ' + error);
      }
    }
    if (Object.keys(knownNames).length) {
      log('preloaded ' + Object.keys(knownNames).length + ' save file(s)');
    }
  })();

  // MARK: - Native read / list

  function requestRead(name, callback) {
    if (!hasBridge) {
      callback(null);
      return;
    }
    var id = nextID++;
    readCallbacks[id] = { name: name, callback: callback };
    post({ action: 'read', name: name, id: id, request: id });
    setTimeout(function () {
      var pending = readCallbacks[id];
      if (!pending) return;
      delete readCallbacks[id];
      pending.callback(null);
    }, 8000);
  }

  window.__sparkSaveReadResult = function (name, base64) {
    var resolved = false;
    for (var id in readCallbacks) {
      if (!Object.prototype.hasOwnProperty.call(readCallbacks, id)) continue;
      var pending = readCallbacks[id];
      if (pending.name !== name) continue;
      delete readCallbacks[id];
      resolved = true;
      try {
        var bytes = base64 ? bytesFromBase64(base64) : new Uint8Array(0);
        rememberBytes(name, bytes);
        pending.callback(bytes);
      } catch (error) {
        log('save read decode failed for ' + name + ': ' + error);
        pending.callback(null);
      }
    }
    if (!resolved) {
      try {
        if (base64) rememberBytes(name, bytesFromBase64(base64));
      } catch (error) {}
    }
  };

  function requestList(callback) {
    if (!hasBridge) {
      if (callback) callback(Object.keys(knownNames));
      return;
    }
    if (callback) listCallbacks.push(callback);
    post({ action: 'list' });
    setTimeout(function () {
      if (!listCallbacks.length) return;
      var backups = listCallbacks.slice();
      listCallbacks.length = 0;
      backups.forEach(function (cb) { cb(Object.keys(knownNames)); });
    }, 3000);
  }

  window.__sparkSaveListResult = function (names) {
    if (Array.isArray(names)) {
      names.forEach(function (name) { knownNames[name] = true; });
    }
    var callbacks = listCallbacks.slice();
    listCallbacks.length = 0;
    callbacks.forEach(function (callback) {
      try { callback(Array.isArray(names) ? names : Object.keys(knownNames)); } catch (error) {}
    });
  };

  // MARK: - Public save store

  var Saves = Spark.saves = {
    names: function () { return Object.keys(knownNames); },
    exists: function (name) { return !!knownNames[name]; },
    readText: function (name) {
      if (typeof textCache[name] === 'string') return textCache[name];
      return null;
    },
    readBytes: function (name) {
      return bytesCache[name] || null;
    },
    writeText: function (name, text) {
      rememberText(name, String(text));
      post({ action: 'save', name: name, data: String(text) });
    },
    writeBytes: function (name, bytes) {
      rememberBytes(name, bytes);
      post({ action: 'save', name: name, data: base64FromBytes(bytes), encoding: 'base64' });
    },
    remove: function (name) {
      delete bytesCache[name];
      delete textCache[name];
      delete knownNames[name];
      post({ action: 'remove', name: name });
      return true;
    },
    requestRead: function (name) {
      return new Promise(function (resolve) {
        if (bytesCache[name]) { resolve(bytesCache[name]); return; }
        requestRead(name, resolve);
      });
    },
    list: function () {
      return new Promise(function (resolve) { requestList(resolve); });
    }
  };

  // MARK: - MV (synchronous StorageManager)

  function mvFileName(savefileId) {
    var name;
    if (savefileId === 0) name = 'global';
    else if (savefileId < 0) name = 'config';
    else name = 'file' + savefileId;
    return name + '.' + saveExtension;
  }

  function patchMV(manager) {
    if (!manager || manager.__sparkPatched) return false;
    manager.__sparkPatched = true;

    manager.isLocalMode = function () { return true; };

    manager.localFileDirectoryPath = function () {
      return String(cfg.virtualCwd || '') + '/save/';
    };

    manager.localFileName = function (savefileId) {
      return mvFileName(savefileId);
    };

    manager.webStorageKey = function (savefileId) {
      return mvFileName(savefileId);
    };

    manager.saveToLocalFile = function (savefileId, json) {
      Saves.writeText(mvFileName(savefileId), String(json));
    };

    manager.loadFromLocalFile = function (savefileId) {
      return Saves.readText(mvFileName(savefileId));
    };

    manager.saveToWebStorage = function (savefileId, json) {
      Saves.writeText(mvFileName(savefileId), String(json));
    };

    manager.loadFromWebStorage = function (savefileId) {
      return Saves.readText(mvFileName(savefileId));
    };

    manager.fileExists = function (savefileId) {
      return Saves.exists(mvFileName(savefileId));
    };

    manager.exists = function (savefileId) {
      return Saves.exists(mvFileName(savefileId));
    };

    manager.webStorageExists = function (savefileId) {
      return Saves.exists(mvFileName(savefileId));
    };

    manager.removeLocalFile = function (savefileId) {
      Saves.remove(mvFileName(savefileId));
    };

    manager.removeWebStorage = function (savefileId) {
      Saves.remove(mvFileName(savefileId));
    };

    log('MV StorageManager patched for native saves');
    return true;
  }

  // MARK: - MZ (Promise based StorageManager)

  function mzFileName(saveName) {
    var value = String(saveName || '');
    if (/\.[A-Za-z0-9]+$/.test(value)) return value;
    return value + '.' + saveExtension;
  }

  function bytesFromZip(zip) {
    if (!zip) return new Uint8Array(0);
    if (zip instanceof Uint8Array) return zip;
    if (zip instanceof ArrayBuffer) return new Uint8Array(zip);
    if (ArrayBuffer.isView(zip)) {
      return new Uint8Array(zip.buffer, zip.byteOffset || 0, zip.byteLength);
    }
    if (typeof zip === 'string') {
      var bytes = new Uint8Array(zip.length);
      for (var i = 0; i < zip.length; i++) bytes[i] = zip.charCodeAt(i) & 0xff;
      return bytes;
    }
    if (typeof Blob !== 'undefined' && zip instanceof Blob) {
      return zip.arrayBuffer().then(function (buffer) { return new Uint8Array(buffer); });
    }
    return new Uint8Array(0);
  }

  function writeZip(name, zip) {
    return Promise.resolve(zip).then(function (value) {
      return bytesFromZip(value);
    }).then(function (bytes) {
      return Promise.resolve(bytes).then(function (resolved) {
        var array = resolved instanceof Uint8Array ? resolved : new Uint8Array(resolved);
        Saves.writeBytes(name, array);
      });
    }).catch(function (error) {
      log('MZ save failed for ' + name + ': ' + error);
    });
  }

  function readBlob(name) {
    if (bytesCache[name]) {
      return Promise.resolve(new Blob([bytesCache[name]]));
    }
    return new Promise(function (resolve) {
      requestRead(name, function (bytes) {
        if (!bytes) { resolve(null); return; }
        resolve(new Blob([bytes]));
      });
    });
  }

  function patchMZ(manager) {
    if (!manager || manager.__sparkPatched) return false;
    manager.__sparkPatched = true;

    manager.isLocalMode = function () { return true; };
    manager.saveFileName = function (saveName) { return mzFileName(saveName); };
    manager.localFileDirectoryPath = function () {
      return String(cfg.virtualCwd || '') + '/save/';
    };
    manager.localFilePath = function (saveName) {
      return manager.localFileDirectoryPath() + mzFileName(saveName);
    };

    manager.saveZip = function (saveName, zip) {
      return writeZip(mzFileName(saveName), zip);
    };
    manager.loadZip = function (saveName) {
      return readBlob(mzFileName(saveName));
    };
    manager.saveToLocalFile = function (saveName, zip) {
      return writeZip(mzFileName(saveName), zip);
    };
    manager.loadFromLocalFile = function (saveName) {
      return readBlob(mzFileName(saveName));
    };
    manager.saveToForage = function (saveName, zip) {
      return writeZip(mzFileName(saveName), zip);
    };
    manager.loadFromForage = function (saveName) {
      return readBlob(mzFileName(saveName));
    };

    manager.exists = function (saveName) {
      var name = mzFileName(saveName);
      if (Saves.exists(name)) return Promise.resolve(true);
      return new Promise(function (resolve) {
        requestList(function (names) {
          resolve(names.indexOf(name) >= 0);
        });
      });
    };

    manager.fileExists = function (saveName) {
      return Saves.exists(mzFileName(saveName));
    };

    manager.remove = function (saveName) {
      Saves.remove(mzFileName(saveName));
      return Promise.resolve();
    };

    log('MZ StorageManager patched for native saves');
    return true;
  }

  // MARK: - Patch as soon as the engine defines StorageManager

  var patched = false;
  var attempts = 0;

  function attemptPatch() {
    var manager = window.StorageManager;
    if (!manager) return false;

    // Feature-detect the engine instead of trusting cfg.engine: a mislabelled
    // game must still save correctly.
    var looksLikeMZ = typeof manager.saveZip === 'function' || typeof manager.loadZip === 'function';
    var looksLikeMV = typeof manager.localFileName === 'function'
      || typeof manager.saveToWebStorage === 'function'
      || typeof manager.loadFromWebStorage === 'function';

    if (looksLikeMZ) return patchMZ(manager);
    if (looksLikeMV) return patchMV(manager);

    if (engine === 'MZ') return patchMZ(manager);
    if (engine === 'MV' || engine === 'WEB') return patchMV(manager);
    return false;
  }

  if (attemptPatch()) {
    patched = true;
  } else {
    var patchTimer = setInterval(function () {
      attempts += 1;
      if (attemptPatch()) {
        patched = true;
        clearInterval(patchTimer);
      } else if (attempts > 1200) {
        clearInterval(patchTimer);
        log('StorageManager was never defined; saves rely on the native bridge only');
      }
    }, 50);
  }

  // Some engines call the bridge list once at boot for the load menu.
  setTimeout(function () { requestList(null); }, 1200);

  Spark.log('storage shim ready (ext: ' + saveExtension + ', preloaded: ' + Object.keys(knownNames).length + ')');
})();
