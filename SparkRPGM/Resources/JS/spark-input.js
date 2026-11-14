/* SparkRPGM — synthetic keyboard bridge.
 *
 * The native SwiftUI touch controls call
 *     window.__sparkKey(type, key, keyCode, rpgmButton)
 * for every press and release. RPG Maker ignores the modern KeyboardEvent
 * key/code fields and reads the legacy keyCode/which values, so both are forced
 * on the event before it is dispatched.
 *
 * The document-level dispatch bubbles up to window, which covers MV, MZ and
 * Emscripten (EasyRPG) listeners without delivering duplicate keystrokes.
 */
(function () {
  'use strict';

  var cfg = window.__SPARK_CONFIG__ || {};
  var Spark = window.Spark = window.Spark || {};
  var log = Spark.log || function (text) { try { console.log(text); } catch (e) {} };

  var keyTable = {
    8: { key: 'Backspace', code: 'Backspace' },
    9: { key: 'Tab', code: 'Tab' },
    13: { key: 'Enter', code: 'Enter' },
    16: { key: 'Shift', code: 'ShiftLeft' },
    17: { key: 'Control', code: 'ControlLeft' },
    18: { key: 'Alt', code: 'AltLeft' },
    27: { key: 'Escape', code: 'Escape' },
    32: { key: ' ', code: 'Space' },
    33: { key: 'PageUp', code: 'PageUp' },
    34: { key: 'PageDown', code: 'PageDown' },
    35: { key: 'End', code: 'End' },
    36: { key: 'Home', code: 'Home' },
    37: { key: 'ArrowLeft', code: 'ArrowLeft' },
    38: { key: 'ArrowUp', code: 'ArrowUp' },
    39: { key: 'ArrowRight', code: 'ArrowRight' },
    40: { key: 'ArrowDown', code: 'ArrowDown' },
    45: { key: 'Insert', code: 'Insert' },
    46: { key: 'Delete', code: 'Delete' },
    88: { key: 'x', code: 'KeyX' },
    90: { key: 'z', code: 'KeyZ' },
    113: { key: 'F2', code: 'F2' },
    114: { key: 'F3', code: 'F3' },
    115: { key: 'F4', code: 'F4' },
    116: { key: 'F5', code: 'F5' },
    117: { key: 'F6', code: 'F6' },
    118: { key: 'F7', code: 'F7' },
    119: { key: 'F8', code: 'F8' },
    120: { key: 'F9', code: 'F9' },
    121: { key: 'F10', code: 'F10' },
    122: { key: 'F11', code: 'F11' },
    123: { key: 'F12', code: 'F12' }
  };

  function keyInfo(keyName, keyCode) {
    var info = keyTable[keyCode];
    var name = String(keyName || '');
    var key = info ? info.key : (name || String.fromCharCode(keyCode || 0));
    var code = info ? info.code : '';

    if (!code) {
      if (/^[a-zA-Z]$/.test(key)) {
        code = 'Key' + key.toUpperCase();
      } else if (/^[0-9]$/.test(key)) {
        code = 'Digit' + key;
      } else if (key === 'Shift') {
        code = 'ShiftLeft';
      } else if (key === 'Control') {
        code = 'ControlLeft';
      } else {
        code = key || 'Unidentified';
      }
    }

    return { key: key, code: code };
  }

  function forceProperty(event, name, value) {
    try {
      Object.defineProperty(event, name, {
        configurable: true,
        enumerable: true,
        get: function () { return value; }
      });
    } catch (error) {
      try { event[name] = value; } catch (ignored) {}
    }
  }

  function setInputState(type, button) {
    var input = window.Input;
    if (!input) return;

    var pressed = type === 'keydown';
    if (!button) return;

    try {
      if (input._currentState && Object.prototype.hasOwnProperty.call(input._currentState, button)) {
        input._currentState[button] = pressed;
      }
    } catch (error) {}

    if (pressed) {
      try {
        input._latestButton = button;
        input._pressedTime = 0;
      } catch (error) {}
    } else {
      try {
        if (input._latestButton === button) input._latestButton = null;
      } catch (error) {}
    }
  }

  function dispatchOnce(event, type) {
    var documentSeen = false;

    function markDocument(eventObject) {
      if (eventObject === event) documentSeen = true;
    }

    var target = document;

    try {
      document.addEventListener(type, markDocument, true);
      target.dispatchEvent(event);
      document.removeEventListener(type, markDocument, true);
    } catch (error) {
      log('key dispatch failed: ' + error);
      documentSeen = false;
    }

    if (!documentSeen) {
      try { window.dispatchEvent(event); } catch (error) {}
    }
  }

  window.__sparkKey = function (type, keyName, keyCode, rpgmButton) {
    var eventType = type === 'keyup' ? 'keyup' : (type === 'keypress' ? 'keypress' : 'keydown');
    var numericCode = Number(keyCode) || 0;
    var info = keyInfo(keyName, numericCode);

    var event;
    try {
      event = new KeyboardEvent(eventType, {
        key: info.key,
        code: info.code,
        location: 0,
        repeat: false,
        isComposing: false,
        bubbles: true,
        cancelable: true,
        composed: true,
        view: window
      });
    } catch (error) {
      event = document.createEvent('Event');
      event.initEvent(eventType, true, true);
      event.key = info.key;
      event.code = info.code;
    }

    forceProperty(event, 'keyCode', numericCode);
    forceProperty(event, 'which', numericCode);
    forceProperty(event, 'charCode', eventType === 'keypress' ? numericCode : 0);

    setInputState(eventType, rpgmButton);
    dispatchOnce(event, eventType);

    return true;
  };

  window.__sparkReleaseAll = function () {
    var input = window.Input;
    if (!input || !input._currentState) return;
    Object.keys(input._currentState).forEach(function (name) {
      if (typeof input._currentState[name] === 'boolean') input._currentState[name] = false;
    });
    try { input._latestButton = null; } catch (error) {}
  };

  Spark.input = {
    press: function (keyName, keyCode, button) {
      return window.__sparkKey('keydown', keyName, keyCode, button);
    },
    release: function (keyName, keyCode, button) {
      return window.__sparkKey('keyup', keyName, keyCode, button);
    },
    releaseAll: window.__sparkReleaseAll
  };

  Spark.log('input shim ready (' + (cfg.platform || 'ios') + ')');
})();
