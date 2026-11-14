/* SparkRPGM — core shim.
 *
 * Runs before every game script. Responsibilities:
 *  - expose window.Spark and the native log/ready bridge
 *  - cap devicePixelRatio on 3 GB iPads (canvas memory guard)
 *  - report WebGL context loss to the native overlay
 *  - prevent iOS double-tap zoom / callout gestures that break RPG Maker
 *  - signal the native loading overlay once the engine is alive
 */
(function () {
  'use strict';

  var cfg = window.__SPARK_CONFIG__ || {};
  var Spark = window.Spark = window.Spark || {};

  Spark.config = cfg;
  Spark.readySent = false;
  Spark.lastError = null;

  function nativeHandlers() {
    return (window.webkit && window.webkit.messageHandlers) || null;
  }

  Spark.post = function (name, payload) {
    var handlers = nativeHandlers();
    if (!handlers || !handlers[name]) return false;
    try {
      handlers[name].postMessage(payload === undefined ? null : payload);
      return true;
    } catch (error) {
      return false;
    }
  };

  Spark.log = function (message) {
    var text = '[SparkRPGM] ' + String(message);
    Spark.post('sparkLog', text);
    if (window.console && window.console.log) {
      try { window.console.log(text); } catch (error) {}
    }
  };

  Spark.ready = function (reason) {
    if (Spark.readySent) return;
    Spark.readySent = true;
    Spark.post('sparkReady', {
      reason: reason || 'engine',
      engine: cfg.engine || 'unknown',
      title: cfg.gameTitle || ''
    });
  };

  // MARK: - Device pixel ratio guard

  try {
    var cap = Number(cfg.maxPixelRatio) || 1.5;
    var actual = Number(window.devicePixelRatio) || 1;
    if (cfg.capPixelRatio && actual > cap) {
      Object.defineProperty(window, 'devicePixelRatio', {
        configurable: true,
        enumerable: true,
        get: function () { return cap; }
      });
      Spark.log('devicePixelRatio capped from ' + actual + ' to ' + cap);
    }
  } catch (error) {
    Spark.log('devicePixelRatio cap unavailable: ' + error);
  }

  // MARK: - WebGL context loss

  function reportContextLoss(canvas) {
    Spark.post('sparkContextLost', {
      engine: cfg.engine || 'unknown',
      width: canvas ? canvas.width : 0,
      height: canvas ? canvas.height : 0,
      memory: cfg.physicalMemory || 0
    });
    Spark.log('WebGL context lost');
  }

  function hookCanvas(canvas) {
    if (!canvas || canvas.__sparkHooked) return;
    canvas.__sparkHooked = true;
    canvas.addEventListener('webglcontextlost', function (event) {
      try { event.preventDefault(); } catch (error) {}
      reportContextLoss(canvas);
    }, false);
    canvas.addEventListener('webglcontextrestored', function () {
      Spark.log('WebGL context restored');
    }, false);
  }

  function scanForCanvases() {
    var canvases = document.getElementsByTagName('canvas');
    for (var i = 0; i < canvases.length; i++) hookCanvas(canvases[i]);
  }

  scanForCanvases();

  try {
    if (window.MutationObserver) {
      var observer = new MutationObserver(function (records) {
        for (var i = 0; i < records.length; i++) {
          var added = records[i].addedNodes || [];
          for (var j = 0; j < added.length; j++) {
            var node = added[j];
            if (!node || node.nodeType !== 1) continue;
            if (String(node.tagName).toLowerCase() === 'canvas') hookCanvas(node);
            if (node.getElementsByTagName) {
              var nested = node.getElementsByTagName('canvas');
              for (var k = 0; k < nested.length; k++) hookCanvas(nested[k]);
            }
          }
        }
      });
      observer.observe(document.documentElement || document, { childList: true, subtree: true });
    }
  } catch (error) {
    Spark.log('MutationObserver unavailable: ' + error);
  }

  // MARK: - iOS gesture / zoom suppression

  try {
    document.addEventListener('gesturestart', function (event) {
      event.preventDefault();
    }, { passive: false });

    document.addEventListener('gesturechange', function (event) {
      event.preventDefault();
    }, { passive: false });

    document.addEventListener('dblclick', function (event) {
      event.preventDefault();
    }, { passive: false });

    document.addEventListener('contextmenu', function (event) {
      event.preventDefault();
    }, { passive: false });
  } catch (error) {
    Spark.log('gesture suppression failed: ' + error);
  }

  // MARK: - Error reporting

  window.addEventListener('error', function (event) {
    var message = event && event.message ? event.message : 'Unknown script error';
    var source = event && event.filename ? event.filename : '';
    var line = event && event.lineno ? event.lineno : 0;
    Spark.lastError = message + (source ? ' (' + source + ':' + line + ')' : '');
    Spark.log('error: ' + Spark.lastError);
  }, false);

  window.addEventListener('unhandledrejection', function (event) {
    var reason = event && event.reason;
    Spark.log('unhandled rejection: ' + (reason && reason.stack ? reason.stack : reason));
  }, false);

  // MARK: - Ready detection

  var attempts = 0;
  var engineTimer = setInterval(function () {
    attempts += 1;

    var engineReady = !!(window.SceneManager || window.Graphics || window.Game_Interpreter || window.Game_Player);

    if (engineReady) {
      clearInterval(engineTimer);
      setTimeout(function () { Spark.ready('engine'); }, 240);
      return;
    }

    if (attempts >= 80) {
      clearInterval(engineTimer);
      Spark.ready('timeout');
    }
  }, 250);

  window.addEventListener('load', function () {
    setTimeout(function () {
      if (window.SceneManager || window.Graphics) Spark.ready('load');
    }, 400);
  }, false);

  // Public helper used by the EasyRPG host page and by future runtimes.
  window.__sparkReady = function (reason) {
    Spark.ready(reason || 'manual');
  };

  Spark.log('core shim ready (' + (cfg.engine || 'unknown') + ', lowMemory=' + !!cfg.lowMemory + ')');
})();
