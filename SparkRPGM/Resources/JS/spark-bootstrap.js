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

  // MARK: - Gamepad Polyfill for iOS WKWebView file://

  try {
    if (typeof navigator !== 'undefined' && typeof navigator.getGamepads !== 'function') {
      var emptyGamepads = function () { return []; };
      try {
        navigator.getGamepads = emptyGamepads;
      } catch (e) {
        try {
          Object.defineProperty(navigator, 'getGamepads', {
            configurable: true,
            writable: true,
            value: emptyGamepads
          });
        } catch (e2) {
          if (typeof Navigator !== 'undefined' && Navigator.prototype) {
            try {
              Object.defineProperty(Navigator.prototype, 'getGamepads', {
                configurable: true,
                writable: true,
                value: emptyGamepads
              });
            } catch (e3) {}
          }
        }
      }
    }
  } catch (e) {}

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
    if (!err) return 'Error: Unknown error';
    if (Array.isArray(err) && err[0] === 'LoadError') {
      return 'LoadError: Failed to load ' + (err[1] || 'resource');
    }
    if (typeof err === 'string') {
      var str = err.trim();
      if (/^[a-zA-Z_$][a-zA-Z0-9_$]*Error:/.test(str)) {
        return str;
      }
      return 'Error: ' + str;
    }
    if (err instanceof Error || (typeof err === 'object' && err !== null && (err.name || err.message))) {
      var name = err.name || 'Error';
      var message = err.message || '';
      var title = name + (message ? ': ' + message : '');
      var stack = err.stack ? String(err.stack).trim() : '';
      if (stack) {
        // JavaScriptCore on iOS omits the error name and message from stack.
        // Prepend "name: message" if not already present at the start.
        if (stack.indexOf(title) === 0) {
          return stack;
        }
        if (message && stack.indexOf(message) === 0) {
          stack = stack.slice(message.length).replace(/^[\r\n]+/, '');
        }
        return title + (stack ? '\n' + stack : '');
      }
      return title;
    }
    return 'Error: ' + String(err);
  }

  // MARK: - JsonEx Cycle Guard & Safe Depth Fallback

  function patchJsonExInstance(jsonEx) {
    if (!jsonEx || typeof jsonEx._encode !== 'function' || jsonEx._encode.__sparkWrapped) return;
    var origEncode = jsonEx._encode;

    jsonEx._encode = function (value, circular, depth) {
      depth = depth || 0;
      var max = (typeof jsonEx.maxDepth === 'number' && jsonEx.maxDepth > 0) ? jsonEx.maxDepth : 100;
      if (depth >= max) {
        return null; // Safe depth fallback instead of throwing "Object too deep"
      }

      if (!circular) circular = [];

      if (value && typeof value === 'object' && value !== null) {
        if (!circular.__sparkSeen) {
          try { circular.__sparkSeen = new WeakSet(); } catch (err) {}
        }
        if (circular.__sparkSeen) {
          if (circular.__sparkSeen.has(value)) {
            var cName = (typeof jsonEx._getConstructorName === 'function') ? jsonEx._getConstructorName(value) : '';
            var idx = circular.indexOf(value);
            return { "@": cName, "@c": idx !== -1 ? idx : 0 };
          }
          try { circular.__sparkSeen.add(value); } catch (err) {}
        } else if (circular.indexOf(value) !== -1) {
          var cName2 = (typeof jsonEx._getConstructorName === 'function') ? jsonEx._getConstructorName(value) : '';
          return { "@": cName2, "@c": circular.indexOf(value) };
        }
      }

      try {
        return origEncode.call(this, value, circular, depth);
      } catch (e) {
        var msg = e && e.message ? String(e.message) : '';
        if (msg.indexOf('too deep') !== -1 || e instanceof RangeError) {
          return null; // Return null on depth/stack overflow instead of throwing
        }
        throw e;
      }
    };
    jsonEx._encode.__sparkWrapped = true;

    if (typeof jsonEx.makeDeepCopy === 'function' && !jsonEx.makeDeepCopy.__sparkWrapped) {
      var origDeepCopy = jsonEx.makeDeepCopy;
      jsonEx.makeDeepCopy = function (object) {
        try {
          return origDeepCopy.apply(this, arguments);
        } catch (e) {
          var msg = e && e.message ? String(e.message) : '';
          if (msg.indexOf('too deep') !== -1 || e instanceof RangeError) {
            if (Array.isArray(object)) return object.slice();
            if (object && typeof object === 'object') {
              var copy = {};
              for (var k in object) {
                if (Object.prototype.hasOwnProperty.call(object, k)) copy[k] = object[k];
              }
              return copy;
            }
          }
          throw e;
        }
      };
      jsonEx.makeDeepCopy.__sparkWrapped = true;
    }
  }

  var rawJsonEx = window.JsonEx;
  if (rawJsonEx) patchJsonExInstance(rawJsonEx);
  try {
    Object.defineProperty(window, 'JsonEx', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawJsonEx;
      },
      set: function (val) {
        rawJsonEx = val;
        patchJsonExInstance(val);
      }
    });
  } catch (e) {}


  function sanitizePluginsList(list) {
    if (Array.isArray(list)) {
      for (var i = 0; i < list.length; i++) {
        if (list[i] && typeof list[i] === 'object') {
          list[i].parameters = list[i].parameters || {};
        }
      }
    }
  }

  var rawPlugins = window.$plugins;
  if (rawPlugins) sanitizePluginsList(rawPlugins);
  try {
    Object.defineProperty(window, '$plugins', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawPlugins;
      },
      set: function (val) {
        rawPlugins = val;
        sanitizePluginsList(rawPlugins);
      }
    });
  } catch (e) {}

  function patchPluginManager(pm) {
    if (!pm) return;
    try {
      if (typeof pm.parameters === 'function' && !pm.parameters.__sparkWrapped) {
        var origParams = pm.parameters;
        var wrappedParams = function (name) {
          try {
            var res = origParams.apply(this, arguments);
            if (res && typeof res === 'object') return res;
          } catch (e) {}
          var key = String(name || '').toLowerCase();
          if (this._parameters && this._parameters[key]) {
            return this._parameters[key];
          }
          return {};
        };
        wrappedParams.__sparkWrapped = true;
        pm.parameters = wrappedParams;
      }

      if (typeof pm.setup === 'function' && !pm.setup.__sparkWrapped) {
        var origSetup = pm.setup;
        var wrappedSetup = function (plugins) {
          sanitizePluginsList(plugins);
          return origSetup.apply(this, arguments);
        };
        wrappedSetup.__sparkWrapped = true;
        pm.setup = wrappedSetup;
      }
    } catch (e) {}
  }

  var rawPluginManager = window.PluginManager;
  if (rawPluginManager) patchPluginManager(rawPluginManager);
  try {
    Object.defineProperty(window, 'PluginManager', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawPluginManager;
      },
      set: function (val) {
        rawPluginManager = val;
        patchPluginManager(val);
      }
    });
  } catch (e) {}

  function ensureButtonCommonEventsDefaults() {
    try {
      if (!window.VisuMZ) return;
      if (!window.VisuMZ.ButtonCommonEvents || typeof window.VisuMZ.ButtonCommonEvents !== 'object') {
        window.VisuMZ.ButtonCommonEvents = {};
      }
      var bce = window.VisuMZ.ButtonCommonEvents;
      if (!Array.isArray(bce.List)) bce.List = [];
      if (!Array.isArray(bce.Buttons)) bce.Buttons = [];
      if (!Array.isArray(bce.Events)) bce.Events = [];
      if (!Array.isArray(bce.CommonEvents)) bce.CommonEvents = [];
      if (!Array.isArray(bce.Data)) bce.Data = [];
      if (!Array.isArray(bce.data)) bce.data = [];
      if (!bce.Settings || typeof bce.Settings !== 'object') bce.Settings = {};
    } catch (e) {}
  }

  function patchGameSystem(gs) {
    if (!gs || !gs.prototype || typeof gs.prototype.initialize !== 'function' || gs.prototype.initialize.__sparkWrapped) return;
    var origInit = gs.prototype.initialize;
    var wrappedInit = function () {
      ensureButtonCommonEventsDefaults();
      try {
        return origInit.apply(this, arguments);
      } catch (e) {
        var formatted = formatError(e);
        report('info', 'Game_System.initialize recovered: ' + formatted, '', 0);
        try {
          if (window.console && window.console.warn) {
            window.console.warn('[SparkBoot] Game_System.initialize caught error:', formatted);
          }
        } catch (err) {}
        if (this._saveEnabled === undefined) this._saveEnabled = true;
        if (this._menuEnabled === undefined) this._menuEnabled = true;
        if (this._encounterEnabled === undefined) this._encounterEnabled = true;
        if (this._formationEnabled === undefined) this._formationEnabled = true;
        this._battleCount = this._battleCount || 0;
        this._winCount = this._winCount || 0;
        this._escapeCount = this._escapeCount || 0;
        this._saveCount = this._saveCount || 0;
        this._versionId = this._versionId || 0;
        this._framesOnSave = this._framesOnSave || 0;
        this._bgmOnSave = this._bgmOnSave || null;
        this._bgsOnSave = this._bgsOnSave || null;
        this._windowTone = this._windowTone || null;
        this._battleBgm = this._battleBgm || null;
        this._victoryMe = this._victoryMe || null;
        this._defeatMe = this._defeatMe || null;
        this._savedBgm = this._savedBgm || null;
        this._walkingBgm = this._walkingBgm || null;
      }
    };
    wrappedInit.__sparkWrapped = true;
    gs.prototype.initialize = wrappedInit;
  }

  var rawGameSystem = window.Game_System;
  if (rawGameSystem) patchGameSystem(rawGameSystem);
  try {
    Object.defineProperty(window, 'Game_System', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawGameSystem;
      },
      set: function (val) {
        rawGameSystem = val;
        patchGameSystem(val);
      }
    });
  } catch (e) {}

  // MARK: - Sprite_ButtonCommonEventsContainer & Scene_Map Button Overlay Guards

  function patchSpriteButtonCommonEventsContainer(cls) {
    if (!cls || !cls.prototype) return;
    ensureButtonCommonEventsDefaults();

    var methods = ['initialize', 'createButtons', 'refresh', 'setupButtons', 'update'];
    for (var i = 0; i < methods.length; i++) {
      var methodName = methods[i];
      try {
        if (typeof cls.prototype[methodName] === 'function' && !cls.prototype[methodName].__sparkWrapped) {
          (function (mName, origMethod) {
            var wrappedMethod = function () {
              ensureButtonCommonEventsDefaults();
              try {
                return origMethod.apply(this, arguments);
              } catch (e) {
                report('info', 'Sprite_ButtonCommonEventsContainer.' + mName + ' recovered: ' + formatError(e), '', 0);
                return null;
              }
            };
            wrappedMethod.__sparkWrapped = true;
            cls.prototype[mName] = wrappedMethod;
          })(methodName, cls.prototype[methodName]);
        }
      } catch (err) {}
    }
  }

  var rawButtonContainer = window.Sprite_ButtonCommonEventsContainer;
  if (rawButtonContainer) patchSpriteButtonCommonEventsContainer(rawButtonContainer);
  try {
    Object.defineProperty(window, 'Sprite_ButtonCommonEventsContainer', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawButtonContainer;
      },
      set: function (val) {
        rawButtonContainer = val;
        patchSpriteButtonCommonEventsContainer(val);
      }
    });
  } catch (e) {}

  function patchSceneMap(sm) {
    if (!sm || !sm.prototype) return;
    try {
      if (typeof sm.prototype.createButtonCommonEvents === 'function' && !sm.prototype.createButtonCommonEvents.__sparkWrapped) {
        var origCreate = sm.prototype.createButtonCommonEvents;
        var wrappedCreate = function () {
          ensureButtonCommonEventsDefaults();
          try {
            return origCreate.apply(this, arguments);
          } catch (e) {
            report('info', 'Scene_Map.createButtonCommonEvents recovered: ' + formatError(e), '', 0);
          }
        };
        wrappedCreate.__sparkWrapped = true;
        sm.prototype.createButtonCommonEvents = wrappedCreate;
      }
    } catch (e) {}
  }

  var rawSceneMap = window.Scene_Map;
  if (rawSceneMap) patchSceneMap(rawSceneMap);
  try {
    Object.defineProperty(window, 'Scene_Map', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawSceneMap;
      },
      set: function (val) {
        rawSceneMap = val;
        patchSceneMap(val);
      }
    });
  } catch (e) {}

  // MARK: - Game_BattlerBase & Game_Actor Trait Objects & States Sanitizer

  function patchGameBattlerBase(gbb) {
    if (!gbb || !gbb.prototype) return;
    try {
      if (typeof gbb.prototype.traitObjects === 'function' && !gbb.prototype.traitObjects.__sparkWrapped) {
        var origTraitObjects = gbb.prototype.traitObjects;
        var wrappedTraitObjects = function () {
          try {
            var list = origTraitObjects.call(this);
            if (Array.isArray(list)) {
              return list.filter(function (obj) {
                return obj && Array.isArray(obj.traits);
              });
            }
            return list;
          } catch (e) {
            return [];
          }
        };
        wrappedTraitObjects.__sparkWrapped = true;
        gbb.prototype.traitObjects = wrappedTraitObjects;
      }
    } catch (e) {}

    try {
      if (typeof gbb.prototype.states === 'function' && !gbb.prototype.states.__sparkWrapped) {
        var origStates = gbb.prototype.states;
        var wrappedStates = function () {
          try {
            var list = origStates.call(this);
            if (Array.isArray(list)) {
              return list.filter(function (s) {
                return s && typeof s === 'object';
              });
            }
            return [];
          } catch (e) {
            return [];
          }
        };
        wrappedStates.__sparkWrapped = true;
        gbb.prototype.states = wrappedStates;
      }
    } catch (e) {}

    try {
      if (typeof gbb.prototype.allTraits === 'function' && !gbb.prototype.allTraits.__sparkWrapped) {
        var origAllTraits = gbb.prototype.allTraits;
        var wrappedAllTraits = function () {
          try {
            var objs = this.traitObjects();
            if (Array.isArray(objs)) {
              return objs.reduce(function (r, obj) {
                return (obj && Array.isArray(obj.traits)) ? r.concat(obj.traits) : r;
              }, []);
            }
          } catch (e) {}
          try {
            return origAllTraits.call(this);
          } catch (e2) {
            return [];
          }
        };
        wrappedAllTraits.__sparkWrapped = true;
        gbb.prototype.allTraits = wrappedAllTraits;
      }
    } catch (e) {}

    try {
      if (typeof gbb.prototype.param === 'function' && !gbb.prototype.param.__sparkWrapped) {
        var origParam = gbb.prototype.param;
        var wrappedParam = function (paramId) {
          try {
            return origParam.call(this, paramId);
          } catch (e) {
            try {
              var base = (typeof this.paramBase === 'function') ? this.paramBase(paramId) : (paramId === 0 ? 500 : 10);
              var plus = (typeof this.paramPlus === 'function') ? this.paramPlus(paramId) : 0;
              return base + plus;
            } catch (e2) {
              return paramId === 0 ? 500 : 10;
            }
          }
        };
        wrappedParam.__sparkWrapped = true;
        gbb.prototype.param = wrappedParam;
      }
    } catch (e) {}
  }

  function patchGameActor(ga) {
    if (!ga || !ga.prototype) return;
    patchGameBattlerBase(ga);

    try {
      if (typeof ga.prototype.equips === 'function' && !ga.prototype.equips.__sparkWrapped) {
        var origEquips = ga.prototype.equips;
        var wrappedEquips = function () {
          try {
            var list = origEquips.call(this);
            if (Array.isArray(list)) {
              return list.map(function (eq) {
                return (eq && typeof eq === 'object') ? eq : null;
              });
            }
            return [];
          } catch (e) {
            return [];
          }
        };
        wrappedEquips.__sparkWrapped = true;
        ga.prototype.equips = wrappedEquips;
      }
    } catch (e) {}

    try {
      if (typeof ga.prototype.paramBase === 'function' && !ga.prototype.paramBase.__sparkWrapped) {
        var origParamBase = ga.prototype.paramBase;
        var wrappedParamBase = function (paramId) {
          try {
            var c = typeof this.currentClass === 'function' ? this.currentClass() : null;
            if (c && c.params && Array.isArray(c.params[paramId])) {
              var lvl = typeof this._level === 'number' ? this._level : 1;
              var val = c.params[paramId][lvl];
              if (typeof val === 'number') return val;
            }
            return origParamBase.call(this, paramId);
          } catch (e) {
            return paramId === 0 ? 500 : (paramId === 1 ? 100 : 10);
          }
        };
        wrappedParamBase.__sparkWrapped = true;
        ga.prototype.paramBase = wrappedParamBase;
      }
    } catch (e) {}

    try {
      if (typeof ga.prototype.paramPlus === 'function' && !ga.prototype.paramPlus.__sparkWrapped) {
        var origParamPlus = ga.prototype.paramPlus;
        var wrappedParamPlus = function (paramId) {
          try {
            return origParamPlus.call(this, paramId);
          } catch (e) {
            return 0;
          }
        };
        wrappedParamPlus.__sparkWrapped = true;
        ga.prototype.paramPlus = wrappedParamPlus;
      }
    } catch (e) {}
  }

  function hookSceneBootPrototype(sb) {
    if (!sb || !sb.prototype) return;
    try {
      var currentLoadSysImages = sb.prototype.loadSystemImages;
      function wrapLoadSysImages(fn) {
        if (!fn) return fn;
        var wrapped = function () {
          try {
            return fn.apply(this, arguments);
          } catch (e) {
            report('info', 'Scene_Boot.loadSystemImages recovered: ' + formatError(e), '', 0);
          }
        };
        wrapped.__sparkWrapped = true;
        return wrapped;
      }
      if (typeof currentLoadSysImages === 'function' && !currentLoadSysImages.__sparkWrapped) {
        currentLoadSysImages = wrapLoadSysImages(currentLoadSysImages);
      }
      try {
        Object.defineProperty(sb.prototype, 'loadSystemImages', {
          configurable: true,
          enumerable: true,
          get: function () {
            return currentLoadSysImages;
          },
          set: function (newFn) {
            currentLoadSysImages = wrapLoadSysImages(newFn);
          }
        });
      } catch (err) {
        if (currentLoadSysImages) sb.prototype.loadSystemImages = currentLoadSysImages;
      }
    } catch (e) {}

    try {
      var currentCreate = sb.prototype.create;
      function wrapCreate(fn) {
        if (!fn) return fn;
        var wrapped = function () {
          try {
            if (window.StorageManager && typeof window.StorageManager.updateForageKeys === 'function') {
              try {
                window.StorageManager.updateForageKeys();
              } catch (smErr) {
                report('info', 'StorageManager.updateForageKeys in Scene_Boot.create recovered: ' + formatError(smErr), '', 0);
              }
            }
          } catch (e) {}
          try {
            return fn.apply(this, arguments);
          } catch (e) {
            report('info', 'Scene_Boot.create recovered: ' + formatError(e), '', 0);
            try {
              if (typeof this.loadSystemImages === 'function') {
                this.loadSystemImages();
              }
            } catch (errImg) {}
          }
        };
        wrapped.__sparkWrapped = true;
        return wrapped;
      }
      if (typeof currentCreate === 'function' && !currentCreate.__sparkWrapped) {
        currentCreate = wrapCreate(currentCreate);
      }
      try {
        Object.defineProperty(sb.prototype, 'create', {
          configurable: true,
          enumerable: true,
          get: function () {
            return currentCreate;
          },
          set: function (newFn) {
            currentCreate = wrapCreate(newFn);
          }
        });
      } catch (err) {
        if (currentCreate) sb.prototype.create = currentCreate;
      }
    } catch (e) {}
  }

  function patchSceneBoot(sb) {
    if (!sb || !sb.prototype) return;
    try {
      hookSceneBootPrototype(sb);

      if (typeof sb.prototype.loadSystemImages === 'function' && !sb.prototype.loadSystemImages.__sparkWrapped) {
        var origLoadSysImages = sb.prototype.loadSystemImages;
        var wrappedLoadSysImages = function () {
          try {
            return origLoadSysImages.apply(this, arguments);
          } catch (e) {
            report('info', 'Scene_Boot.loadSystemImages recovered: ' + formatError(e), '', 0);
          }
        };
        wrappedLoadSysImages.__sparkWrapped = true;
        sb.prototype.loadSystemImages = wrappedLoadSysImages;
      }

      if (typeof sb.prototype.create === 'function' && !sb.prototype.create.__sparkWrapped) {
        var origCreate = sb.prototype.create;
        var wrappedCreate = function () {
          try {
            if (window.StorageManager && typeof window.StorageManager.updateForageKeys === 'function') {
              try {
                window.StorageManager.updateForageKeys();
              } catch (smErr) {
                report('info', 'StorageManager.updateForageKeys in Scene_Boot.create recovered: ' + formatError(smErr), '', 0);
              }
            }
          } catch (e) {}
          try {
            return origCreate.apply(this, arguments);
          } catch (e) {
            report('info', 'Scene_Boot.create recovered: ' + formatError(e), '', 0);
            try {
              if (typeof this.loadSystemImages === 'function') {
                this.loadSystemImages();
              }
            } catch (errImg) {}
          }
        };
        wrappedCreate.__sparkWrapped = true;
        sb.prototype.create = wrappedCreate;
      }

      if (typeof sb.prototype.onDatabaseLoaded === 'function' && !sb.prototype.onDatabaseLoaded.__sparkWrapped) {
        var origOnDbLoaded = sb.prototype.onDatabaseLoaded;
        var wrappedOnDbLoaded = function () {
          this._sparkOnDatabaseLoadedDone = true;
          this._databaseLoaded = true;
          return origOnDbLoaded.apply(this, arguments);
        };
        wrappedOnDbLoaded.__sparkWrapped = true;
        sb.prototype.onDatabaseLoaded = wrappedOnDbLoaded;
      }
    } catch (e) {}
  }

  function patchImageManager(im) {
    if (!im) return;
    try {
      var currentLoadSystem = im.loadSystem;
      function wrapLoadSystem(fn) {
        if (!fn) return fn;
        var wrapped = function (filename) {
          try {
            return fn.apply(this, arguments);
          } catch (e) {
            report('info', 'ImageManager.loadSystem(' + filename + ') recovered: ' + formatError(e), '', 0);
            return (this._emptyBitmap || null);
          }
        };
        wrapped.__sparkWrapped = true;
        return wrapped;
      }
      if (typeof currentLoadSystem === 'function' && !currentLoadSystem.__sparkWrapped) {
        currentLoadSystem = wrapLoadSystem(currentLoadSystem);
      }
      try {
        Object.defineProperty(im, 'loadSystem', {
          configurable: true,
          enumerable: true,
          get: function () {
            return currentLoadSystem;
          },
          set: function (newFn) {
            currentLoadSystem = wrapLoadSystem(newFn);
          }
        });
      } catch (err) {
        if (currentLoadSystem) im.loadSystem = currentLoadSystem;
      }

      var currentLoadBitmap = im.loadBitmap;
      function wrapLoadBitmap(fn) {
        if (!fn) return fn;
        var wrapped = function (folder, filename) {
          try {
            return fn.apply(this, arguments);
          } catch (e) {
            report('info', 'ImageManager.loadBitmap(' + folder + ', ' + filename + ') recovered: ' + formatError(e), '', 0);
            return (this._emptyBitmap || null);
          }
        };
        wrapped.__sparkWrapped = true;
        return wrapped;
      }
      if (typeof currentLoadBitmap === 'function' && !currentLoadBitmap.__sparkWrapped) {
        currentLoadBitmap = wrapLoadBitmap(currentLoadBitmap);
      }
      try {
        Object.defineProperty(im, 'loadBitmap', {
          configurable: true,
          enumerable: true,
          get: function () {
            return currentLoadBitmap;
          },
          set: function (newFn) {
            currentLoadBitmap = wrapLoadBitmap(newFn);
          }
        });
      } catch (err) {
        if (currentLoadBitmap) im.loadBitmap = currentLoadBitmap;
      }
    } catch (e) {}
  }

  var rawImageManager = window.ImageManager;
  if (rawImageManager) patchImageManager(rawImageManager);
  try {
    Object.defineProperty(window, 'ImageManager', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawImageManager;
      },
      set: function (val) {
        rawImageManager = val;
        patchImageManager(val);
      }
    });
  } catch (e) {}

  function patchColorManager(cm) {
    if (!cm) return;
    try {
      var currentLoadWindowskin = cm.loadWindowskin;
      function wrapLoadWindowskin(fn) {
        if (!fn) return fn;
        var wrapped = function () {
          try {
            return fn.apply(this, arguments);
          } catch (e) {
            report('info', 'ColorManager.loadWindowskin recovered: ' + formatError(e), '', 0);
          }
        };
        wrapped.__sparkWrapped = true;
        return wrapped;
      }
      if (typeof currentLoadWindowskin === 'function' && !currentLoadWindowskin.__sparkWrapped) {
        currentLoadWindowskin = wrapLoadWindowskin(currentLoadWindowskin);
      }
      try {
        Object.defineProperty(cm, 'loadWindowskin', {
          configurable: true,
          enumerable: true,
          get: function () {
            return currentLoadWindowskin;
          },
          set: function (newFn) {
            currentLoadWindowskin = wrapLoadWindowskin(newFn);
          }
        });
      } catch (err) {
        if (currentLoadWindowskin) cm.loadWindowskin = currentLoadWindowskin;
      }
    } catch (e) {}
  }

  var rawColorManager = window.ColorManager;
  if (rawColorManager) patchColorManager(rawColorManager);
  try {
    Object.defineProperty(window, 'ColorManager', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawColorManager;
      },
      set: function (val) {
        rawColorManager = val;
        patchColorManager(val);
      }
    });
  } catch (e) {}

  var rawGameBattlerBase = window.Game_BattlerBase;
  if (rawGameBattlerBase) patchGameBattlerBase(rawGameBattlerBase);
  try {
    Object.defineProperty(window, 'Game_BattlerBase', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawGameBattlerBase;
      },
      set: function (val) {
        rawGameBattlerBase = val;
        patchGameBattlerBase(val);
      }
    });
  } catch (e) {}

  var rawGameActor = window.Game_Actor;
  if (rawGameActor) patchGameActor(rawGameActor);
  try {
    Object.defineProperty(window, 'Game_Actor', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawGameActor;
      },
      set: function (val) {
        rawGameActor = val;
        patchGameActor(val);
      }
    });
  } catch (e) {}

  var rawSceneBoot = window.Scene_Boot;
  if (rawSceneBoot) patchSceneBoot(rawSceneBoot);
  try {
    Object.defineProperty(window, 'Scene_Boot', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawSceneBoot;
      },
      set: function (val) {
        rawSceneBoot = val;
        patchSceneBoot(val);
      }
    });
  } catch (e) {}

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
      if (!errorObj && message && !/^[a-zA-Z_$][a-zA-Z0-9_$]*Error:/.test(message)) {
        message = 'Error: ' + message;
      }
      var source = (event && event.filename) ? event.filename : '';
      var line = (event && event.lineno) ? event.lineno : 0;
      var column = (event && event.colno) ? event.colno : 0;
      report('script', message, source, line, { column: column });
    } catch (error) {}
  }, true);

  var origWindowOnError = window.onerror;
  function hookWindowOnError() {
    try {
      var currentWindowOnError = window.onerror;
      function wrapWinOnError(fn) {
        var wrapper = function (message, source, lineno, colno, error) {
          try {
            var fullMsg = '';
            if (error) {
              fullMsg = formatError(error);
            } else {
              var strMsg = String(message || 'Unknown script error');
              var stackPart = (source ? '\n@' + source + (lineno ? ':' + lineno : '') + (colno ? ':' + colno : '') : '');
              if (/^[a-zA-Z_$][a-zA-Z0-9_$]*Error:/.test(strMsg)) {
                fullMsg = strMsg + stackPart;
              } else {
                fullMsg = 'Error: ' + strMsg + stackPart;
              }
            }
            report('script', fullMsg, source || '', lineno || 0, { column: colno || 0 });
          } catch (e) {}
          if (typeof fn === 'function') {
            try {
              return fn.apply(window, arguments);
            } catch (err) {}
          }
          return false;
        };
        wrapper.__sparkWrapped = true;
        return wrapper;
      }

      if (typeof currentWindowOnError === 'function' && !currentWindowOnError.__sparkWrapped) {
        currentWindowOnError = wrapWinOnError(currentWindowOnError);
      } else if (!currentWindowOnError) {
        currentWindowOnError = wrapWinOnError(origWindowOnError);
      }

      try {
        Object.defineProperty(window, 'onerror', {
          configurable: true,
          enumerable: true,
          get: function () {
            return currentWindowOnError;
          },
          set: function (newFn) {
            currentWindowOnError = wrapWinOnError(newFn);
          }
        });
      } catch (err) {
        window.onerror = currentWindowOnError;
      }
    } catch (e) {}
  }
  hookWindowOnError();

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
        if (!Array.isArray(sm._forageKeys)) {
          sm._forageKeys = sm._forageKeys || [];
        }
        if (typeof sm._forageKeysUpdated !== 'boolean') {
          sm._forageKeysUpdated = true;
        }

        sm.isLocalMode = function () { return false; };
        sm.fileDirectoryPath = function () { return 'save/'; };
        sm.localFileDirectoryPath = function () { return 'save/'; };
        sm.forageKeyPrefix = function () { return 'rmmzsave.'; };

        sm.forageKey = function (saveName) {
          var prefix = 'rmmzsave.';
          try {
            if (this && typeof this.forageKeyPrefix === 'function') {
              prefix = this.forageKeyPrefix();
            } else if (sm && typeof sm.forageKeyPrefix === 'function') {
              prefix = sm.forageKeyPrefix();
            }
          } catch (e) {}
          return prefix + (saveName || '');
        };

        sm.isForageKey = function (key) {
          var prefix = 'rmmzsave.';
          try {
            if (this && typeof this.forageKeyPrefix === 'function') {
              prefix = this.forageKeyPrefix();
            } else if (sm && typeof sm.forageKeyPrefix === 'function') {
              prefix = sm.forageKeyPrefix();
            }
          } catch (e) {}
          return String(key || '').indexOf(prefix) === 0;
        };

        sm.filePath = function (saveName) {
          var k = '';
          try {
            if (this && typeof this.forageKey === 'function') {
              k = this.forageKey(saveName);
            } else {
              k = 'rmmzsave.' + (saveName || '');
            }
          } catch (e) {
            k = 'rmmzsave.' + (saveName || '');
          }
          return 'save/' + k;
        };

        sm.forageKeys = function () {
          var target = (this && Array.isArray(this._forageKeys)) ? this : sm;
          return (target && Array.isArray(target._forageKeys)) ? target._forageKeys : [];
        };

        sm.forageKeysUpdated = function () {
          try {
            var dm = window.DataManager;
            if (dm && typeof dm.isDatabaseLoaded === 'function' && dm.isDatabaseLoaded()) {
              return true;
            }
          } catch (e) {}
          try {
            var target = (this && typeof this._forageKeysUpdated === 'boolean') ? this : sm;
            if (target && typeof target._forageKeysUpdated === 'boolean') {
              return target._forageKeysUpdated;
            }
          } catch (e) {}
          return true;
        };

        sm.updateForageKeys = function () {
          var self = (this && (typeof this === 'object' || typeof this === 'function')) ? this : (sm || window.StorageManager || {});
          if (!Array.isArray(self._forageKeys)) {
            self._forageKeys = (sm && Array.isArray(sm._forageKeys)) ? sm._forageKeys : [];
          }
          self._forageKeysUpdated = false;

          try {
            var lf = window.localforage || (typeof sparkLocalForage !== 'undefined' ? sparkLocalForage : null);
            if (!lf || typeof lf.iterate !== 'function') {
              self._forageKeysUpdated = true;
              return Promise.resolve(self._forageKeys);
            }
            return Promise.resolve(lf.iterate(function (value, key) {
              try {
                var match = false;
                if (self && typeof self.isForageKey === 'function') {
                  match = self.isForageKey(key);
                } else if (sm && typeof sm.isForageKey === 'function') {
                  match = sm.isForageKey(key);
                } else {
                  match = String(key || '').indexOf('rmmzsave.') === 0;
                }
                if (match && self._forageKeys.indexOf(key) === -1) {
                  self._forageKeys.push(key);
                }
              } catch (iterErr) {}
            })).then(function () {
              self._forageKeysUpdated = true;
              return self._forageKeys;
            }).catch(function () {
              self._forageKeysUpdated = true;
              return self._forageKeys;
            });
          } catch (syncErr) {
            self._forageKeysUpdated = true;
            return Promise.resolve(self._forageKeys || []);
          }
        };

        sm.forageExists = function (saveName) {
          var key = 'rmmzsave.' + (saveName || '');
          try {
            if (this && typeof this.forageKey === 'function') {
              key = this.forageKey(saveName);
            }
          } catch (e) {}
          return sparkLocalForage.getItem(key).then(function (data) {
            return data !== null && data !== undefined;
          });
        };
        sm.removeForage = function (saveName) {
          var key = 'rmmzsave.' + (saveName || '');
          try {
            if (this && typeof this.forageKey === 'function') {
              key = this.forageKey(saveName);
            }
          } catch (e) {}
          return sparkLocalForage.removeItem(key);
        };
        sm.saveToForage = function (saveName, zip) {
          var key = 'rmmzsave.' + (saveName || '');
          try {
            if (this && typeof this.forageKey === 'function') {
              key = this.forageKey(saveName);
            }
          } catch (e) {}
          var zipString = typeof zip === 'string' ? zip : (zip !== null && zip !== undefined ? JSON.stringify(zip) : '');
          return sparkLocalForage.setItem(key, zipString);
        };
        sm.saveZip = function (saveName, zip) {
          return this.saveToForage(saveName, zip);
        };
        sm.loadFromForage = function (saveName) {
          var key = 'rmmzsave.' + (saveName || '');
          try {
            if (this && typeof this.forageKey === 'function') {
              key = this.forageKey(saveName);
            }
          } catch (e) {}
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

    var rawStorageManager = window.StorageManager;
    try {
      Object.defineProperty(window, 'StorageManager', {
        configurable: true,
        enumerable: true,
        get: function () {
          return rawStorageManager;
        },
        set: function (val) {
          rawStorageManager = val;
          patchStorageManager(val);
        }
      });
    } catch (e) {}

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
      wrapDataManagerCreateGameObjects(dm);
      wrapDataManagerSetupNewGame(dm);
    } catch (e) {}
  }

  function wrapDataManagerSetupNewGame(dm) {
    if (!dm || typeof dm.setupNewGame !== 'function' || dm.setupNewGame.__sparkWrapped) return;
    var origSetupNewGame = dm.setupNewGame;
    dm.setupNewGame = function () {
      origSetupNewGame.apply(this, arguments);
      // Ensure starting map is reserved if $gamePlayer did not reserve it
      try {
        if (window.$gamePlayer && window.$dataSystem) {
          var mapId = (typeof window.$gamePlayer.newMapId === 'function') ? window.$gamePlayer.newMapId() : 0;
          if (mapId <= 0 && window.$dataSystem.startMapId > 0) {
            window.$gamePlayer.reserveTransfer(
              window.$dataSystem.startMapId,
              window.$dataSystem.startX || 0,
              window.$dataSystem.startY || 0,
              2,
              0
            );
          }
        }
      } catch (e) {}
    };
    dm.setupNewGame.__sparkWrapped = true;
  }

  function wrapDataManagerCreateGameObjects(dm) {
    if (!dm || typeof dm.createGameObjects !== 'function' || dm.createGameObjects.__sparkWrapped) return;
    var orig = dm.createGameObjects;
    var wrapped = function () {
      try {
        return orig.apply(this, arguments);
      } catch (e) {
        var formatted = formatError(e);
        report('engine.error', formatted, '', 0);
        throw e;
      }
    };
    wrapped.__sparkWrapped = true;
    dm.createGameObjects = wrapped;
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
      if (typeof sm.forageKeysUpdated === 'function' && !sm.forageKeysUpdated.__sparkWrapped) {
        var origFKU = sm.forageKeysUpdated;
        var wrappedFKU = function () {
          try {
            var dm = window.DataManager;
            if (dm && typeof dm.isDatabaseLoaded === 'function' && dm.isDatabaseLoaded()) {
              return true;
            }
            return origFKU.apply(this, arguments);
          } catch (e) {
            return true;
          }
        };
        wrappedFKU.__sparkWrapped = true;
        sm.forageKeysUpdated = wrappedFKU;
      }
      if (typeof sm.updateForageKeys === 'function' && !sm.updateForageKeys.__sparkWrapped) {
        var origUFK = sm.updateForageKeys;
        var wrappedUFK = function () {
          try {
            var self = (this && (typeof this === 'object' || typeof this === 'function')) ? this : (sm || window.StorageManager || {});
            if (!self._forageKeys || !Array.isArray(self._forageKeys)) {
              self._forageKeys = (sm && Array.isArray(sm._forageKeys)) ? sm._forageKeys : [];
            }
            var res = origUFK.apply(self, arguments);
            if (res && typeof res.then === 'function') {
              return res.catch(function () {
                return self._forageKeys || [];
              });
            }
            return Promise.resolve(self._forageKeys || []);
          } catch (e) {
            if (this) {
              if (!this._forageKeys) this._forageKeys = [];
              this._forageKeysUpdated = true;
            }
            return Promise.resolve([]);
          }
        };
        wrappedUFK.__sparkWrapped = true;
        sm.updateForageKeys = wrappedUFK;
      }
    }

    var dm = window.DataManager;
    if (dm) {
      if (typeof patchDataManagerInstance === 'function') {
        patchDataManagerInstance(dm);
      }
      wrapDataManagerGlobalInfo(dm);
      wrapDataManagerCreateGameObjects(dm);
      wrapDataManagerSetupNewGame(dm);
    }

    if (window.JsonEx) {
      patchJsonExInstance(window.JsonEx);
    }
    if (window.PluginManager) {
      patchPluginManager(window.PluginManager);
    }
    if (window.Game_System) {
      patchGameSystem(window.Game_System);
    }
    if (window.Game_BattlerBase) {
      patchGameBattlerBase(window.Game_BattlerBase);
    }
    if (window.Game_Actor) {
      patchGameActor(window.Game_Actor);
    }
    if (window.Sprite_ButtonCommonEventsContainer) {
      patchSpriteButtonCommonEventsContainer(window.Sprite_ButtonCommonEventsContainer);
    }
    if (window.Scene_Map) {
      patchSceneMap(window.Scene_Map);
    }
    ensureButtonCommonEventsDefaults();
    if (window.ImageManager && typeof patchImageManager === 'function') {
      patchImageManager(window.ImageManager);
    }
    if (window.ColorManager && typeof patchColorManager === 'function') {
      patchColorManager(window.ColorManager);
    }
    if (window.Scene_Boot) {
      if (typeof patchSceneBoot === 'function') patchSceneBoot(window.Scene_Boot);
      if (typeof hookSceneBootPrototype === 'function') hookSceneBootPrototype(window.Scene_Boot);
    }
    if (window.Graphics && typeof hookGraphicsPrintError === 'function') {
      hookGraphicsPrintError(window.Graphics);
    }
    if (window.SceneManager) {
      if (typeof patchSceneManagerInstance === 'function') patchSceneManagerInstance(window.SceneManager);
      if (typeof hookSceneManagerErrors === 'function') hookSceneManagerErrors(window.SceneManager);
    }
    if (typeof hookWindowOnError === 'function') {
      hookWindowOnError();
    }
  }

  if (typeof window.DataManager !== 'undefined') {
    patchDataManagerInstance(window.DataManager);
  }

  // MARK: - Graphics.printError & SceneManager.onError Overwrite Locks

  function formatGraphicsError(name, message, error) {
    if (error && (error instanceof Error || (typeof error === 'object' && error !== null && (error.name || error.message || error.stack)))) {
      return formatError(error);
    }
    var nameStr = (name ? String(name).trim() : '');
    var msgStr = (message ? String(message).trim() : '');

    if (typeof message === 'object' && message !== null) {
      return formatError(message);
    }

    if (nameStr && msgStr) {
      if (msgStr.indexOf(nameStr) === 0) {
        return formatError(msgStr);
      }
      return formatError(nameStr + ': ' + msgStr);
    }
    if (msgStr) {
      return formatError(msgStr);
    }
    if (nameStr) {
      return formatError(nameStr);
    }
    return 'Error: Unknown graphics error';
  }

  function hookGraphicsPrintError(gfx) {
    if (!gfx || (typeof gfx !== 'object' && typeof gfx !== 'function')) return;
    try {
      function wrapPrintError(fn) {
        var wrapper = function (name, message, error) {
          var formatted = formatGraphicsError(name, message, error);
          report('graphics.error', formatted, '', 0);
          if (typeof fn === 'function') {
            try {
              return fn.apply(this, arguments);
            } catch (e) {}
          }
        };
        wrapper.__sparkWrapped = true;
        return wrapper;
      }

      var current = gfx.printError;
      if (typeof current === 'function' && !current.__sparkWrapped) {
        current = wrapPrintError(current);
      } else if (!current) {
        current = wrapPrintError(null);
      }

      try {
        Object.defineProperty(gfx, 'printError', {
          configurable: true,
          enumerable: true,
          get: function () {
            return current;
          },
          set: function (newFn) {
            current = wrapPrintError(newFn);
          }
        });
      } catch (err) {
        gfx.printError = current;
      }
    } catch (e) {}
  }

  function patchGraphicsInstance(gfx) {
    hookGraphicsPrintError(gfx);
  }

  if (typeof window.Graphics !== 'undefined') {
    hookGraphicsPrintError(window.Graphics);
  }

  function hookSceneManagerErrors(sm) {
    if (!sm || (typeof sm !== 'object' && typeof sm !== 'function')) return;
    try {
      // 1. SceneManager.onError
      function wrapOnError(fn) {
        var wrapper = function (e) {
          var errorObj = (e && e.error) ? e.error : e;
          var formatted = formatError(errorObj);
          var file = (e && (e.filename || e.fileName)) || '';
          var line = (e && (e.lineno || e.lineNumber)) || 0;
          report('engine.error', formatted, file, line);
          if (typeof fn === 'function') {
            try {
              return fn.apply(this, arguments);
            } catch (err) {}
          }
        };
        wrapper.__sparkWrapped = true;
        return wrapper;
      }

      var currentOnError = sm.onError;
      if (typeof currentOnError === 'function' && !currentOnError.__sparkWrapped) {
        currentOnError = wrapOnError(currentOnError);
      } else if (!currentOnError) {
        currentOnError = wrapOnError(null);
      }

      try {
        Object.defineProperty(sm, 'onError', {
          configurable: true,
          enumerable: true,
          get: function () {
            return currentOnError;
          },
          set: function (newFn) {
            currentOnError = wrapOnError(newFn);
          }
        });
      } catch (err) {
        sm.onError = currentOnError;
      }

      // 2. SceneManager.catchException
      function wrapCatchException(fn) {
        var wrapper = function (e) {
          var formatted = formatError(e);
          report('engine.error', formatted, '', 0);
          if (typeof fn === 'function') {
            try {
              return fn.apply(this, arguments);
            } catch (err) {}
          }
        };
        wrapper.__sparkWrapped = true;
        return wrapper;
      }

      var currentCatchException = sm.catchException;
      if (typeof currentCatchException === 'function' && !currentCatchException.__sparkWrapped) {
        currentCatchException = wrapCatchException(currentCatchException);
      }
      try {
        Object.defineProperty(sm, 'catchException', {
          configurable: true,
          enumerable: true,
          get: function () {
            return currentCatchException;
          },
          set: function (newFn) {
            currentCatchException = wrapCatchException(newFn);
          }
        });
      } catch (err) {
        if (currentCatchException) sm.catchException = currentCatchException;
      }

      // 3. SceneManager.catchNormalError
      function wrapCatchNormal(fn) {
        var wrapper = function (e) {
          var formatted = formatError(e);
          report('engine.error', formatted, '', 0);
          if (typeof fn === 'function') {
            try {
              return fn.apply(this, arguments);
            } catch (err) {}
          }
        };
        wrapper.__sparkWrapped = true;
        return wrapper;
      }

      var currentCatchNormal = sm.catchNormalError;
      if (typeof currentCatchNormal === 'function' && !currentCatchNormal.__sparkWrapped) {
        currentCatchNormal = wrapCatchNormal(currentCatchNormal);
      }
      try {
        Object.defineProperty(sm, 'catchNormalError', {
          configurable: true,
          enumerable: true,
          get: function () {
            return currentCatchNormal;
          },
          set: function (newFn) {
            currentCatchNormal = wrapCatchNormal(newFn);
          }
        });
      } catch (err) {
        if (currentCatchNormal) sm.catchNormalError = currentCatchNormal;
      }
    } catch (e) {}
  }

  // SceneManager: run hook, onError, catchNormalError, and catchException reporting
  function patchSceneManagerInstance(sm) {
    if (!sm || (typeof sm !== 'object' && typeof sm !== 'function')) return;
    try {
      if (typeof sm.run === 'function' && !sm.run.__sparkRunHooked) {
        var origRun = sm.run;
        var wrappedRun = function (sceneClass) {
          try {
            reapplyStorageAndDataManagerPatches();
            hookGraphicsPrintError(window.Graphics);
            hookSceneManagerErrors(sm);
            if (typeof hookWindowOnError === 'function') hookWindowOnError();
            if (sceneClass) {
              if (typeof patchSceneBoot === 'function') patchSceneBoot(sceneClass);
              if (typeof hookSceneBootPrototype === 'function') hookSceneBootPrototype(sceneClass);
            }
            if (window.Scene_Boot) {
              if (typeof patchSceneBoot === 'function') patchSceneBoot(window.Scene_Boot);
              if (typeof hookSceneBootPrototype === 'function') hookSceneBootPrototype(window.Scene_Boot);
            }
            syncLoadingSpinner();
          } catch (e) {}
          return origRun.apply(this, arguments);
        };
        wrappedRun.__sparkRunHooked = true;
        sm.run = wrappedRun;
      }

      hookSceneManagerErrors(sm);
    } catch (e) {}
  }

  var rawSceneManager = window.SceneManager;
  if (rawSceneManager) patchSceneManagerInstance(rawSceneManager);
  try {
    Object.defineProperty(window, 'SceneManager', {
      configurable: true,
      enumerable: true,
      get: function () {
        return rawSceneManager;
      },
      set: function (val) {
        rawSceneManager = val;
        patchSceneManagerInstance(val);
      }
    });
  } catch (e) {}

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
      if (typeof hookGraphicsPrintError === 'function') hookGraphicsPrintError(window.Graphics);
      hookGraphicsVideo(window.Graphics);
    }
    if (window.SceneManager) {
      if (typeof patchSceneManagerInstance === 'function') patchSceneManagerInstance(window.SceneManager);
      if (typeof hookSceneManagerErrors === 'function') hookSceneManagerErrors(window.SceneManager);
    }
    if (window.ImageManager && typeof patchImageManager === 'function') patchImageManager(window.ImageManager);
    if (window.ColorManager && typeof patchColorManager === 'function') patchColorManager(window.ColorManager);
    if (window.Scene_Boot) {
      if (typeof patchSceneBoot === 'function') patchSceneBoot(window.Scene_Boot);
      if (typeof hookSceneBootPrototype === 'function') hookSceneBootPrototype(window.Scene_Boot);
    }
    if (window.StorageManager && window.__sparkPatchStorageManager) {
      window.__sparkPatchStorageManager(window.StorageManager);
    }
    if (window.StorageManager || window.DataManager) {
      reapplyStorageAndDataManagerPatches();
      syncLoadingSpinner();
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

  // MARK: - iOS WebAudio Auto-Unlock & DOM Loading Spinner Sync

  function unlockWebAudio() {
    try {
      var wa = window.WebAudio;
      if (wa && wa._context && typeof wa._context.resume === 'function') {
        if (wa._context.state === 'suspended' || wa._context.state === 'interrupted') {
          wa._context.resume();
        }
      }
    } catch (e) {}
  }

  ['touchstart', 'touchend', 'pointerdown', 'mousedown', 'keydown'].forEach(function (eventName) {
    window.addEventListener(eventName, unlockWebAudio, { capture: true, passive: true });
  });

  function syncLoadingSpinner() {
    try {
      var gfx = window.Graphics;
      var dm = window.DataManager;
      var dbReady = dm && typeof dm.isDatabaseLoaded === 'function' && dm.isDatabaseLoaded();
      var giReady = dm && typeof dm.isGlobalInfoLoaded === 'function' && dm.isGlobalInfoLoaded();

      if (dbReady && giReady) {
        if (gfx && typeof gfx._loadingCount === 'number' && gfx._loadingCount <= 0) {
          gfx._loadingCount = 0;
          if (typeof gfx.endLoading === 'function' && gfx._loadingSpinner) {
            gfx.endLoading();
          }
          if (gfx._loadingSpinner && gfx._loadingSpinner.parentNode) {
            gfx._loadingSpinner.parentNode.removeChild(gfx._loadingSpinner);
            gfx._loadingSpinner = null;
          }
        }
        var spinnerEl = document.getElementById('loadingSpinner');
        if (spinnerEl && spinnerEl.parentNode) {
          if (!gfx || typeof gfx._loadingCount !== 'number' || gfx._loadingCount <= 0) {
            spinnerEl.style.display = 'none';
            spinnerEl.parentNode.removeChild(spinnerEl);
          }
        }
      }
    } catch (e) {}
  }

  function checkReadinessWatchdog() {
    var sm = window.SceneManager;
    var gfx = window.Graphics;
    if (!sm && !gfx) return;

    syncLoadingSpinner();

    var scene = (sm && (sm._scene || sm._nextScene)) || null;
    var sceneName = (scene && scene.constructor && scene.constructor.name) || 'Scene_Boot';

    var dm = window.DataManager;
    var dbBool = false;
    var giBool = false;
    var dbLoaded = 'n/a';
    var giLoaded = 'n/a';
    var allDbFilesLoaded = false;

    var expectedDbFiles = [
      '$dataActors', '$dataClasses', '$dataSkills', '$dataItems',
      '$dataWeapons', '$dataArmors', '$dataEnemies', '$dataTroops',
      '$dataStates', '$dataAnimations', '$dataTilesets', '$dataCommonEvents',
      '$dataSystem', '$dataMapInfos'
    ];

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

      allDbFilesLoaded = true;
      if (Array.isArray(dm._databaseFiles) && dm._databaseFiles.length > 0) {
        for (var dfi = 0; dfi < dm._databaseFiles.length; dfi++) {
          var df = dm._databaseFiles[dfi];
          if (df && df.name && !window[df.name]) {
            allDbFilesLoaded = false;
            break;
          }
        }
      } else {
        for (var ei = 0; ei < expectedDbFiles.length; ei++) {
          if (!window[expectedDbFiles[ei]]) {
            allDbFilesLoaded = false;
            break;
          }
        }
      }
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

    var fm = window.FontManager;
    var fmReady = fm && typeof fm.isReady === 'function' ? fm.isReady() : true;
    var im = window.ImageManager;
    var imReady = im && typeof im.isReady === 'function' ? im.isReady() : true;

    // Scene_Boot Force-Advance Guard:
    // If Scene_Boot is active when DB and GlobalInfo are already loaded, along with fonts and images:
    // CRITICAL: Scene_Boot must NOT be force-advanced until EVERY database file in DataManager._databaseFiles is truthy.
    if (sceneName === 'Scene_Boot' && dbBool === true && giBool === true && fmReady && imReady && allDbFilesLoaded) {
      if (scene && !scene._sparkOnDatabaseLoadedDone) {
        if (typeof scene.onDatabaseLoaded === 'function') {
          scene._sparkOnDatabaseLoadedDone = true;
          scene._databaseLoaded = true;
          report('info', 'Watchdog: calling scene.onDatabaseLoaded() for Scene_Boot', '', 0);
          try {
            scene.onDatabaseLoaded();
          } catch (e) {
            report('info', 'Watchdog: scene.onDatabaseLoaded() threw: ' + formatError(e), '', 0);
          }
        }
      }

      if (!window.__sparkBootForceAdvanceTimer) {
        window.__sparkBootForceAdvanceTimer = setTimeout(function () {
          window.__sparkBootForceAdvanceTimer = null;
          var currentDm = window.DataManager;
          if (currentDm && Array.isArray(currentDm._databaseFiles)) {
            for (var i = 0; i < currentDm._databaseFiles.length; i++) {
              var f = currentDm._databaseFiles[i];
              if (f && f.name && !window[f.name]) {
                report('info', 'Watchdog cancelled Scene_Boot force-advance: ' + f.name + ' not loaded', '', 0);
                return;
              }
            }
          }
          var currentSm = window.SceneManager;
          var currentScene = currentSm && (currentSm._scene || currentSm._nextScene);
          var curName = (currentScene && currentScene.constructor && currentScene.constructor.name) || '';
          if (curName === 'Scene_Boot') {
            // NEVER bypass Scene_Boot.prototype.onDatabaseLoaded()!
            if (currentScene && typeof currentScene.onDatabaseLoaded === 'function' && !currentScene._sparkOnDatabaseLoadedDone) {
              currentScene._sparkOnDatabaseLoadedDone = true;
              currentScene._databaseLoaded = true;
              report('info', 'Watchdog ensuring onDatabaseLoaded() runs before advancing Scene_Boot', '', 0);
              try { currentScene.onDatabaseLoaded(); } catch (e) {}
            }
            report('info', 'Watchdog force-advancing Scene_Boot -> Scene_Title', '', 0);
            try {
              if (typeof currentScene.resizeScreen === 'function') {
                try { currentScene.resizeScreen(); } catch (e) {}
              }
              if (typeof currentScene.updateDocumentTitle === 'function') {
                try { currentScene.updateDocumentTitle(); } catch (e) {}
              }
              if (typeof currentScene.start === 'function') {
                currentScene.start();
              }
            } catch (e) {}

            setTimeout(function () {
              var smAfter = window.SceneManager;
              var scAfter = smAfter && (smAfter._scene || smAfter._nextScene);
              var nameAfter = (scAfter && scAfter.constructor && scAfter.constructor.name) || '';
              if (nameAfter === 'Scene_Boot') {
                var targetScene = window.Scene_Title || null;
                if (targetScene && typeof smAfter.goto === 'function') {
                  report('info', 'SceneManager.goto(Scene_Title) force-transition triggered', '', 0);
                  try { smAfter.goto(targetScene); } catch (e) {}
                }
              }
            }, 200);
          }
        }, 1000);
      }
    } else if (!allDbFilesLoaded && window.__sparkBootForceAdvanceTimer) {
      clearTimeout(window.__sparkBootForceAdvanceTimer);
      window.__sparkBootForceAdvanceTimer = null;
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

    var stallThreshold = (sceneName === 'Scene_Boot') ? 6000 : 3500;
    if (now - stallStartTime >= stallThreshold) {
      syncLoadingSpinner();

      if (sceneName === 'Scene_Boot' && scene) {
        var bootReasons = [];
        bootReasons.push('dbLoadedFlag=' + !!scene._databaseLoaded);
        if (dm) {
          try {
            if (typeof dm.isDatabaseLoaded === 'function') {
              bootReasons.push('dm.isDatabaseLoaded=' + dm.isDatabaseLoaded());
            }
          } catch (e) { bootReasons.push('dm.isDatabaseLoaded=err'); }
        }
        if (typeof scene.isPlayerDataLoaded === 'function') {
          try { bootReasons.push('isPlayerDataLoaded=' + scene.isPlayerDataLoaded()); } catch (e) { bootReasons.push('isPlayerDataLoaded=err'); }
        }
        if (typeof scene.isCustomFontLoaded === 'function') {
          try { bootReasons.push('isCustomFontLoaded=' + scene.isCustomFontLoaded()); } catch (e) { bootReasons.push('isCustomFontLoaded=err'); }
        }
        if (fm && typeof fm.isReady === 'function') {
          try { bootReasons.push('FontManager.isReady=' + fm.isReady()); } catch (e) {}
        }
        if (im && typeof im.isReady === 'function') {
          try { bootReasons.push('ImageManager.isReady=' + im.isReady()); } catch (e) {}
        }
        if (typeof scene.isReady === 'function') {
          try { bootReasons.push('Scene_Boot.isReady=' + scene.isReady()); } catch (e) { bootReasons.push('Scene_Boot.isReady=err'); }
        }
        report('info', 'Scene_Boot stall diagnosis (>' + (stallThreshold / 1000).toFixed(1) + 's): ' + bootReasons.join(', '), '', 0);
      }

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

      var imManager = window.ImageManager;
      if (imManager) {
        inspectBitmaps(imManager._cache);
        inspectBitmaps(imManager._system);
      }

      var fmManager = window.FontManager;
      var fmReadyStr = 'n/a';
      var unreadyFonts = [];
      if (fmManager) {
        try {
          if (typeof fmManager.isReady === 'function') {
            fmReadyStr = String(fmManager.isReady());
          }
          if (fmManager._states) {
            for (var fontName in fmManager._states) {
              if (fmManager._states[fontName] !== 'loaded') {
                unreadyFonts.push(fontName + ' (' + fmManager._states[fontName] + ')');
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

      if (sceneName === 'Scene_Map' || (window.Scene_Map && scene instanceof window.Scene_Map)) {
        var mapLoaded = (dm && typeof dm.isMapLoaded === 'function') ? dm.isMapLoaded() : false;
        var mapId = (window.$gameMap && typeof window.$gameMap.mapId === 'function') ? window.$gameMap.mapId() : 0;
        var padMapId = ('000' + mapId).slice(-3);
        var mapUrl = 'data/Map' + padMapId + '.json';
        lines.push('Map State: mapId=' + mapId + ' (' + mapUrl + '), isMapLoaded=' + mapLoaded);
      }

      var fontVideo = 'FontManager.isReady()=' + fmReadyStr;
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

      // Log Scene_Boot.prototype.isReady implementation if real stall occurs
      if (sceneName === 'Scene_Boot' && scene && typeof scene.isReady === 'function') {
        try {
          var isReadySnippet = scene.isReady.toString().slice(0, 220).replace(/\s+/g, ' ');
          lines.push('Scene_Boot.isReady: ' + isReadySnippet);
        } catch (e) {}
      }

      var diagnosticText = 'Stall detected (>' + (stallThreshold / 1000).toFixed(1) + 's):\n' + lines.join('\n');
      reportStall(diagnosticText);
    }
  }

  // Poll continuously every 1.5 seconds
  setInterval(checkReadinessWatchdog, 1500);

  // MARK: - Milestone Listeners (DOM, main.js, Scenes)

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      reapplyStorageAndDataManagerPatches();
      syncLoadingSpinner();
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
      syncLoadingSpinner();
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
