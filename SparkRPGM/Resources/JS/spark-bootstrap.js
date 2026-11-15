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

    var originalOpen = XMLHttpRequest.prototype.open;
    var originalSend = XMLHttpRequest.prototype.send;
    var originalStatusDesc = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'status');
    var originalStatusTextDesc = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'statusText');

    XMLHttpRequest.prototype.open = function (method, url, async, user, password) {
      this._sparkMethod = method || 'GET';
      this._sparkRawUrl = url;
      this._sparkFailed = false;

      var resolvedUrl = url;
      try {
        if (typeof url === 'string') {
          // If relative path under file:// or rpgm://, resolve cleanly against baseURI / location.href
          if (url.indexOf('://') === -1) {
            var base = document.baseURI || window.location.href;
            resolvedUrl = new URL(url, base).href;
          }
        }
      } catch (e) {
        resolvedUrl = url;
      }
      this._sparkResolvedUrl = resolvedUrl;

      var isAsync = async === undefined ? true : !!async;
      return originalOpen.call(this, method, resolvedUrl, isAsync, user, password);
    };

    XMLHttpRequest.prototype.send = function (body) {
      var self = this;
      var targetUrl = self._sparkResolvedUrl || self._sparkRawUrl || '';

      self.addEventListener('error', function () {
        self._sparkFailed = true;
        report('resource', 'Failed to load: ' + targetUrl, targetUrl, 0, {
          method: self._sparkMethod,
          url: targetUrl
        });
      }, false);

      try {
        return originalSend.apply(this, arguments);
      } catch (err) {
        self._sparkFailed = true;
        report('resource', 'Failed to load: ' + targetUrl + ' (' + (err.message || err) + ')', targetUrl, 0);
        throw err;
      }
    };

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
        if (rawStatus === 0 && this.readyState === 4 && !this._sparkFailed) {
          var hasContent = false;
          try {
            var rType = this.responseType;
            if (rType === '' || rType === 'text') {
              hasContent = typeof this.responseText === 'string' && this.responseText.length > 0;
            } else if (rType === 'arraybuffer') {
              hasContent = this.response && this.response.byteLength > 0;
            } else if (rType === 'blob') {
              hasContent = this.response && this.response.size > 0;
            } else if (rType === 'json') {
              hasContent = this.response !== null && this.response !== undefined;
            } else if (rType === 'document') {
              hasContent = this.responseXML !== null && this.responseXML !== undefined;
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

  // MARK: - 3. Property Setter Traps (Utils, DataManager, Graphics)

  // Utils trap: force isNwjs() = false and browser mode
  var _realUtils = window.Utils;
  function patchUtilsInstance(utils) {
    if (!utils || (typeof utils !== 'object' && typeof utils !== 'function')) return;
    try {
      utils.isNwjs = function () { return false; };
      utils.isOptionValid = function (name) {
        if (name === 'test' || name === 'btest') return false;
        return false;
      };
      utils.__sparkBrowserMode = true;
    } catch (e) {}
  }

  if (_realUtils) {
    patchUtilsInstance(_realUtils);
  }

  try {
    Object.defineProperty(window, 'Utils', {
      configurable: true,
      enumerable: true,
      get: function () {
        return _realUtils;
      },
      set: function (val) {
        _realUtils = val;
        patchUtilsInstance(val);
      }
    });
  } catch (e) {
    window.Utils = _realUtils;
  }

  // DataManager trap: intercept onXhrError and onError to report exact missing file
  var _realDataManager = window.DataManager;
  function patchDataManagerInstance(dm) {
    if (!dm || (typeof dm !== 'object' && typeof dm !== 'function')) return;
    try {
      if (dm.__sparkPatched) return;
      dm.__sparkPatched = true;

      // Wrap onXhrError (MZ)
      var origOnXhrError = dm.onXhrError;
      dm.onXhrError = function (name, src, url) {
        var failedUrl = url || ('data/' + src);
        report('resource', 'Failed to load: ' + failedUrl, failedUrl, 0, {
          dataName: name,
          src: src
        });
        if (origOnXhrError) {
          return origOnXhrError.apply(this, arguments);
        }
      };

      // Wrap onError (MV)
      var origOnError = dm.onError;
      dm.onError = function (name, src) {
        var failedUrl = 'data/' + src;
        report('resource', 'Failed to load: ' + failedUrl, failedUrl, 0, {
          dataName: name,
          src: src
        });
        if (origOnError) {
          try {
            return origOnError.apply(this, arguments);
          } catch (e) {
            var msg = e && e.message ? e.message : String(e);
            if (msg.indexOf('Your browser does not allow to read local files') !== -1) {
              throw new Error('Failed to load: ' + failedUrl);
            }
            throw e;
          }
        } else {
          throw new Error('Failed to load: ' + failedUrl);
        }
      };
    } catch (e) {}
  }

  if (_realDataManager) {
    patchDataManagerInstance(_realDataManager);
  }

  try {
    Object.defineProperty(window, 'DataManager', {
      configurable: true,
      enumerable: true,
      get: function () {
        return _realDataManager;
      },
      set: function (val) {
        _realDataManager = val;
        patchDataManagerInstance(val);
      }
    });
  } catch (e) {
    window.DataManager = _realDataManager;
  }

  // Graphics trap: intercept printError to report engine errors to Swift
  var _realGraphics = window.Graphics;
  function patchGraphicsInstance(gfx) {
    if (!gfx || (typeof gfx !== 'object' && typeof gfx !== 'function')) return;
    try {
      if (gfx.__sparkPatched) return;
      gfx.__sparkPatched = true;

      var origPrintError = gfx.printError;
      gfx.printError = function (name, message) {
        var detail = (name ? name + ': ' : '') + (message || '');
        report('graphics.error', detail, '', 0);
        if (origPrintError) {
          return origPrintError.apply(this, arguments);
        }
      };
    } catch (e) {}
  }

  if (_realGraphics) {
    patchGraphicsInstance(_realGraphics);
  }

  try {
    Object.defineProperty(window, 'Graphics', {
      configurable: true,
      enumerable: true,
      get: function () {
        return _realGraphics;
      },
      set: function (val) {
        _realGraphics = val;
        patchGraphicsInstance(val);
      }
    });
  } catch (e) {
    window.Graphics = _realGraphics;
  }

  // Continuous fallback poller in case static classes are reassigned or defined late
  var enginePollAttempts = 0;
  var enginePollTimer = setInterval(function () {
    enginePollAttempts += 1;
    if (window.Utils) patchUtilsInstance(window.Utils);
    if (window.DataManager) patchDataManagerInstance(window.DataManager);
    if (window.Graphics) patchGraphicsInstance(window.Graphics);
    if (enginePollAttempts >= 600) {
      clearInterval(enginePollTimer);
    }
  }, 40);

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
