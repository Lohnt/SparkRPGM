/* SparkRPGM — boot diagnostics and desktop guard.
 *
 * Injected before every other shim, at document start. Two jobs:
 *
 *  1. Forward real JavaScript failures to Swift (`sparkError`) so the loading
 *     overlay can show the exact exception or missing script instead of
 *     spinning forever.
 *  2. Force `Utils.isNwjs()` to report false once the engine defines it. The
 *     Node shims (`require`, `process`, `nw`) exist for desktop-only plugins,
 *     but MV/MZ must take their browser code paths for XHR loading, audio and
 *     IndexedDB storage on iOS.
 *
 * Every entry point is defensive: a failure here must never stop a game.
 */
(function () {
  'use strict';

  var cfg = window.__SPARK_CONFIG__ || {};
  var reported = Object.create(null);
  var reportCount = 0;
  var MAX_REPORTS = 24;

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
    try {
      if (window.console && window.console.error) {
        window.console.error('[SparkRPGM] ' + kind + ': ' + message + (source ? ' (' + source + ':' + (line || 0) + ')' : ''));
      }
    } catch (error) {}
  }

  window.__sparkReportError = report;
  window.__sparkBrowserMode = true;

  // MARK: - JavaScript failures

  window.addEventListener('error', function (event) {
    try {
      var target = event && event.target;
      var isElement = target && target !== window && target !== document && target.tagName;

      if (isElement) {
        var tag = String(target.tagName).toLowerCase();
        // Only script and stylesheet failures are fatal to a boot sequence.
        // Audio and image probes are expected while the engine tries formats.
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

  // MARK: - Force browser mode in MV / MZ

  var patchedUtils = false;
  var attempts = 0;

  function patchUtils() {
    var utils = window.Utils;
    if (!utils || (typeof utils !== 'object' && typeof utils !== 'function')) return false;
    if (patchedUtils) return true;
    try {
      utils.isNwjs = function () { return false; };
      utils.__sparkBrowserMode = true;
      patchedUtils = true;
      report('info', 'Forced Utils.isNwjs() to false for iOS browser mode', '', 0, { kind: 'info' });
      return true;
    } catch (error) {
      report('info', 'Could not override Utils.isNwjs: ' + error, '', 0);
      return false;
    }
  }

  if (!patchUtils()) {
    var utilsTimer = setInterval(function () {
      attempts += 1;
      if (patchUtils() || attempts >= 600) {
        clearInterval(utilsTimer);
      }
    }, 40);
  }

  // MARK: - WebAssembly guard

  // RPG Maker MZ links Effekseer through WebAssembly. On a 3 GB iPad a compile
  // can take several seconds, and a module that 404s can leave `Scene_Boot`
  // waiting forever. Report slow and failed compiles so the native banner can
  // explain the delay, while letting the compile itself run to completion.
  (function () {
    var wasm = window.WebAssembly;
    if (!wasm || typeof Promise === 'undefined') return;

    function watch(promise, label) {
      if (!promise || typeof promise.then !== 'function') return promise;
      var timer = setTimeout(function () {
        report('info', 'WebAssembly ' + label + ' is still compiling after 6s', '', 0);
      }, 6000);
      return promise.then(function (value) {
        clearTimeout(timer);
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

  // MARK: - Document-level failures

  window.addEventListener('DOMContentLoaded', function () {
    try {
      if (!document.body) {
        report('document', 'index.html loaded without a body element', '', 0);
      }
    } catch (error) {}
  }, false);
})();
