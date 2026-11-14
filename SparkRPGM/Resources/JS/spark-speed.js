/* SparkRPGM — game speed shim (1x / 2x / 3x).
 *
 * The native top pill bar calls
 *     window.__sparkSetSpeed(multiplier)
 * where multiplier is 1, 2 or 3.
 *
 * Two clean paths, never both at once:
 *  - RPG Maker MV / MZ: hook SceneManager.updateScene so the scene's game logic
 *    ticks 2-3 times per rendered frame. Audio, input polling and rendering stay
 *    on their normal cadence, so BGM does not pitch-shift.
 *  - EasyRPG (WebAssembly) and plain HTML5: wrap requestAnimationFrame so the
 *    engine's main loop callback runs 2-3 times per real frame. Re-registrations
 *    made by the extra ticks are dropped, which keeps exactly one loop alive
 *    (no runaway fan-out, no stale timers).
 *
 * Calling __sparkSetSpeed(1) leaves the hooks installed but inert, so the game
 * returns to normal speed without a reload.
 */
(function () {
  'use strict';

  var Spark = window.Spark = window.Spark || {};
  var log = Spark.log || function (text) { try { console.log(text); } catch (e) {} };

  var config = window.__SPARK_CONFIG__ || {};
  var engineName = String(config.engine || '').toLowerCase();
  // MV and MZ must never be sped up by repeating whole frames: they are fixed
  // through SceneManager.updateScene instead.
  var sceneManagerEngine = engineName === 'mv' || engineName === 'mz';
  var animationFrameEngine = engineName === '2000' || engineName === '2003' || engineName === 'web';

  var state = {
    multiplier: 1,
    rafPatched: false,
    retryTimer: 0,
    retries: 0
  };

  function currentMultiplier() {
    var value = Number(state.multiplier) || 1;
    return Math.max(1, Math.min(3, Math.round(value)));
  }

  // MARK: - RPG Maker MV / MZ

  function sceneManagerHooked() {
    var manager = window.SceneManager;
    if (!manager || typeof manager.updateScene !== 'function') return false;
    if (manager.__sparkSpeedHooked) return true;

    var baseUpdateScene = manager.updateScene;
    manager.updateScene = function () {
      var times = currentMultiplier();
      if (times <= 1) {
        return baseUpdateScene.apply(this, arguments);
      }
      for (var i = 0; i < times; i++) {
        baseUpdateScene.apply(this, arguments);
      }
    };
    manager.__sparkSpeedHooked = true;
    log('speed: SceneManager.updateScene hooked');
    return true;
  }

  function sceneManagerDrivesSpeed() {
    return !!(window.SceneManager && window.SceneManager.__sparkSpeedHooked);
  }

  // MARK: - requestAnimationFrame loops

  var capturingRegistration = false;

  function animationFrameHooked() {
    if (state.rafPatched) return true;
    var nativeRAF = window.requestAnimationFrame;
    if (typeof nativeRAF !== 'function') return false;

    window.requestAnimationFrame = function (callback) {
      if (typeof callback !== 'function') {
        return nativeRAF.call(window, callback);
      }
      // Extra ticks inside a multiplied frame must not register the loop again.
      if (capturingRegistration) return 0;

      return nativeRAF.call(window, function (timestamp) {
        var times = currentMultiplier();
        // MV/MZ speed is already handled by the SceneManager hook; running the
        // frame loop several times as well would multiply the game twice.
        if (times <= 1 || sceneManagerDrivesSpeed()) {
          return callback(timestamp);
        }

        for (var i = 0; i < times; i++) {
          capturingRegistration = i > 0;
          try {
            callback(timestamp);
          } catch (error) {
            capturingRegistration = false;
            log('speed: animation frame failed — ' + error);
            break;
          }
        }
        capturingRegistration = false;
      });
    };

    state.rafPatched = true;
    log('speed: requestAnimationFrame hooked');
    return true;
  }

  // MARK: - Late bootstrapping

  function scheduleRetry() {
    if (state.retryTimer || state.retries > 40) return;
    state.retryTimer = window.setTimeout(function () {
      state.retryTimer = 0;
      state.retries += 1;
      if (currentMultiplier() <= 1) return;
      if (sceneManagerHooked()) return;
      // MV/MZ wait for SceneManager; they never fall back to frame repetition.
      if (!sceneManagerEngine && animationFrameHooked()) return;
      scheduleRetry();
    }, 250);
  }

  // MARK: - Public API

  window.__sparkSetSpeed = function (value) {
    var next = Math.max(1, Math.min(3, Math.round(Number(value) || 1)));
    state.multiplier = next;

    if (next > 1) {
      if (sceneManagerEngine || window.SceneManager) {
        if (!sceneManagerHooked()) scheduleRetry();
      } else if (!animationFrameHooked()) {
        scheduleRetry();
      }
    }

    log('speed set to ' + next + 'x');
    return next;
  };

  window.__sparkGetSpeed = function () {
    return currentMultiplier();
  };

  Spark.speed = {
    set: window.__sparkSetSpeed,
    get: window.__sparkGetSpeed
  };

  // EasyRPG (2000/2003) and plain HTML5 boot their own rAF loop, and Emscripten
  // captures `requestAnimationFrame` while the module initialises. Wrapping it
  // now — with the multiplier still at 1, so it is a pass-through — means the
  // loop picks up the shim as soon as the player taps 2x. MV/MZ are left alone
  // and sped up through SceneManager instead.
  if (animationFrameEngine) {
    animationFrameHooked();
  }
})();
