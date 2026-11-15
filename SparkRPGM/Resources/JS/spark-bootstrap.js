/* SparkRPGM — boot diagnostics, fetch polyfill, and storage deadlock guard.
 *
 * Injected before every other shim, at document start. Responsibilities:
 *  1. Polyfill window.fetch over XMLHttpRequest for rpgm:// and relative URLs
 *     so wasm, JSON, and plugin fetch calls never stall on custom schemes.
 *  2. Guard indexedDB / localforage and StorageManager so save data reads and writes
 *     synchronously / via Swift message handler without deadlocking Scene_Boot.
 *  3. Report live boot milestones (DOM ready, main.js loaded, Effekseer ready,
 *     Scene_Boot started, Title screen active) and errors to GamePlayerView.
 *  4. Force Utils.isNwjs() to report false for browser mode execution on iOS.
 */
(function () {
  'use strict';

  var cfg = window.__SPARK_CONFIG__ || {};
  var reported = Object.create(null);
  var reportCount = 0;
  var MAX_REPORTS = 30;

  function handlers() {
    return (window.webkit && window.webkit.messageHandlers) || null;
  }

  function post(name, payload) {
    var map = handlers();
    if (!map || !map[name]) return false;
    try {
      map[name].postMessage(payload === undefined ? null : payload);
      return true;
    } catch (error) {
      return false;
    }
  }

  function shorten(value, limit) {
    var text = String(value === undefined || value === null ? '' : value);
    if (text.length <= limit) return text;
    return text.slice(0, limit) + '...';
  }

  function report(kind, message, source, line, extra) {
    if (reportCount >= MAX_REPORTS) return;
    var key = kind + '|' + message + '|' + source + '|' + (line || 0);
    if (reported[key]) return;
    reported[key] = true;
    reportCount += 1;

    var payload = {
      kind: String(kind || 'error'),
      message: shorten(message, 900),
      source: shorten(source, 500),
      line: Number(line) || 0,
      engine: cfg.engine || 'unknown',
      title: cfg.gameTitle || '',
      readySent: !!(window.Spark && window.Spark.readySent)
    };
    if (extra) {
      for (var name in extra) {
        if (Object.prototype.hasOwnProperty.call(extra, name)) {
          payload[name] = extra[name];
        }
      }
    }

    post('sparkError', payload);
  }

  window.__sparkReportError = report;
  window.__sparkBrowserMode = true;

  // MARK: - Boot Stage Telemetry

  var currentBootStage = 'Starting...';
  function reportStage(stage, isFinished) {
    if (!stage || currentBootStage === stage) return;
    currentBootStage = stage;
    post('bootStage', {
      stage: stage,
      isFinished: !!isFinished,
      timestamp: Date.now()
    });
    try {
      if (window.console && window.console.log) {
        window.console.log('[SparkBoot] ' + stage);
      }
    } catch (e) {}
  }

  window.__sparkReportStage = reportStage;

  // MARK: - Console & Exception Logging

  var originalConsoleError = window.console ? window.console.error : null;
  if (window.console) {
    window.console.error = function () {
      try {
        var args = Array.prototype.slice.call(arguments);
        var msg = args.map(function (a) {
          if (a instanceof Error) return a.stack || a.message;
          if (typeof a === 'object' && a !== null) {
            try { return JSON.stringify(a); } catch (e) { return String(a); }
          }
          return String(a);
        }).join(' ');
        report('console.error', msg, '', 0);
      } catch (err) {}
      if (originalConsoleError) {
        originalConsoleError.apply(window.console, arguments);
      }
    };
  }

  window.addEventListener('error', function (event) {
    try {
      var target = event && event.target;
      var isElement = target && target !== window && target !== document && target.tagName;

      if (isElement) {
        var tag = String(target.tagName).toLowerCase();
        if (tag !== 'script' && tag !== 'link') return;
        var url = target.src || target.href || '';
        report('resource', 'Failed to load ' + tag + ': ' + url, url, 0, { tag: tag });
        return;
      }

      var message = (event && event.message) ? event.message : 'Unknown script error';
      var source = (event && event.filename) ? event.filename : '';
      var line = (event && event.lineno) ? event.lineno : 0;
      var column = (event && event.colno) ? event.colno : 0;
      report('script', message, source, line, { column: column });
    } catch (error) {}
  }, true);

  window.addEventListener('unhandledrejection', function (event) {
    try {
      var reason = event && event.reason;
      var message = 'Unhandled promise rejection';
      var source = '';
      if (reason) {
        if (typeof reason === 'string') {
          message = reason;
        } else if (reason.message) {
          message = reason.message;
          source = reason.fileName || reason.sourceURL || '';
        } else {
          message = String(reason);
        }
      }
      report('promise', message, source, 0);
    } catch (error) {}
  }, true);

  // MARK: - Native XMLHttpRequest status 0 patch for file:// URLs

  (function patchXHRForFileScheme() {
    if (typeof XMLHttpRequest === 'undefined') return;

    var originalStatusDesc = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'status');
    var originalStatusTextDesc = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'statusText');

    Object.defineProperty(XMLHttpRequest.prototype, 'status', {
      configurable: true,
      enumerable: true,
      get: function () {
        var rawStatus = 0;
        try {
          if (originalStatusDesc && originalStatusDesc.get) {
            rawStatus = originalStatusDesc.get.call(this);
          }
        } catch (e) {}

        // In WebKit file:// or custom scheme, successful requests report status 0.
        // If readyState is DONE (4), treat status 0 with non-empty response as 200 OK.
        if (rawStatus === 0 && this.readyState === 4) {
          var hasContent = false;
          try {
            var rType = this.responseType;
            if (rType === '' || rType === 'text') {
              hasContent = typeof this.responseText === 'string' && this.responseText.length > 0;
            } else if (rType === 'arraybuffer') {
              hasContent = this.response && this.response.byteLength > 0;
            } else if (rType === 'blob') {
              hasContent = this.response && this.response.size > 0;
            } else {
              hasContent = this.response !== null && this.response !== undefined;
            }
          } catch (err) {}
          if (hasContent) return 200;
        }
        return rawStatus;
      }
    });

    Object.defineProperty(XMLHttpRequest.prototype, 'statusText', {
      configurable: true,
      enumerable: true,
      get: function () {
        var rawText = '';
        try {
          if (originalStatusTextDesc && originalStatusTextDesc.get) {
            rawText = originalStatusTextDesc.get.call(this);
          }
        } catch (e) {}
        if ((!rawText || rawText === '') && this.status === 200) {
          return 'OK';
        }
        return rawText;
      }
    });
  })();

  // MARK: - 1. Polyfill window.fetch over XMLHttpRequest for file:// and rpgm:// URLs

  (function polyfillFetch() {
    var originalFetch = window.fetch;

    function isLocalOrRelative(input) {
      if (!input) return false;
      var urlStr = '';
      if (typeof input === 'string') {
        urlStr = input;
      } else if (typeof input === 'object' && input.url) {
        urlStr = String(input.url);
      }
      urlStr = urlStr.trim();
      if (urlStr.indexOf('file://') === 0 || urlStr.indexOf('rpgm://') === 0) return true;
      if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(urlStr)) {
        return false;
      }
      return true;
    }

    function createResponse(buffer, status, statusText, headersMap, url) {
      var bodyUsed = false;
      var headersObj = {
        get: function (name) {
          return headersMap[name.toLowerCase()] || null;
        },
        has: function (name) {
          return Object.prototype.hasOwnProperty.call(headersMap, name.toLowerCase());
        }
      };

      return {
        ok: status >= 200 && status < 300,
        status: status,
        statusText: statusText || (status >= 200 && status < 300 ? 'OK' : 'Error'),
        url: url,
        headers: headersObj,
        type: 'basic',
        redirected: false,
        get bodyUsed() { return bodyUsed; },
        arrayBuffer: function () {
          bodyUsed = true;
          return Promise.resolve(buffer);
        },
        text: function () {
          bodyUsed = true;
          try {
            if (typeof TextDecoder !== 'undefined') {
              return Promise.resolve(new TextDecoder('utf-8').decode(buffer));
            }
          } catch (e) {}
          var bytes = new Uint8Array(buffer);
          var str = '';
          for (var i = 0; i < bytes.length; i++) {
            str += String.fromCharCode(bytes[i]);
          }
          try {
            return Promise.resolve(decodeURIComponent(escape(str)));
          } catch (e) {
            return Promise.resolve(str);
          }
        },
        json: function () {
          return this.text().then(function (text) {
            return JSON.parse(text);
          });
        },
        blob: function () {
          bodyUsed = true;
          var mime = headersMap['content-type'] || 'application/octet-stream';
          return Promise.resolve(new Blob([buffer], { type: mime }));
        },
        clone: function () {
          return createResponse(buffer.slice(0), status, statusText, headersMap, url);
        }
      };
    }

    window.fetch = function (input, init) {
      if (!isLocalOrRelative(input)) {
        if (originalFetch) {
          return originalFetch.apply(window, arguments);
        }
      }

      var url = typeof input === 'string' ? input : (input && input.url ? input.url : String(input));
      var method = (init && init.method) || (input && input.method) || 'GET';

      return new Promise(function (resolve, reject) {
        var xhr = new XMLHttpRequest();
        xhr.open(method, url, true);
        xhr.responseType = 'arraybuffer';

        if (init && init.headers) {
          try {
            if (typeof init.headers.forEach === 'function') {
              init.headers.forEach(function (v, k) { xhr.setRequestHeader(k, v); });
            } else if (Array.isArray(init.headers)) {
              init.headers.forEach(function (pair) { xhr.setRequestHeader(pair[0], pair[1]); });
            } else {
              for (var key in init.headers) {
                if (Object.prototype.hasOwnProperty.call(init.headers, key)) {
                  xhr.setRequestHeader(key, init.headers[key]);
                }
              }
            }
          } catch (e) {}
        }

        xhr.onload = function () {
          var buffer = xhr.response || new ArrayBuffer(0);
          var status = xhr.status === 0 ? 200 : xhr.status;
          var statusText = xhr.statusText || 'OK';

          var rawHeaders = xhr.getAllResponseHeaders() || '';
          var headersMap = {};
          rawHeaders.split(/\r?\n/).forEach(function (line) {
            var idx = line.indexOf(':');
            if (idx > 0) {
              var hKey = line.slice(0, idx).trim().toLowerCase();
              var hVal = line.slice(idx + 1).trim();
              headersMap[hKey] = hVal;
            }
          });

          resolve(createResponse(buffer, status, statusText, headersMap, url));
        };

        xhr.onerror = function () {
          report('fetch', 'fetch failed over XHR: ' + url, url, 0);
          reject(new TypeError('Network request failed for ' + url));
        };

        xhr.ontimeout = function () {
          report('fetch', 'fetch timed out over XHR: ' + url, url, 0);
          reject(new TypeError('Network request timed out for ' + url));
        };

        try {
          xhr.send((init && init.body) || null);
        } catch (err) {
          reject(err);
        }
      });
    };
  })();

  // MARK: - 2. Prevent indexedDB / localforage Boot Deadlock

  (function guardStorage() {
    var saveMemoryStore = Object.create(null);

    // Synchronize initial keys from localStorage if available
    try {
      if (window.localStorage) {
        for (var i = 0; i < window.localStorage.length; i++) {
          var k = window.localStorage.key(i);
          if (k) {
            saveMemoryStore[k] = window.localStorage.getItem(k);
          }
        }
      }
    } catch (e) {}

    function normalizeSaveFileName(key) {
      var name = String(key || '').replace(/^rmmzsave\./, '').replace(/[^a-zA-Z0-9._-]/g, '_');
      if (!/\.[A-Za-z0-9]+$/.test(name)) {
        name += '.rmmzsave';
      }
      return name;
    }

    var sparkLocalForage = {
      _store: saveMemoryStore,
      getItem: function (key) {
        var val = saveMemoryStore[key];
        if (val === undefined) {
          try {
            val = window.localStorage ? window.localStorage.getItem(key) : null;
          } catch (e) { val = null; }
        }
        return Promise.resolve(val === undefined ? null : val);
      },
      setItem: function (key, value) {
        saveMemoryStore[key] = value;
        try {
          if (window.localStorage) {
            window.localStorage.setItem(key, typeof value === 'string' ? value : JSON.stringify(value));
          }
        } catch (e) {}
        post('saveBridge', {
          action: 'save',
          name: normalizeSaveFileName(key),
          data: typeof value === 'string' ? value : JSON.stringify(value)
        });
        return Promise.resolve(value);
      },
      removeItem: function (key) {
        delete saveMemoryStore[key];
        try {
          if (window.localStorage) window.localStorage.removeItem(key);
        } catch (e) {}
        post('saveBridge', {
          action: 'remove',
          name: normalizeSaveFileName(key)
        });
        return Promise.resolve();
      },
      clear: function () {
        saveMemoryStore = Object.create(null);
        return Promise.resolve();
      },
      length: function () {
        return Promise.resolve(Object.keys(saveMemoryStore).length);
      },
      key: function (n) {
        return Promise.resolve(Object.keys(saveMemoryStore)[n] || null);
      },
      keys: function () {
        return Promise.resolve(Object.keys(saveMemoryStore));
      },
      iterate: function (iterator) {
        var keys = Object.keys(saveMemoryStore);
        for (var i = 0; i < keys.length; i++) {
          var k = keys[i];
          try {
            var res = iterator(saveMemoryStore[k], k, i + 1);
            if (res !== undefined) return Promise.resolve(res);
          } catch (e) {}
        }
        return Promise.resolve();
      },
      ready: function () {
        return Promise.resolve();
      },
      setDriver: function () {
        return Promise.resolve();
      },
      config: function () {
        return true;
      },
      defineDriver: function () {
        return Promise.resolve();
      },
      driver: function () {
        return 'LOCALSTORAGE';
      },
      createInstance: function () {
        return sparkLocalForage;
      },
      dropInstance: function () {
        return Promise.resolve();
      }
    };

    try {
      Object.defineProperty(window, 'localforage', {
        configurable: true,
        enumerable: true,
        get: function () {
          return sparkLocalForage;
        },
        set: function () {
          // Keep sparkLocalForage active to prevent indexedDB deadlock on rpgm://
        }
      });
    } catch (e) {
      window.localforage = sparkLocalForage;
    }

    // Guard indexedDB.open in case any plugin invokes it directly
    if (window.indexedDB && typeof window.indexedDB.open === 'function') {
      var rawIdbOpen = window.indexedDB.open.bind(window.indexedDB);
      window.indexedDB.open = function () {
        var req;
        try {
          req = rawIdbOpen.apply(window.indexedDB, arguments);
        } catch (err) {
          req = {
            onsuccess: null,
            onerror: null,
            readyState: 'done',
            error: err
          };
        }
        setTimeout(function () {
          if (req && req.readyState !== 'done') {
            req.readyState = 'done';
            req.error = new Error('IndexedDB timed out on custom scheme; falling back');
            if (typeof req.onerror === 'function') {
              try { req.onerror({ target: req, type: 'error' }); } catch (e) {}
            }
          }
        }, 800);
        return req;
      };
    }

    // Guard StorageManager as soon as rmmz_managers.js defines it
    var smAttempts = 0;
    var smTimer = setInterval(function () {
      smAttempts += 1;
      var sm = window.StorageManager;
      if (sm) {
        clearInterval(smTimer);
        sm.isLocalMode = function () { return false; };

        var rawUpdate = sm.updateForageKeys;
        sm.updateForageKeys = function () {
          this._forageKeys = [];
          var self = this;
          return sparkLocalForage.iterate(function (value, key) {
            if (!self.isForageKey || self.isForageKey(key)) {
              self._forageKeys.push(key);
            }
          });
        };

        sm.forageKeys = function () {
          return this._forageKeys || [];
        };

        sm.forageExists = function (saveName) {
          var key = this.forageKey ? this.forageKey(saveName) : ('rmmzsave.' + saveName);
          return sparkLocalForage.getItem(key).then(function (data) {
            return data !== null && data !== undefined;
          });
        };

        sm.removeForage = function (saveName) {
          var key = this.forageKey ? this.forageKey(saveName) : ('rmmzsave.' + saveName);
          return sparkLocalForage.removeItem(key);
        };

        sm.saveToForage = function (saveName, zip) {
          var key = this.forageKey ? this.forageKey(saveName) : ('rmmzsave.' + saveName);
          return sparkLocalForage.setItem(key, zip);
        };

        sm.loadFromForage = function (saveName) {
          var key = this.forageKey ? this.forageKey(saveName) : ('rmmzsave.' + saveName);
          return sparkLocalForage.getItem(key);
        };
      } else if (smAttempts >= 600) {
        clearInterval(smTimer);
      }
    }, 40);
  })();

  // MARK: - 3. Force browser mode in MV / MZ

  var patchedUtils = false;
  var utilsAttempts = 0;

  function patchUtils() {
    var utils = window.Utils;
    if (!utils || (typeof utils !== 'object' && typeof utils !== 'function')) return false;
    if (patchedUtils) return true;
    try {
      utils.isNwjs = function () { return false; };
      utils.__sparkBrowserMode = true;
      patchedUtils = true;
      return true;
    } catch (error) {
      return false;
    }
  }

  if (!patchUtils()) {
    var utilsTimer = setInterval(function () {
      utilsAttempts += 1;
      if (patchUtils() || utilsAttempts >= 600) {
        clearInterval(utilsTimer);
      }
    }, 40);
  }

  // MARK: - WebAssembly guard & Effekseer milestone

  (function () {
    var wasm = window.WebAssembly;
    if (!wasm || typeof Promise === 'undefined') return;

    var effekseerNotified = false;
    function notifyEffekseer() {
      if (effekseerNotified) return;
      effekseerNotified = true;
      reportStage('Effekseer ready');
    }

    var effTimer = setInterval(function () {
      if (window.effekseer || window.Effekseer) {
        clearInterval(effTimer);
        notifyEffekseer();
      }
    }, 120);

    function watch(promise, label) {
      if (!promise || typeof promise.then !== 'function') return promise;
      var timer = setTimeout(function () {
        report('info', 'WebAssembly ' + label + ' is compiling (> 6s)', '', 0);
      }, 6000);
      return promise.then(function (value) {
        clearTimeout(timer);
        if (label && label.toLowerCase().indexOf('effekseer') !== -1) {
          notifyEffekseer();
        }
        return value;
      }, function (error) {
        clearTimeout(timer);
        var message = error && error.message ? error.message : error;
        report('wasm', 'WebAssembly ' + label + ' failed: ' + message, '', 0);
        throw error;
      });
    }

    ['instantiate', 'compile', 'instantiateStreaming', 'compileStreaming'].forEach(function (name) {
      var original = wasm[name];
      if (typeof original !== 'function') return;
      wasm[name] = function () {
        var result;
        try {
          result = original.apply(wasm, arguments);
        } catch (error) {
          return original.apply(wasm, arguments);
        }
        return watch(result, name);
      };
    });
  })();

  // MARK: - Milestone Listeners (DOM, main.js, Scenes)

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      reportStage('DOM ready');
    }, false);
  } else {
    reportStage('DOM ready');
  }

  window.addEventListener('load', function () {
    reportStage('main.js loaded');
  }, false);

  var sceneAttempts = 0;
  var sceneTimer = setInterval(function () {
    sceneAttempts += 1;
    var sm = window.SceneManager;
    if (sm) {
      var currentScene = sm._scene || sm._nextScene;
      if (currentScene) {
        var name = (currentScene.constructor && currentScene.constructor.name) || '';
        if (name === 'Scene_Boot') {
          reportStage('Scene_Boot started');
        } else if (name === 'Scene_Title') {
          clearInterval(sceneTimer);
          reportStage('Title screen active', true);
          post('gameReady', { reason: 'title-active', hasEngine: true });
        } else if (name) {
          clearInterval(sceneTimer);
          reportStage(name + ' active', true);
          post('gameReady', { reason: 'scene-active', hasEngine: true });
        }
      }
    }
    if (sceneAttempts >= 600) {
      clearInterval(sceneTimer);
    }
  }, 100);
})();
