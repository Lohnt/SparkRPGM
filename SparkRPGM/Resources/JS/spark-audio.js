/* SparkRPGM — audio + ogv.js shim.
 *
 * iPadOS cannot decode Ogg Vorbis / WebM natively. When the game ships only
 * .ogg/.webm assets we fall back to the ogv.js 1.8.9 runtime that the CI copies
 * into Resources/WebRuntime/ogv:
 *   - WebM/OGV <video> elements are rendered by OGVPlayer on an overlay canvas.
 *   - decodeAudioData() failures degrade to a silent AudioBuffer so the game
 *     keeps running (the game's audio manager retries on the next scene).
 *
 * The shim also unlocks Web Audio on the first touch, which iOS requires even
 * when the audio session is already active.
 */
(function () {
  'use strict';

  var cfg = window.__SPARK_CONFIG__ || {};
  var Spark = window.Spark = window.Spark || {};
  var log = Spark.log || function (text) { try { console.log(text); } catch (e) {} };

  var NativeAudioContext = window.AudioContext || window.webkitAudioContext;
  var audioContexts = [];
  var ogvPromise = null;

  function ogvBase() {
    return String(cfg.ogvBase || '').replace(/\/+$/, '');
  }

  function ensureOGV() {
    if (window.OGVPlayer) return Promise.resolve(window.OGVPlayer);
    if (ogvPromise) return ogvPromise;

    ogvPromise = new Promise(function (resolve, reject) {
      var url = ogvBase() + '/ogv.js';
      var script = document.createElement('script');
      script.src = url;
      script.async = true;
      script.onload = function () {
        if (typeof window.OGVPlayer === 'function') {
          log('ogv.js loaded');
          resolve(window.OGVPlayer);
        } else {
          reject(new Error('ogv.js loaded but OGVPlayer is missing'));
        }
      };
      script.onerror = function () {
        reject(new Error('Unable to load ' + url));
      };
      document.head.appendChild(script);
    }).catch(function (error) {
      log('ogv.js unavailable: ' + error);
      throw error;
    });

    return ogvPromise;
  }

  // MARK: - Audio unlock

  function registerContext(context) {
    if (!context) return context;
    for (var i = 0; i < audioContexts.length; i++) {
      if (audioContexts[i] === context) return context;
    }
    audioContexts.push(context);
    try {
      context.addEventListener('statechange', function () {
        if (context.state === 'suspended' && context.__sparkWantRunning) {
          context.resume().catch(function () {});
        }
      });
    } catch (error) {}
    return context;
  }

  function unlockAudio() {
    for (var i = 0; i < audioContexts.length; i++) {
      var context = audioContexts[i];
      context.__sparkWantRunning = true;
      if (context.state === 'suspended' && typeof context.resume === 'function') {
        context.resume().catch(function () {});
      }
    }

    if (!NativeAudioContext) return;

    try {
      if (!unlockAudio.context) {
        unlockAudio.context = registerContext(new NativeAudioContext());
      }
      var ctx = unlockAudio.context;
      ctx.__sparkWantRunning = true;
      if (ctx.state === 'suspended' && ctx.resume) ctx.resume().catch(function () {});
      if (!ctx.__sparkSilentPlayed) {
        var buffer = ctx.createBuffer(1, 1, 22050);
        var source = ctx.createBufferSource();
        source.buffer = buffer;
        source.connect(ctx.destination);
        source.start(0);
        ctx.__sparkSilentPlayed = true;
      }
    } catch (error) {
      log('audio unlock failed: ' + error);
    }
  }

  if (NativeAudioContext && !NativeAudioContext.__sparkWrapped) {
    try {
      function WrappedAudioContext() {
        var context = new (Function.prototype.bind.apply(
          NativeAudioContext,
          [null].concat(Array.prototype.slice.call(arguments))
        ))();
        return registerContext(context);
      }
      WrappedAudioContext.prototype = NativeAudioContext.prototype;
      WrappedAudioContext.__sparkWrapped = true;
      window.AudioContext = WrappedAudioContext;
      if (window.webkitAudioContext) window.webkitAudioContext = WrappedAudioContext;
    } catch (error) {
      log('AudioContext wrapper unavailable: ' + error);
    }
  }

  ['touchstart', 'touchend', 'mousedown', 'keydown', 'pointerdown'].forEach(function (name) {
    document.addEventListener(name, unlockAudio, { capture: true, passive: true });
  });

  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') unlockAudio();
  });

  // MARK: - decodeAudioData fallback

  function silentBuffer(context) {
    try {
      var duration = 0.5;
      var frames = Math.max(1, Math.floor((context.sampleRate || 44100) * duration));
      return context.createBuffer(1, frames, context.sampleRate || 44100);
    } catch (error) {
      return null;
    }
  }

  function tryOGVDecode(context, arrayBuffer) {
    // ogv.js does not expose a stable synchronous "decode to AudioBuffer" API.
    // Its public surface is OGVPlayer (video + audio playback). We therefore
    // return a silent buffer when native decoding fails so a missing Ogg track
    // never breaks a scene transition.
    return Promise.resolve(silentBuffer(context));
  }

  function hookDecodeAudioData(prototype) {
    if (!prototype || !prototype.decodeAudioData) return;
    var original = prototype.decodeAudioData;
    if (original.__sparkHooked) return;

    var replacement = function (data, successCallback, errorCallback) {
      var context = this;
      var copy = null;
      try {
        if (data && typeof data.slice === 'function') copy = data.slice(0);
      } catch (error) {}

      var settled = false;

      function deliver(buffer) {
        if (settled) return;
        settled = true;
        if (successCallback) successCallback(buffer);
      }

      function fail(error) {
        if (settled) return;
        tryOGVDecode(context, copy).then(function (buffer) {
          if (buffer) {
            log('native audio decode failed; using silent fallback (' + error + ')');
            deliver(buffer);
          } else if (errorCallback) {
            settled = true;
            errorCallback(error);
          }
        }).catch(function (fallbackError) {
          if (settled) return;
          settled = true;
          if (errorCallback) errorCallback(fallbackError);
        });
      }

      var result;
      try {
        result = original.call(context, data, deliver, fail);
      } catch (error) {
        fail(error);
        return undefined;
      }

      if (result && typeof result.then === 'function') {
        return result.then(function (buffer) {
          deliver(buffer);
          return buffer;
        }, function (error) {
          return tryOGVDecode(context, copy).then(function (buffer) {
            if (buffer) {
              if (successCallback) successCallback(buffer);
              return buffer;
            }
            throw error;
          });
        });
      }
      return undefined;
    };

    replacement.__sparkHooked = true;
    try {
      prototype.decodeAudioData = replacement;
    } catch (error) {
      log('decodeAudioData hook failed: ' + error);
    }
  }

  if (NativeAudioContext) {
    hookDecodeAudioData(NativeAudioContext.prototype);
  }
  if (window.webkitAudioContext && window.webkitAudioContext !== NativeAudioContext) {
    hookDecodeAudioData(window.webkitAudioContext.prototype);
  }

  // MARK: - WebM / OGV video overlay

  function overlayFor(video) {
    var canvas = document.createElement('canvas');
    canvas.setAttribute('data-spark-ogv', '1');
    canvas.style.position = 'fixed';
    canvas.style.left = '0';
    canvas.style.top = '0';
    canvas.style.width = '100vw';
    canvas.style.height = '100vh';
    canvas.style.background = '#000';
    canvas.style.zIndex = '2147483000';
    canvas.style.objectFit = 'contain';
    document.body.appendChild(canvas);
    return canvas;
  }

  function playWithOGV(video, source) {
    return ensureOGV().then(function (OGVPlayer) {
      return new Promise(function (resolve, reject) {
        var canvas = overlayFor(video);
        var player = null;

        try {
          try {
            player = new OGVPlayer({ canvas: canvas, autoplay: false });
          } catch (error) {
            player = new OGVPlayer();
          }
        } catch (error) {
          canvas.remove();
          reject(error);
          return;
        }

        if (!player) {
          canvas.remove();
          reject(new Error('OGVPlayer could not be created'));
          return;
        }

        try {
          player.canvas = canvas;
          if ('audioContext' in player && audioContexts.length) player.audioContext = audioContexts[0];
        } catch (error) {}

        video.__sparkOGVPlayer = player;

        function cleanup() {
          try { player.pause(); } catch (error) {}
          try { player.destroy(); } catch (error) {}
          try { canvas.remove(); } catch (error) {}
          try { video.style.visibility = ''; } catch (error) {}
          video.__sparkOGVPlayer = null;
        }

        function forward(name) {
          try {
            video.dispatchEvent(new Event(name));
          } catch (error) {}
        }

        try {
          player.addEventListener('loadeddata', function () { forward('loadeddata'); });
          player.addEventListener('playing', function () { forward('playing'); });
          player.addEventListener('timeupdate', function () { forward('timeupdate'); });
          player.addEventListener('ended', function () {
            cleanup();
            forward('ended');
          });
          player.addEventListener('error', function (event) {
            log('ogv playback error: ' + (event && event.message ? event.message : 'unknown'));
            cleanup();
            forward('error');
          });
        } catch (error) {}

        try {
          video.style.visibility = 'hidden';
        } catch (error) {}

        video.__sparkOGVCleanup = cleanup;

        try {
          player.src = new URL(source, location.href).href;
          player.play();
          resolve();
        } catch (error) {
          cleanup();
          reject(error);
        }
      });
    });
  }

  var mediaPrototype = window.HTMLMediaElement && HTMLMediaElement.prototype;
  if (mediaPrototype && !mediaPrototype.__sparkVideoHooked) {
    try {
      mediaPrototype.__sparkVideoHooked = true;

      var originalPlay = mediaPrototype.play;
      mediaPrototype.play = function () {
        var media = this;
        var source = media.currentSrc || media.src || '';
        var isVideo = media.tagName && String(media.tagName).toUpperCase() === 'VIDEO';
        var needsOGV = /\.(webm|ogv)([?#]|$)/i.test(source);
        var canPlay = media.canPlayType && (
          media.canPlayType('video/webm') || media.canPlayType('video/ogg') || media.canPlayType('video/ogv')
        );

        if (isVideo && needsOGV && !canPlay) {
          return playWithOGV(media, source).catch(function (error) {
            log('ogv video fallback failed: ' + error);
            return originalPlay.call(media);
          });
        }
        return originalPlay.apply(media, arguments);
      };

      var originalPause = mediaPrototype.pause;
      mediaPrototype.pause = function () {
        if (this.__sparkOGVPlayer) {
          try { this.__sparkOGVPlayer.pause(); } catch (error) {}
        }
        return originalPause.apply(this, arguments);
      };

      var originalLoad = mediaPrototype.load;
      mediaPrototype.load = function () {
        if (this.__sparkOGVCleanup) {
          try { this.__sparkOGVCleanup(); } catch (error) {}
          this.__sparkOGVCleanup = null;
        }
        return originalLoad.apply(this, arguments);
      };
    } catch (error) {
      log('HTMLMediaElement hook failed: ' + error);
    }
  }

  // MARK: - Public API

  Spark.audio = {
    unlock: unlockAudio,
    context: function () {
      if (audioContexts.length) return audioContexts[0];
      unlockAudio();
      return unlockAudio.context || null;
    },
    ensureOGV: ensureOGV
  };

  Spark.log('audio shim ready (ogv base: ' + (ogvBase() || 'missing') + ')');
})();
