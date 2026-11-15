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
  var pendingXHRs = Object.create(null);
  var pendingImages = Object.create(null);

  try {
    var origImageSrcDesc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
    if (origImageSrcDesc && origImageSrcDesc.set) {
      Object.defineProperty(HTMLImageElement.prototype, 'src', {
        configurable: true,
        enumerable: true,
        get: function () {
          return origImageSrcDesc.get.call(this);
        },
        set: function (url) {
          var self = this;
          var imgUrl = String(url || '');
          if (imgUrl && imgUrl.indexOf('data:') !== 0) {
            pendingImages[imgUrl] = Date.now();
            var onDone = function () {
              delete pendingImages[imgUrl];
              self.removeEventListener('load', onDone);
              self.removeEventListener('error', onDone);
              self.removeEventListener('abort', onDone);
            };
            self.addEventListener('load', onDone, false);
            self.addEventListener('error', onDone, false);
            self.addEventListener('abort', onDone, false);
          }
          return origImageSrcDesc.set.call(this, url);
        }
      });
    }
  } catch (e) {}

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

  // MARK: - Error Formatting Helper (JavaScriptCore stack fix)

  function formatError(err) {
    if (!err) return 'Unknown error';
    if (Array.isArray(err) && err[0] === 'LoadError') {
      return 'Failed to load: ' + err[1];
    }
    if (err instanceof Error || (typeof err === 'object' && err !== null && (err.name || err.message))) {
      var name = err.name || 'Error';
      var message = err.message || '';
      var title = name + (message ? ': ' + message : '');
      var stack = err.stack ? String(err.stack) : '';
      if (stack) {
        // JavaScriptCore on iOS omits the error name and message from stack.
        // Prepend "name: message" if not already present at the start.
        if (stack.indexOf(title) !== 0 && stack.indexOf(message) === -1) {
          return title + '\n' + stack;
        }
        return stack;
      }
      return title;
    }
    return String(err);
  }

  // MARK: - Console & Exception Logging

  var originalConsoleError = window.console ? window.console.error : null;
  if (window.console) {
    window.console.error = function () {
      try {
        var args = Array.prototype.slice.call(arguments);
        var msg = args.map(function (a) {
          if (a instanceof Error || (typeof a === 'object' && a !== null && (a.name || a.message))) {
            return formatError(a);
          }
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

      var errorObj = event && event.error;
      var message = errorObj ? formatError(errorObj) : ((event && event.message) ? event.message : 'Unknown script error');
      var source = (event && event.filename) ? event.filename : '';
      var line = (event && event.lineno) ? event.lineno : 0;
      var column = (event && event.colno) ? event.colno : 0;
      report('script', message, source, line, { column: column });
    } catch (error) {}
  }, true);

  var origWindowOnError = window.onerror;
  window.onerror = function (message, source, lineno, colno, error) {
    try {
      var fullMsg = error ? formatError(error) : (message || 'Unknown script error');
      report('script', fullMsg, source || '', lineno || 0, { column: colno || 0 });
    } catch (e) {}
    if (typeof origWindowOnError === 'function') {
      return origWindowOnError.apply(window, arguments);
    }
    return false;
  };

  window.addEventListener('unhandledrejection', function (event) {
    try {
      var reason = event && event.reason;
      var message = 'Unhandled promise rejection';
      var source = '';
      if (reason) {
        if (reason instanceof Error || (typeof reason === 'object' && reason !== null && (reason.name || reason.message))) {
          message = formatError(reason);
          source = reason.fileName || reason.sourceURL || '';
        } else if (typeof reason === 'string') {
          message = reason;
        } else {
          try { message = JSON.stringify(reason); } catch (e) { message = String(reason); }
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

      if (targetUrl) {
        pendingXHRs[targetUrl] = Date.now();
        var onComplete = function () {
          delete pendingXHRs[targetUrl];
          self.removeEventListener('load', onComplete);
          self.removeEventListener('error', onComplete);
          self.removeEventListener('abort', onComplete);
          self.removeEventListener('timeout', onComplete);
        };
        self.addEventListener('load', onComplete, false);
        self.addEventListener('error', onComplete, false);
        self.addEventListener('abort', onComplete, false);
        self.addEventListener('timeout', onComplete, false);
      }

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
        if (targetUrl) delete pendingXHRs[targetUrl];
        self._sparkFailed = true;
        report('resource', 'Failed to load: ' + targetUrl + ' (' + (err.message || err) + ')', targetUrl, 0);
        throw err;
      }
    };

    Object.defineProperty(XMLHttpRequest.prototype, 'status', {
      configurable: true,
      enumerable: true,
      get: function () {
        if (typeof this._sparkCustomStatus !== 'undefined') {
          return this._sparkCustomStatus;
        }
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
      },
      set: function (val) {
        this._sparkCustomStatus = val;
      }
    });

    Object.defineProperty(XMLHttpRequest.prototype, 'statusText', {
      configurable: true,
      enumerable: true,
      get: function () {
        if (typeof this._sparkCustomStatusText !== 'undefined') {
          return this._sparkCustomStatusText;
        }
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
      },
      set: function (val) {
        this._sparkCustomStatusText = val;
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
      _config: {
        name: 'localforage',
        storeName: 'keyvaluepairs',
        description: '',
        driver: 'localStorageWrapper',
        size: 4980736,
        version: 1.0
      },
      INDEXEDDB: 'asyncStorage',
      WEBSQL: 'webSQLStorage',
      LOCALSTORAGE: 'localStorageWrapper',
      getItem: function (key, callback) {
        var val = saveMemoryStore[key];
        if (val === undefined) {
          try {
            val = window.localStorage ? window.localStorage.getItem(key) : null;
          } catch (e) { val = null; }
        }
        var p = Promise.resolve(val === undefined ? null : val);
        if (typeof callback === 'function') {
          p.then(function (res) { callback(null, res); }, function (err) { callback(err); });
        }
        return p;
      },
      setItem: function (key, value, callback) {
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
        var p = Promise.resolve(value);
        if (typeof callback === 'function') {
          p.then(function (res) { callback(null, res); }, function (err) { callback(err); });
        }
        return p;
      },
      removeItem: function (key, callback) {
        delete saveMemoryStore[key];
        try {
          if (window.localStorage) window.localStorage.removeItem(key);
        } catch (e) {}
        post('saveBridge', {
          action: 'remove',
          name: normalizeSaveFileName(key)
        });
        var p = Promise.resolve();
        if (typeof callback === 'function') {
          p.then(function () { callback(null); }, function (err) { callback(err); });
        }
        return p;
      },
      clear: function (callback) {
        saveMemoryStore = Object.create(null);
        var p = Promise.resolve();
        if (typeof callback === 'function') {
          p.then(function () { callback(null); }, function (err) { callback(err); });
        }
        return p;
      },
      length: function (callback) {
        var len = Object.keys(saveMemoryStore).length;
        var p = Promise.resolve(len);
        if (typeof callback === 'function') {
          p.then(function (res) { callback(null, res); }, function (err) { callback(err); });
        }
        return p;
      },
      key: function (n, callback) {
        var k = Object.keys(saveMemoryStore)[n] || null;
        var p = Promise.resolve(k);
        if (typeof callback === 'function') {
          p.then(function (res) { callback(null, res); }, function (err) { callback(err); });
        }
        return p;
      },
      keys: function (callback) {
        var list = Object.keys(saveMemoryStore);
        var p = Promise.resolve(list);
        if (typeof callback === 'function') {
          p.then(function (res) { callback(null, res); }, function (err) { callback(err); });
        }
        return p;
      },
      iterate: function (iterator, callback) {
        var keys = Object.keys(saveMemoryStore);
        var result;
        for (var i = 0; i < keys.length; i++) {
          var k = keys[i];
          try {
            var res = iterator(saveMemoryStore[k], k, i + 1);
            if (res !== undefined) {
              result = res;
              break;
            }
          } catch (e) {
            var errP = Promise.reject(e);
            if (typeof callback === 'function') callback(e);
            return errP;
          }
        }
        var p = Promise.resolve(result);
        if (typeof callback === 'function') {
          p.then(function (r) { callback(null, r); });
        }
        return p;
      },
      ready: function (callback) {
        var p = Promise.resolve();
        if (typeof callback === 'function') {
          p.then(function () { callback(null); });
        }
        return p;
      },
      setDriver: function (drivers, callback, errorCallback) {
        var p = Promise.resolve();
        if (typeof callback === 'function') {
          p.then(function () { callback(); });
        }
        return p;
      },
      config: function (options) {
        if (typeof options === 'object' && options !== null) {
          for (var opt in options) {
            if (Object.prototype.hasOwnProperty.call(options, opt)) {
              this._config[opt] = options[opt];
            }
          }
          return true;
        }
        if (typeof options === 'string') {
          return this._config[options];
        }
        return this._config;
      },
      defineDriver: function (driverObj, callback, errorCallback) {
        var p = Promise.resolve();
        if (typeof callback === 'function') {
          p.then(function () { callback(); });
        }
        return p;
      },
      driver: function () {
        return 'localStorageWrapper';
      },
      supports: function () {
        return true;
      },
      createInstance: function (options) {
        var inst = Object.create(sparkLocalForage);
        if (options && typeof options === 'object') {
          inst._config = Object.assign({}, sparkLocalForage._config, options);
        }
        return inst;
      },
      dropInstance: function (options, callback) {
        var p = Promise.resolve();
        if (typeof callback === 'function') {
          p.then(function () { callback(null); });
        }
        return p;
      }
    };

    try {
      Object.defineProperty(window, 'localforage', {
        configurable: true,
        enumerable: true,
        get: function () {
          return sparkLocalForage;
        },
        set: function (newLF) {
          if (newLF && typeof newLF === 'object') {
            for (var prop in newLF) {
              try {
                if (typeof sparkLocalForage[prop] === 'undefined') {
                  sparkLocalForage[prop] = newLF[prop];
                }
              } catch (e) {}
            }
          }
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

    // StorageManager implementation & patching for VisuMZ_1_SaveCore & CGMZ_Core
    function patchStorageManager(sm) {
      if (!sm || (typeof sm !== 'object' && typeof sm !== 'function')) return;
      try {
        sm._forageKeys = sm._forageKeys || [];
        sm.isLocalMode = function () { return false; };
        sm.fileDirectoryPath = function () { return 'save/'; };
        sm.localFileDirectoryPath = function () { return 'save/'; };
        sm.filePath = function (saveName) {
          var k = this.forageKey ? this.forageKey(saveName) : ('rmmzsave.' + saveName);
          return this.fileDirectoryPath() + k;
        };
        if (!sm.forageKey) {
          sm.forageKey = function (saveName) { return 'rmmzsave.' + saveName; };
        }
        if (!sm.isForageKey) {
          sm.isForageKey = function (key) { return String(key || '').indexOf('rmmzsave.') === 0; };
        }
        sm.forageKeys = function () {
          return this._forageKeys || [];
        };
        sm.updateForageKeys = function () {
          this._forageKeys = [];
          var self = this;
          return sparkLocalForage.iterate(function (value, key) {
            if (!self.isForageKey || self.isForageKey(key)) {
              self._forageKeys.push(key);
            }
          }).then(function () {
            return self._forageKeys;
          });
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
          var zipString = typeof zip === 'string' ? zip : (zip !== null && zip !== undefined ? JSON.stringify(zip) : '');
          return sparkLocalForage.setItem(key, zipString);
        };
        sm.saveZip = function (saveName, zip) {
          return this.saveToForage(saveName, zip);
        };
        sm.loadFromForage = function (saveName) {
          var key = this.forageKey ? this.forageKey(saveName) : ('rmmzsave.' + saveName);
          return sparkLocalForage.getItem(key).then(function (data) {
            if (data !== null && data !== undefined && data !== '') {
              return data;
            } else {
              return Promise.reject(new Error("Save not found: " + saveName));
            }
          });
        };
        sm.loadZip = function (saveName) {
          return this.loadFromForage(saveName);
        };
        var origZipToJson = sm.zipToJson;
        sm.zipToJson = function (zip) {
          if (typeof zip === 'string') {
            var trimmed = zip.trim();
            if (trimmed.charAt(0) === '{' || trimmed.charAt(0) === '[') {
              return zip;
            }
          }
          if (origZipToJson) {
            try {
              return origZipToJson.apply(this, arguments);
            } catch (e) {
              return zip;
            }
          }
          return zip;
        };
        if (!sm.exists) {
          sm.exists = function (saveName) { return this.forageExists(saveName); };
        }
        if (!sm.remove) {
          sm.remove = function (saveName) { return this.removeForage(saveName); };
        }
      } catch (e) {}
    }

    window.__sparkPatchStorageManager = patchStorageManager;

    if (!window.StorageManager) {
      window.StorageManager = function StorageManager() {
        throw new Error('This is a static class');
      };
    }
    patchStorageManager(window.StorageManager);

    var smAttempts = 0;
    var smTimer = setInterval(function () {
      smAttempts += 1;
      if (window.StorageManager) {
        patchStorageManager(window.StorageManager);
      }
      if (smAttempts >= 600) {
        clearInterval(smTimer);
      }
    }, 40);
  })();

  // MARK: - 3. Non-destructive shims for Utils, DataManager, Graphics, SceneManager

  function patchUtilsInstance(utils) {
    if (!utils || (typeof utils !== 'object' && typeof utils !== 'function')) return;
    try {
      var _isNwjsFn = function () { return false; };
      try {
        Object.defineProperty(utils, 'isNwjs', {
          configurable: true,
          enumerable: true,
          get: function () {
            return _isNwjsFn;
          },
          set: function (newFn) {
            // Allows safe assignment in strict mode without throwing
            _isNwjsFn = function () { return false; };
          }
        });
      } catch (err) {
        utils.isNwjs = function () { return false; };
      }

      if (!utils.isOptionValid) {
        utils.isOptionValid = function (name) {
          if (name === 'test' || name === 'btest') return false;
          return false;
        };
      }
      utils.__sparkBrowserMode = true;
    } catch (e) {}
  }

  // Ensure window.Utils is a normal writable property
  if (typeof window.Utils === 'undefined') {
    window.Utils = function Utils() {
      throw new Error('This is a static class');
    };
  }
  patchUtilsInstance(window.Utils);

  // DataManager: intercept onXhrError and onError to report exact missing file
  function patchDataManagerInstance(dm) {
    if (!dm || (typeof dm !== 'object' && typeof dm !== 'function')) return;
    try {
      if (!dm.__sparkErrorPatched) {
        dm.__sparkErrorPatched = true;

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
      }

      wrapDataManagerGlobalInfo(dm);
    } catch (e) {}
  }

  // MARK: - Late StorageManager & DataManager.loadGlobalInfo Wrappers

  function wrapStorageMethod(sm, methodName) {
    if (!sm) return;
    var current = sm[methodName];
    if (typeof current !== 'function' || current.__sparkLateWrapped) return;

    var wrapped = function (saveName) {
      var self = this;
      var nameStr = String(saveName || '');

      // Whenever StorageManager.exists(saveName) is false, reject immediately
      try {
        if (typeof self.exists === 'function') {
          var ex = self.exists(saveName);
          if (ex === false) {
            return Promise.reject(new Error("Save not found: " + nameStr));
          }
        }
      } catch (e) {}

      var p;
      try {
        p = current.apply(self, arguments);
      } catch (err) {
        return Promise.reject(err);
      }

      return Promise.resolve(p).then(function (val) {
        if (val === null || val === undefined || (typeof val === 'string' && val === '')) {
          return Promise.reject(new Error("Save not found: " + nameStr));
        }
        return val;
      });
    };

    wrapped.__sparkLateWrapped = true;
    sm[methodName] = wrapped;
  }

  function wrapDataManagerGlobalInfo(dm) {
    if (!dm) return;
    var current = dm.loadGlobalInfo;
    if (typeof current === 'function' && !current.__sparkLateWrapped) {
      var wrapped = function () {
        var self = this;
        var timer = setTimeout(function () {
          if (!self._globalInfo) {
            report('info', 'DataManager.loadGlobalInfo timed out (1000ms); initialized _globalInfo = []', '', 0);
            self._globalInfo = [];
          }
        }, 1000);

        try {
          var result = current.apply(self, arguments);
          if (result && typeof result.then === 'function') {
            result.then(function () {
              clearTimeout(timer);
              if (!self._globalInfo) self._globalInfo = [];
            }, function () {
              clearTimeout(timer);
              if (!self._globalInfo) self._globalInfo = [];
            });
          }
          return result;
        } catch (e) {
          clearTimeout(timer);
          report('info', 'DataManager.loadGlobalInfo threw synchronously; initialized _globalInfo = []', '', 0);
          self._globalInfo = [];
        }
      };

      wrapped.__sparkLateWrapped = true;
      dm.loadGlobalInfo = wrapped;
    }

    if (typeof dm.isGlobalInfoLoaded === 'function' && !dm.isGlobalInfoLoaded.__sparkLateWrapped) {
      var origIsLoaded = dm.isGlobalInfoLoaded;
      var wrappedIsLoaded = function () {
        try {
          var res = origIsLoaded.apply(this, arguments);
          if (res) return true;
        } catch (e) {}
        return !!this._globalInfo;
      };
      wrappedIsLoaded.__sparkLateWrapped = true;
      dm.isGlobalInfoLoaded = wrappedIsLoaded;
    }
  }

  function reapplyStorageAndDataManagerPatches() {
    var sm = window.StorageManager;
    if (sm) {
      if (typeof window.__sparkPatchStorageManager === 'function') {
        window.__sparkPatchStorageManager(sm);
      }
      wrapStorageMethod(sm, 'loadFromForage');
      wrapStorageMethod(sm, 'loadZip');
      wrapStorageMethod(sm, 'loadObject');
    }

    var dm = window.DataManager;
    if (dm) {
      if (typeof patchDataManagerInstance === 'function') {
        patchDataManagerInstance(dm);
      }
      wrapDataManagerGlobalInfo(dm);
    }
  }

  if (typeof window.DataManager !== 'undefined') {
    patchDataManagerInstance(window.DataManager);
  }

  // Graphics: intercept printError to report engine errors to Swift with formatted stack
  function patchGraphicsInstance(gfx) {
    if (!gfx || (typeof gfx !== 'object' && typeof gfx !== 'function')) return;
    try {
      if (gfx.__sparkPatched) return;
      gfx.__sparkPatched = true;

      var origPrintError = gfx.printError;
      gfx.printError = function (name, message, error) {
        var title = (name ? name + ': ' : '') + (message || '');
        var formatted = error ? formatError(error) : title;
        if (formatted.indexOf(title) === -1) {
          formatted = title + '\n' + formatted;
        }
        report('graphics.error', formatted, '', 0);
        if (origPrintError) {
          return origPrintError.apply(this, arguments);
        }
      };
    } catch (e) {}
  }

  if (typeof window.Graphics !== 'undefined') {
    patchGraphicsInstance(window.Graphics);
  }

  // SceneManager: run hook, catchNormalError, and catchException reporting
  function patchSceneManagerInstance(sm) {
    if (!sm || (typeof sm !== 'object' && typeof sm !== 'function')) return;
    try {
      if (typeof sm.run === 'function' && !sm.run.__sparkRunHooked) {
        var origRun = sm.run;
        var wrappedRun = function (sceneClass) {
          try {
            reapplyStorageAndDataManagerPatches();
          } catch (e) {}
          return origRun.apply(this, arguments);
        };
        wrappedRun.__sparkRunHooked = true;
        sm.run = wrappedRun;
      }

      if (!sm.__sparkErrorPatched) {
        sm.__sparkErrorPatched = true;

        var origCatchNormalError = sm.catchNormalError;
        sm.catchNormalError = function (e) {
          var formatted = formatError(e);
          report('engine.error', formatted, '', 0);
          if (origCatchNormalError) {
            return origCatchNormalError.apply(this, arguments);
          }
        };

        var origCatchException = sm.catchException;
        sm.catchException = function (e) {
          var formatted = formatError(e);
          report('engine.error', formatted, '', 0);
          if (origCatchException) {
            return origCatchException.apply(this, arguments);
          }
        };
      }
    } catch (e) {}
  }

  if (typeof window.SceneManager !== 'undefined') {
    patchSceneManagerInstance(window.SceneManager);
  }

  // MARK: - iOS 15 WebM Video & FontManager Fallback Hooks

  function isVideoFormatSupported(src) {
    if (!src) return true;
    var extMatch = String(src).match(/\.([a-zA-Z0-9]+)(?:\?|#|$)/);
    var ext = extMatch ? extMatch[1].toLowerCase() : '';
    if (ext === 'webm') return false; // iOS 15 WKWebView does not support .webm video

    var mime = '';
    if (ext === 'mp4' || ext === 'm4v') mime = 'video/mp4';
    else if (ext === 'mov') mime = 'video/quicktime';
    else if (ext === 'ogv' || ext === 'ogg') mime = 'video/ogg';

    if (mime) {
      try {
        var v = document.createElement('video');
        var can = v.canPlayType(mime);
        return can !== '' && can !== 'no';
      } catch (e) {
        return true;
      }
    }
    return true;
  }

  function hookVideo(v) {
    if (!v || v.__sparkHooked) return;
    v.__sparkHooked = true;

    var origPlay = v.play;
    if (typeof origPlay === 'function') {
      v.play = function (src) {
        if (!isVideoFormatSupported(src)) {
          report('info', 'Skipping unsupported video format on iOS: ' + src, src, 0);
          v._loading = false;
          try {
            if (typeof v._onEnd === 'function') {
              v._onEnd();
            } else if (typeof v._onVideoEnd === 'function') {
              v._onVideoEnd();
            }
          } catch (e) {}
          return;
        }
        return origPlay.apply(this, arguments);
      };
    }
  }

  function hookGraphicsVideo(gfx) {
    if (!gfx || gfx.__sparkVideoHooked) return;
    gfx.__sparkVideoHooked = true;

    var origPlayVideo = gfx.playVideo;
    if (typeof origPlayVideo === 'function') {
      gfx.playVideo = function (src) {
        if (!isVideoFormatSupported(src)) {
          report('info', 'Skipping unsupported video format on iOS: ' + src, src, 0);
          gfx._videoLoading = false;
          try {
            if (typeof gfx._onVideoEnd === 'function') {
              gfx._onVideoEnd();
            }
          } catch (e) {}
          if (window.Video) {
            window.Video._loading = false;
            try {
              if (typeof window.Video._onEnd === 'function') {
                window.Video._onEnd();
              }
            } catch (e) {}
          }
          return;
        }
        return origPlayVideo.apply(this, arguments);
      };
    }
  }

  function hookFontManager(fm) {
    if (!fm || fm.__sparkHooked) return;
    fm.__sparkHooked = true;

    var origLoad = fm.load;
    if (typeof origLoad === 'function') {
      fm.load = function (family, url) {
        var self = this;
        setTimeout(function () {
          if (self._states && self._states[family] === 'loading') {
            report('info', 'Font load timed out after 2s, marking loaded: ' + family, url || '', 0);
            self._states[family] = 'loaded';
          }
        }, 2000);
        return origLoad.apply(this, arguments);
      };
    }

    var origIsReady = fm.isReady;
    fm.isReady = function () {
      if (this._states) {
        for (var family in this._states) {
          if (this._states[family] === 'loading') {
            if (!this._sparkTimers) this._sparkTimers = {};
            if (!this._sparkTimers[family]) {
              this._sparkTimers[family] = Date.now();
            } else if (Date.now() - this._sparkTimers[family] > 2000) {
              report('info', 'Font stalled > 2s in isReady(), marking loaded: ' + family, '', 0);
              this._states[family] = 'loaded';
            }
          }
        }
      }
      if (origIsReady) {
        return origIsReady.apply(this, arguments);
      }
      return true;
    };
  }

  if (typeof window.Video !== 'undefined') hookVideo(window.Video);
  if (typeof window.FontManager !== 'undefined') hookFontManager(window.FontManager);

  // Continuous fallback poller in case static classes are reassigned or defined late
  var enginePollAttempts = 0;
  var enginePollTimer = setInterval(function () {
    enginePollAttempts += 1;
    if (window.Utils) patchUtilsInstance(window.Utils);
    if (window.DataManager) patchDataManagerInstance(window.DataManager);
    if (window.Graphics) {
      patchGraphicsInstance(window.Graphics);
      hookGraphicsVideo(window.Graphics);
    }
    if (window.SceneManager) patchSceneManagerInstance(window.SceneManager);
    if (window.StorageManager && window.__sparkPatchStorageManager) {
      window.__sparkPatchStorageManager(window.StorageManager);
    }
    if (window.StorageManager || window.DataManager) {
      reapplyStorageAndDataManagerPatches();
    }
    if (window.Video) hookVideo(window.Video);
    if (window.FontManager) hookFontManager(window.FontManager);
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

  // MARK: - Continuous Scene & Asset Stall Watchdog

  var stallStartTime = null;
  var lastReportedStallText = '';

  function reportStall(diagnosticMessage) {
    if (!diagnosticMessage || diagnosticMessage === lastReportedStallText) return;
    lastReportedStallText = diagnosticMessage;
    post('sparkError', {
      kind: 'stall',
      message: shorten(diagnosticMessage, 1500),
      source: '',
      line: 0,
      engine: cfg.engine || 'unknown',
      title: cfg.gameTitle || '',
      readySent: !!(window.Spark && window.Spark.readySent)
    });
  }

  function checkReadinessWatchdog() {
    var sm = window.SceneManager;
    var gfx = window.Graphics;
    if (!sm && !gfx) return;

    var scene = (sm && (sm._scene || sm._nextScene)) || null;
    var sceneName = (scene && scene.constructor && scene.constructor.name) || 'Scene_Boot';

    var dm = window.DataManager;
    var dbBool = false;
    var giBool = false;
    var dbLoaded = 'n/a';
    var giLoaded = 'n/a';
    if (dm) {
      try {
        if (typeof dm.isDatabaseLoaded === 'function') {
          dbBool = dm.isDatabaseLoaded();
          dbLoaded = String(dbBool);
        }
      } catch (e) { dbLoaded = 'err'; }
      try {
        if (typeof dm.isGlobalInfoLoaded === 'function') {
          giBool = dm.isGlobalInfoLoaded();
          giLoaded = String(giBool);
        }
      } catch (e) { giLoaded = 'err'; }
    }

    // Watchdog Safety Recovery:
    // In the readiness watchdog, if Scene_Boot is active with DB === true and GlobalInfo === false,
    // automatically set DataManager._globalInfo = DataManager._globalInfo || [] so the game immediately proceeds to Scene_Title instead of hanging.
    if (sceneName === 'Scene_Boot' && dbBool === true && giBool === false && dm) {
      report('info', 'Watchdog safety recovery: setting DataManager._globalInfo = [] for Scene_Boot', '', 0);
      dm._globalInfo = dm._globalInfo || [];
      giBool = true;
      giLoaded = 'true (recovered)';
    }

    var isSceneReady = true;
    if (scene && typeof scene.isReady === 'function') {
      try {
        isSceneReady = scene.isReady();
      } catch (e) {
        isSceneReady = false;
      }
    }

    var loadingCount = (gfx && typeof gfx._loadingCount === 'number') ? gfx._loadingCount : 0;
    var videoLoading = !!((window.Video && window.Video._loading) || (gfx && gfx._videoLoading));

    var isStalled = (loadingCount > 0) || (scene && !isSceneReady) || videoLoading;

    var now = Date.now();
    if (!isStalled) {
      stallStartTime = null;
      return;
    }

    if (!stallStartTime) {
      stallStartTime = now;
      return;
    }

    if (now - stallStartTime >= 2500) {
      if (sceneName === 'Scene_Boot' && dbBool === true && (!dm || !dm.isGlobalInfoLoaded || !dm.isGlobalInfoLoaded())) {
        if (dm) {
          dm._globalInfo = dm._globalInfo || [];
          giLoaded = 'true (recovered)';
        }
      }

      var unreadyBitmaps = [];
      function recordBitmap(bmp, key) {
        if (!bmp) return;
        try {
          if (typeof bmp.isReady === 'function' && !bmp.isReady()) {
            var url = bmp._url || bmp.url || key || 'unknown';
            var state = bmp._loadingState || (typeof bmp.isError === 'function' && bmp.isError() ? 'error' : 'loading');
            unreadyBitmaps.push(url + ' [' + state + ']');
          }
        } catch (e) {}
      }

      function inspectBitmaps(target) {
        if (!target) return;
        try {
          if (target._inner) inspectBitmaps(target._inner);
          if (typeof target.forEach === 'function') {
            target.forEach(function (bmp, k) {
              recordBitmap(bmp, k);
            });
          } else if (typeof target === 'object') {
            for (var k in target) {
              if (!Object.prototype.hasOwnProperty.call(target, k)) continue;
              recordBitmap(target[k], k);
            }
          }
        } catch (e) {}
      }

      var im = window.ImageManager;
      if (im) {
        inspectBitmaps(im._cache);
        inspectBitmaps(im._system);
      }

      var fm = window.FontManager;
      var fmReady = 'n/a';
      var unreadyFonts = [];
      if (fm) {
        try {
          if (typeof fm.isReady === 'function') {
            fmReady = String(fm.isReady());
          }
          if (fm._states) {
            for (var fontName in fm._states) {
              if (fm._states[fontName] !== 'loaded') {
                unreadyFonts.push(fontName + ' (' + fm._states[fontName] + ')');
              }
            }
          }
        } catch (e) {}
      }

      var xhrKeys = Object.keys(pendingXHRs || {});

      var lines = [];
      lines.push('Scene: ' + sceneName);
      lines.push('LoadingCount: ' + loadingCount);
      lines.push('DB / GlobalInfo: DB=' + dbLoaded + ', GlobalInfo=' + giLoaded);

      var fontVideo = 'FontManager.isReady()=' + fmReady;
      if (unreadyFonts.length > 0) {
        fontVideo += ' [' + unreadyFonts.join(', ') + ']';
      }
      fontVideo += ' | Video._loading=' + videoLoading;
      lines.push('Fonts / Video: ' + fontVideo);

      if (unreadyBitmaps.length > 0) {
        lines.push('Unready Bitmaps (' + unreadyBitmaps.length + '): ' + unreadyBitmaps.slice(0, 4).join(', ') + (unreadyBitmaps.length > 4 ? ' (+' + (unreadyBitmaps.length - 4) + ' more)' : ''));
      } else {
        lines.push('Unready Bitmaps: none');
      }

      if (xhrKeys.length > 0) {
        lines.push('Pending XHRs (' + xhrKeys.length + '): ' + xhrKeys.slice(0, 3).join(', '));
      }

      var diagnosticText = 'Stall detected (>2.5s):\n' + lines.join('\n');
      reportStall(diagnosticText);
    }
  }

  // Poll continuously every 2.5 seconds
  setInterval(checkReadinessWatchdog, 2500);

  // MARK: - Milestone Listeners (DOM, main.js, Scenes)

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      reapplyStorageAndDataManagerPatches();
      reportStage('DOM ready');
    }, false);
  } else {
    reapplyStorageAndDataManagerPatches();
    reportStage('DOM ready');
  }

  window.addEventListener('load', function () {
    reapplyStorageAndDataManagerPatches();
    reportStage('main.js loaded');
  }, false);

  var sceneAttempts = 0;
  var sceneTimer = setInterval(function () {
    sceneAttempts += 1;
    var sm = window.SceneManager;
    if (sm) {
      if (typeof patchSceneManagerInstance === 'function') {
        patchSceneManagerInstance(sm);
      }
      reapplyStorageAndDataManagerPatches();
      var currentScene = sm._scene || sm._nextScene;
      if (currentScene) {
        var name = (currentScene.constructor && currentScene.constructor.name) || '';
        if (name === 'Scene_Boot') {
          if (!window.Spark || !window.Spark._bootStarted) {
            window.Spark = window.Spark || {};
            window.Spark._bootStarted = true;
            reportStage('Scene_Boot started');
          }
        } else if (name) {
          var isReady = false;
          try {
            isReady = typeof currentScene.isReady === 'function' ? currentScene.isReady() : true;
          } catch (e) {
            isReady = true;
          }
          if (isReady && (!window.Spark || !window.Spark.readySent)) {
            clearInterval(sceneTimer);
            window.Spark = window.Spark || {};
            window.Spark.readySent = true;
            var label = name === 'Scene_Title' ? 'Title screen active' : name + ' active';
            reportStage(label, true);
            post('gameReady', { reason: name === 'Scene_Title' ? 'title-active' : 'scene-active', hasEngine: true });
          }
        }
      }
    }
    if (sceneAttempts >= 600) {
      clearInterval(sceneTimer);
    }
  }, 100);
})();
