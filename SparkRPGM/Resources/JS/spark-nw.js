/* SparkRPGM — nw.js / Node compatibility shim.
 *
 * RPG Maker MV/MZ games on desktop occasionally pull in nw.js plugins that
 * call require('fs'), require('path') or nw.gui. iOS has no Node, so this layer
 * implements the small synchronous surface those plugins touch, backed by:
 *   - __SPARK_CONFIG__.fsFiles (small text/config files preloaded by Swift)
 *   - fsBridge (async reads/writes into Documents/.spark/nwfs/<game>)
 *
 * Everything is defensive: an unsupported module returns a tolerant stub so a
 * single desktop-only plugin can never stop a game from booting.
 */
(function () {
  'use strict';

  var cfg = window.__SPARK_CONFIG__ || {};
  var Spark = window.Spark = window.Spark || {};
  var log = Spark.log || function (text) { try { console.log(text); } catch (e) {} };

  // MARK: - Bridge plumbing

  var nextRequestID = 1;
  var pendingRequests = {};
  var hasBridge = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fsBridge);

  function requestFS(action, path, extra, callback) {
    var id = nextRequestID++;
    if (callback) {
      pendingRequests[id] = callback;
      setTimeout(function () {
        var pending = pendingRequests[id];
        if (!pending) return;
        delete pendingRequests[id];
        pending({ ok: false, error: 'timeout' });
      }, 8000);
    }

    if (!hasBridge) {
      if (callback) {
        delete pendingRequests[id];
        setTimeout(function () { callback({ ok: false, error: 'no bridge' }); }, 0);
      }
      return id;
    }

    var message = { id: id, action: action, path: path };
    if (extra) {
      for (var key in extra) {
        if (Object.prototype.hasOwnProperty.call(extra, key)) message[key] = extra[key];
      }
    }

    try {
      window.webkit.messageHandlers.fsBridge.postMessage(message);
    } catch (error) {
      if (callback) {
        delete pendingRequests[id];
        setTimeout(function () { callback({ ok: false, error: String(error) }); }, 0);
      }
    }
    return id;
  }

  window.__sparkNativeCallback = function (kind, id, payload) {
    if (kind !== 'fs') return;
    var callback = pendingRequests[id];
    if (!callback) return;
    delete pendingRequests[id];
    try {
      callback(payload || { ok: false, error: 'empty response' });
    } catch (error) {
      log('fs callback failed: ' + error);
    }
  };

  // MARK: - Virtual path helpers

  function toRelativePath(input) {
    if (input === undefined || input === null) return '';
    var value = String(input).replace(/\\/g, '/');
    var cwd = String(cfg.virtualCwd || '').replace(/\/+$/, '');

    if (cwd && value.indexOf(cwd + '/') === 0) {
      value = value.slice(cwd.length + 1);
    } else if (cwd && value === cwd) {
      value = '';
    }

    if (/^[A-Za-z]:/.test(value)) value = value.slice(2);
    value = value.replace(/^\/+/, '');

    var parts = value.split('/');
    var output = [];
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i];
      if (!part || part === '.') continue;
      if (part === '..') { output.pop(); continue; }
      output.push(part);
    }
    return output.join('/');
  }

  // MARK: - Text/binary helpers

  function utf8Bytes(text) {
    if (window.TextEncoder) return new TextEncoder().encode(String(text));
    var encoded = unescape(encodeURIComponent(String(text)));
    var bytes = new Uint8Array(encoded.length);
    for (var i = 0; i < encoded.length; i++) bytes[i] = encoded.charCodeAt(i);
    return bytes;
  }

  function utf8String(bytes) {
    if (window.TextDecoder) return new TextDecoder('utf-8').decode(bytes);
    var binary = '';
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    try { return decodeURIComponent(escape(binary)); } catch (error) { return binary; }
  }

  function base64FromBytes(bytes) {
    var chunk = 0x8000;
    var parts = [];
    for (var i = 0; i < bytes.length; i += chunk) {
      parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + chunk)));
    }
    return btoa(parts.join(''));
  }

  function bytesFromBase64(text) {
    var binary = atob(text);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  // MARK: - Buffer

  function SparkBuffer(data, encoding) {
    var bytes;

    if (data instanceof SparkBuffer) {
      bytes = data._bytes;
    } else if (typeof data === 'string') {
      bytes = encoding === 'base64' ? bytesFromBase64(data) : utf8Bytes(data);
    } else if (data instanceof ArrayBuffer) {
      bytes = new Uint8Array(data);
    } else if (data && data.buffer instanceof ArrayBuffer) {
      bytes = new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
    } else if (Array.isArray(data)) {
      bytes = new Uint8Array(data);
    } else if (typeof data === 'number') {
      bytes = new Uint8Array(data);
    } else {
      bytes = new Uint8Array(0);
    }

    this._bytes = bytes;
  }

  SparkBuffer.prototype.toString = function (encoding) {
    var enc = String(encoding || 'utf8').toLowerCase();
    if (enc === 'base64') return base64FromBytes(this._bytes);
    if (enc === 'hex') {
      var hex = '';
      for (var i = 0; i < this._bytes.length; i++) {
        var part = this._bytes[i].toString(16);
        hex += part.length === 1 ? '0' + part : part;
      }
      return hex;
    }
    return utf8String(this._bytes);
  };

  SparkBuffer.prototype.toJSON = function () {
    return { type: 'Buffer', data: Array.prototype.slice.call(this._bytes) };
  };

  SparkBuffer.prototype.slice = function (start, end) {
    return new SparkBuffer(this._bytes.slice(start, end));
  };

  Object.defineProperty(SparkBuffer.prototype, 'length', {
    get: function () { return this._bytes.length; }
  });

  SparkBuffer.from = function (data, encoding) { return new SparkBuffer(data, encoding); };
  SparkBuffer.alloc = function (size) { return new SparkBuffer(new Uint8Array(size)); };
  SparkBuffer.isBuffer = function (value) { return value instanceof SparkBuffer; };
  SparkBuffer.concat = function (list) {
    var total = 0;
    for (var i = 0; i < list.length; i++) total += list[i].length;
    var merged = new Uint8Array(total);
    var offset = 0;
    for (var j = 0; j < list.length; j++) {
      merged.set(list[j]._bytes, offset);
      offset += list[j].length;
    }
    return new SparkBuffer(merged);
  };

  function toText(data, encoding) {
    if (data instanceof SparkBuffer) return data.toString(encoding || 'utf8');
    if (data && data.buffer instanceof ArrayBuffer && !(data instanceof ArrayBuffer)) {
      return utf8String(new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength));
    }
    if (data instanceof ArrayBuffer) return utf8String(new Uint8Array(data));
    return String(data);
  }

  // MARK: - In-memory game file index

  var preloaded = cfg.fsFiles || {};
  var fileCache = {};
  var directorySet = {};
  var lowerIndex = {};

  function indexDirectory(path) {
    if (!path) return;
    var parts = path.split('/');
    for (var i = 1; i <= parts.length; i++) {
      directorySet[parts.slice(0, i).join('/')] = true;
    }
  }

  function rememberFile(path, text) {
    if (!path) return;
    fileCache[path] = text;
    lowerIndex[path.toLowerCase()] = path;
    var slash = path.lastIndexOf('/');
    if (slash > 0) indexDirectory(path.substring(0, slash));
  }

  Object.keys(preloaded).forEach(function (path) {
    rememberFile(toRelativePath(path), preloaded[path]);
  });

  function lookupFile(path) {
    var relative = toRelativePath(path);
    if (Object.prototype.hasOwnProperty.call(fileCache, relative)) {
      return { path: relative, text: fileCache[relative] };
    }
    var actual = lowerIndex[relative.toLowerCase()];
    if (actual && Object.prototype.hasOwnProperty.call(fileCache, actual)) {
      return { path: actual, text: fileCache[actual] };
    }
    return null;
  }

  function fileMissing(path) {
    var error = new Error('ENOENT: no such file or directory, open \'' + path + '\'');
    error.code = 'ENOENT';
    error.errno = -2;
    error.path = path;
    return error;
  }

  function statLike(isDirectory, size) {
    return {
      isFile: function () { return !isDirectory; },
      isDirectory: function () { return isDirectory; },
      isBlockDevice: function () { return false; },
      isCharacterDevice: function () { return false; },
      isSymbolicLink: function () { return false; },
      isFIFO: function () { return false; },
      isSocket: function () { return false; },
      size: size || 0,
      mode: isDirectory ? 16877 : 33188,
      mtime: new Date(),
      atime: new Date(),
      ctime: new Date(),
      birthtime: new Date()
    };
  }

  // MARK: - fs module

  var fs = {};

  fs.constants = {
    F_OK: 0,
    R_OK: 4,
    W_OK: 2,
    X_OK: 1,
    COPYFILE_EXCL: 1,
    O_RDONLY: 0,
    O_WRONLY: 1,
    O_RDWR: 2,
    O_CREAT: 64,
    O_TRUNC: 512,
    O_APPEND: 1024
  };

  fs.existsSync = function (path) {
    var relative = toRelativePath(path);
    if (lookupFile(relative)) return true;
    if (directorySet[relative]) return true;
    if (!relative) return true;
    return false;
  };

  fs.readFileSync = function (path, options) {
    var encoding = typeof options === 'string' ? options : (options && options.encoding);
    var found = lookupFile(path);
    if (!found) throw fileMissing(toRelativePath(path));
    if (encoding) return found.text;
    return new SparkBuffer(found.text);
  };

  fs.readFile = function (path, options, callback) {
    if (typeof options === 'function') { callback = options; options = undefined; }
    var encoding = typeof options === 'string' ? options : (options && options.encoding);
    var found = lookupFile(path);
    if (found) {
      setTimeout(function () {
        callback(null, encoding ? found.text : new SparkBuffer(found.text));
      }, 0);
      return;
    }

    requestFS('read', toRelativePath(path), null, function (response) {
      if (!response || !response.ok) {
        callback(fileMissing(toRelativePath(path)));
        return;
      }
      var text = typeof response.data === 'string' ? response.data : '';
      rememberFile(toRelativePath(path), text);
      callback(null, encoding ? text : new SparkBuffer(text));
    });
  };

  fs.writeFileSync = function (path, data, options) {
    var relative = toRelativePath(path);
    var text = toText(data, typeof options === 'string' ? options : (options && options.encoding));
    rememberFile(relative, text);
    requestFS('write', relative, { data: text }, null);
  };

  fs.writeFile = function (path, data, options, callback) {
    if (typeof options === 'function') { callback = options; options = undefined; }
    var relative = toRelativePath(path);
    var text = toText(data, typeof options === 'string' ? options : (options && options.encoding));
    rememberFile(relative, text);
    requestFS('write', relative, { data: text }, function (response) {
      if (callback) callback(!response || response.ok ? null : new Error(response.error || 'write failed'));
    });
  };

  fs.appendFileSync = function (path, data, options) {
    var relative = toRelativePath(path);
    var existing = lookupFile(relative);
    var text = (existing ? existing.text : '') + toText(data, typeof options === 'string' ? options : (options && options.encoding));
    rememberFile(relative, text);
    requestFS('append', relative, { data: toText(data) }, null);
  };

  fs.appendFile = function (path, data, options, callback) {
    if (typeof options === 'function') { callback = options; options = undefined; }
    var relative = toRelativePath(path);
    var existing = lookupFile(relative);
    var addition = toText(data, typeof options === 'string' ? options : (options && options.encoding));
    rememberFile(relative, (existing ? existing.text : '') + addition);
    requestFS('append', relative, { data: addition }, function (response) {
      if (callback) callback(!response || response.ok ? null : new Error(response.error || 'append failed'));
    });
  };

  fs.exists = function (path, callback) {
    setTimeout(function () { callback(fs.existsSync(path)); }, 0);
  };

  fs.statSync = function (path) {
    var relative = toRelativePath(path);
    var found = lookupFile(relative);
    if (found) return statLike(false, found.text ? found.text.length : 0);
    if (directorySet[relative] || !relative) return statLike(true, 0);
    throw fileMissing(relative);
  };

  fs.stat = function (path, callback) {
    try {
      callback(null, fs.statSync(path));
    } catch (error) {
      callback(error);
    }
  };

  fs.lstatSync = fs.statSync;
  fs.lstat = fs.stat;
  fs.fstatSync = function () { return statLike(false, 0); };

  fs.readdirSync = function (path) {
    var relative = toRelativePath(path);
    var prefix = relative ? relative + '/' : '';
    var names = {};
    var add = function (value) {
      if (!value || value.indexOf(prefix) !== 0) return;
      var rest = value.slice(prefix.length);
      var head = rest.split('/')[0];
      if (head) names[head] = true;
    };

    Object.keys(fileCache).forEach(add);
    Object.keys(directorySet).forEach(add);

    if (!Object.keys(names).length && relative && !directorySet[relative]) {
      throw fileMissing(relative);
    }

    return Object.keys(names).sort();
  };

  fs.readdir = function (path, options, callback) {
    if (typeof options === 'function') { callback = options; options = undefined; }
    try {
      callback(null, fs.readdirSync(path));
    } catch (error) {
      callback(error);
    }
  };

  fs.mkdirSync = function (path, options) {
    var relative = toRelativePath(path);
    indexDirectory(relative);
    requestFS('mkdir', relative, null, null);
  };

  fs.mkdir = function (path, options, callback) {
    if (typeof options === 'function') { callback = options; options = undefined; }
    var relative = toRelativePath(path);
    indexDirectory(relative);
    requestFS('mkdir', relative, null, function (response) {
      if (callback) callback(!response || response.ok ? null : new Error(response.error || 'mkdir failed'));
    });
  };

  fs.rmdirSync = function (path) {
    var relative = toRelativePath(path);
    delete directorySet[relative];
    requestFS('unlink', relative, null, null);
  };

  fs.rmdir = function (path, options, callback) {
    if (typeof options === 'function') { callback = options; options = undefined; }
    fs.rmdirSync(path);
    if (callback) callback(null);
  };

  fs.unlinkSync = function (path) {
    var relative = toRelativePath(path);
    var actual = lookupFile(relative);
    var key = actual ? actual.path : relative;
    delete fileCache[key];
    delete lowerIndex[key.toLowerCase()];
    requestFS('unlink', key, null, null);
  };

  fs.unlink = function (path, callback) {
    fs.unlinkSync(path);
    if (callback) callback(null);
  };

  fs.renameSync = function (from, to) {
    var fromRelative = toRelativePath(from);
    var toRelative = toRelativePath(to);
    var found = lookupFile(fromRelative);
    if (found) {
      delete fileCache[found.path];
      delete lowerIndex[found.path.toLowerCase()];
      rememberFile(toRelative, found.text);
    }
    requestFS('rename', fromRelative, { to: toRelative }, null);
  };

  fs.rename = function (from, to, callback) {
    fs.renameSync(from, to);
    if (callback) callback(null);
  };

  fs.copyFileSync = function (from, to) {
    var found = lookupFile(from);
    if (!found) throw fileMissing(toRelativePath(from));
    rememberFile(toRelativePath(to), found.text);
    requestFS('write', toRelativePath(to), { data: found.text }, null);
  };

  fs.copyFile = function (from, to, callback) {
    try {
      fs.copyFileSync(from, to);
      if (callback) callback(null);
    } catch (error) {
      if (callback) callback(error);
    }
  };

  fs.accessSync = function (path) {
    if (!fs.existsSync(path)) throw fileMissing(toRelativePath(path));
  };

  fs.access = function (path, mode, callback) {
    if (typeof mode === 'function') { callback = mode; mode = fs.constants.F_OK; }
    try {
      fs.accessSync(path);
      if (callback) callback(null);
    } catch (error) {
      if (callback) callback(error);
    }
  };

  fs.createReadStream = function () { throw new Error('fs streams are not supported on iOS'); };
  fs.createWriteStream = function () { throw new Error('fs streams are not supported on iOS'); };
  fs.watch = function () { return { close: function () {} }; };
  fs.watchFile = function () {};
  fs.unwatchFile = function () {};
  fs.realpathSync = function (path) { return toRelativePath(path); };

  function wrapPromise(operation) {
    return function () {
      var args = Array.prototype.slice.call(arguments);
      return new Promise(function (resolve, reject) {
        args.push(function (error, result) {
          if (error) reject(error); else resolve(result);
        });
        operation.apply(fs, args);
      });
    };
  }

  fs.promises = {
    readFile: wrapPromise(fs.readFile),
    writeFile: wrapPromise(fs.writeFile),
    appendFile: wrapPromise(fs.appendFile),
    stat: wrapPromise(fs.stat),
    lstat: wrapPromise(fs.stat),
    readdir: wrapPromise(fs.readdir),
    mkdir: wrapPromise(fs.mkdir),
    rmdir: wrapPromise(fs.rmdir),
    unlink: wrapPromise(fs.unlink),
    rename: wrapPromise(fs.rename),
    copyFile: wrapPromise(fs.copyFile),
    access: wrapPromise(fs.access),
    realpath: function (path) { return Promise.resolve(toRelativePath(path)); }
  };

  // MARK: - path module

  function normalisePath(input) {
    var value = String(input === undefined || input === null ? '' : input).replace(/\\/g, '/');
    var absolute = value.charAt(0) === '/';
    var parts = value.split('/');
    var output = [];

    for (var i = 0; i < parts.length; i++) {
      var part = parts[i];
      if (!part || part === '.') continue;
      if (part === '..') {
        if (output.length && output[output.length - 1] !== '..') output.pop();
        else if (!absolute) output.push('..');
        continue;
      }
      output.push(part);
    }

    var result = output.join('/');
    if (absolute) result = '/' + result;
    if (!result) result = absolute ? '/' : '.';
    return result;
  }

  var pathModule = {
    sep: '/',
    delimiter: ':',
    posix: null,
    win32: null,
    normalize: normalisePath,

    join: function () {
      var parts = Array.prototype.slice.call(arguments).filter(function (value) {
        return value !== undefined && value !== null && String(value) !== '';
      });
      return normalisePath(parts.join('/'));
    },

    resolve: function () {
      var resolved = '';
      for (var i = arguments.length - 1; i >= 0; i--) {
        var part = String(arguments[i] || '');
        if (!part) continue;
        resolved = resolved ? part + '/' + resolved : part;
        if (part.charAt(0) === '/') break;
      }
      if (!resolved) resolved = cfg.virtualCwd || '/';
      else if (resolved.charAt(0) !== '/') resolved = (cfg.virtualCwd || '/') + '/' + resolved;
      return normalisePath(resolved);
    },

    dirname: function (input) {
      var value = normalisePath(input);
      if (value === '/' || value === '.') return value;
      var index = value.lastIndexOf('/');
      if (index < 0) return '.';
      if (index === 0) return '/';
      return value.slice(0, index);
    },

    basename: function (input, extension) {
      var value = String(input === undefined ? '' : input).replace(/\\/g, '/');
      var index = value.lastIndexOf('/');
      var name = index >= 0 ? value.slice(index + 1) : value;
      if (extension && name.slice(-extension.length) === extension) {
        name = name.slice(0, name.length - extension.length);
      }
      return name;
    },

    extname: function (input) {
      var name = pathModule.basename(input);
      var index = name.lastIndexOf('.');
      if (index <= 0) return '';
      return name.slice(index);
    },

    relative: function (from, to) {
      var fromParts = normalisePath(pathModule.resolve(from)).split('/').filter(Boolean);
      var toParts = normalisePath(pathModule.resolve(to)).split('/').filter(Boolean);
      var common = 0;
      while (common < fromParts.length && common < toParts.length && fromParts[common] === toParts[common]) common++;
      var up = [];
      for (var i = common; i < fromParts.length; i++) up.push('..');
      var down = toParts.slice(common);
      var value = up.concat(down).join('/');
      return value || '';
    },

    isAbsolute: function (input) {
      return String(input || '').charAt(0) === '/';
    },

    parse: function (input) {
      var full = normalisePath(input);
      var dir = pathModule.dirname(full);
      var base = pathModule.basename(full);
      var ext = pathModule.extname(full);
      return {
        root: full.charAt(0) === '/' ? '/' : '',
        dir: dir === '.' ? '' : dir,
        base: base,
        ext: ext,
        name: ext ? base.slice(0, base.length - ext.length) : base
      };
    },

    format: function (object) {
      var dir = object.dir || object.root || '';
      var base = object.base || ((object.name || '') + (object.ext || ''));
      if (!dir) return base;
      if (dir === object.root) return dir + base;
      return dir + '/' + base;
    }
  };

  pathModule.posix = pathModule;
  pathModule.win32 = pathModule;

  // MARK: - os module

  var totalMemory = Number(cfg.physicalMemory) || 3 * 1024 * 1024 * 1024;
  var osModule = {
    EOL: '\n',
    platform: function () { return 'darwin'; },
    type: function () { return 'iOS'; },
    arch: function () { return 'arm64'; },
    release: function () { return '15.0.0'; },
    hostname: function () { return 'sparkrpgm'; },
    homedir: function () { return '/'; },
    tmpdir: function () { return '/tmp'; },
    cpus: function () { return [{ model: 'Apple', speed: 2400 }]; },
    totalmem: function () { return totalMemory; },
    freemem: function () { return Math.max(0, totalMemory / 2); },
    uptime: function () { return performance && performance.now ? performance.now() / 1000 : 0; },
    networkInterfaces: function () { return {}; },
    userInfo: function () { return { username: 'ipad', homedir: '/', shell: null }; }
  };

  // MARK: - process module

  var processStub = {
    platform: 'darwin',
    arch: 'arm64',
    title: 'SparkRPGM',
    version: 'v12.22.12',
    versions: { node: '12.22.12', v8: '7.8', uv: '1.0.0' },
    env: {
      HOME: '/',
      TMPDIR: '/tmp',
      PATH: '/usr/bin:/bin',
      LANG: 'en_US.UTF-8'
    },
    argv: ['node', 'game'],
    execPath: '/usr/bin/node',
    pid: 1,
    nextTick: function (callback) {
      var args = Array.prototype.slice.call(arguments, 1);
      setTimeout(function () { callback.apply(null, args); }, 0);
    },
    cwd: function () { return cfg.virtualCwd || '/'; },
    chdir: function () {},
    exit: function () {},
    abort: function () {},
    on: function () {},
    once: function () {},
    removeListener: function () {},
    emit: function () {},
    hrtime: function () {
      var ms = performance && performance.now ? performance.now() : Date.now();
      return [Math.floor(ms / 1000), Math.floor((ms % 1000) * 1e6)];
    },
    memoryUsage: function () {
      return { rss: 0, heapTotal: 0, heapUsed: 0, external: 0 };
    }
  };

  processStub.mainModule = {
    filename: (cfg.virtualCwd || '') + '/index.html',
    id: '.',
    exports: {},
    loaded: true
  };
  processStub.binding = function () { return {}; };

  // MARK: - nw.gui

  function createNWWindow() {
    return {
      title: cfg.gameTitle || 'SparkRPGM',
      width: window.innerWidth,
      height: window.innerHeight,
      x: 0,
      y: 0,
      menu: null,
      show: function () {},
      hide: function () {},
      close: function () {},
      focus: function () {},
      minimize: function () {},
      maximize: function () {},
      restore: function () {},
      resizeTo: function () {},
      moveTo: function () {},
      setAlwaysOnTop: function () {},
      enterFullscreen: function () {},
      leaveFullscreen: function () {},
      toggleFullscreen: function () {},
      reload: function () { location.reload(); },
      reloadIgnoringCache: function () { location.reload(); },
      showDevTools: function () {},
      closeDevTools: function () {},
      on: function () {},
      once: function () {},
      removeListener: function () {},
      open: function () {}
    };
  }

  var sharedNWWindow = createNWWindow();

  function MenuItem() {
    return {
      type: 'normal',
      label: '',
      enabled: true,
      checked: false,
      click: null,
      submenu: null
    };
  }

  var nwGui = {
    Window: {
      get: function () { return sharedNWWindow; },
      open: function () { return createNWWindow(); }
    },
    App: {
      argv: ['game'],
      dataPath: cfg.virtualCwd || '/',
      manifest: { name: cfg.gameTitle || 'SparkRPGM', version: '1.0.0' },
      quit: function () {},
      closeAllWindows: function () {},
      clearCache: function () {},
      showDevTools: function () {},
      on: function () {},
      removeListener: function () {}
    },
    Shell: {
      openExternal: function (url) {
        try {
          if (/^https?:/i.test(String(url))) window.location.href = String(url);
        } catch (error) {}
      },
      openItem: function () {}
    },
    Clipboard: {
      get: function () { return ''; },
      set: function () {},
      clear: function () {}
    },
    Menu: function (options) {
      return {
        type: (options && options.type) || 'contextmenu',
        items: [],
        append: function (item) { this.items.push(item); },
        insert: function (item) { this.items.push(item); },
        remove: function () {},
        popup: function () {},
        createMacBuiltin: function () {}
      };
    },
    MenuItem: MenuItem,
    Tray: function () {
      return {
        title: '',
        tooltip: '',
        menu: null,
        show: function () {},
        hide: function () {},
        remove: function () {},
        setTitle: function () {}
      };
    },
    Screen: {
      Init: function () {},
      screens: [{
        bounds: { x: 0, y: 0, width: window.innerWidth, height: window.innerHeight },
        work_area: { x: 0, y: 0, width: window.innerWidth, height: window.innerHeight },
        scaleFactor: Number(window.devicePixelRatio) || 1
      }]
    }
  };

  nwGui.Window.get().menu = new nwGui.Menu({ type: 'menubar' });

  // MARK: - Events / util / crypto stubs

  function EventEmitter() {
    this._listeners = {};
  }
  EventEmitter.prototype.on = function (name, listener) {
    (this._listeners[name] = this._listeners[name] || []).push(listener);
    return this;
  };
  EventEmitter.prototype.addListener = EventEmitter.prototype.on;
  EventEmitter.prototype.once = function (name, listener) {
    var self = this;
    function wrapped() {
      self.removeListener(name, wrapped);
      listener.apply(null, arguments);
    }
    return this.on(name, wrapped);
  };
  EventEmitter.prototype.removeListener = function (name, listener) {
    var list = this._listeners[name] || [];
    var index = list.indexOf(listener);
    if (index >= 0) list.splice(index, 1);
    return this;
  };
  EventEmitter.prototype.removeAllListeners = function (name) {
    if (name) delete this._listeners[name];
    else this._listeners = {};
    return this;
  };
  EventEmitter.prototype.emit = function (name) {
    var list = this._listeners[name] || [];
    var args = Array.prototype.slice.call(arguments, 1);
    list.slice().forEach(function (listener) {
      try { listener.apply(null, args); } catch (error) { log('EventEmitter listener failed: ' + error); }
    });
    return list.length > 0;
  };

  var utilModule = {
    inherits: function (constructor, superConstructor) {
      constructor.super_ = superConstructor;
      constructor.prototype = Object.create(superConstructor.prototype, {
        constructor: { value: constructor, enumerable: false, writable: true, configurable: true }
      });
    },
    inspect: function (value) {
      try { return JSON.stringify(value); } catch (error) { return String(value); }
    },
    format: function () {
      var args = Array.prototype.slice.call(arguments);
      var template = String(args.shift() || '');
      return template.replace(/%[sdj%]/g, function (token) {
        if (token === '%%') return '%';
        if (!args.length) return token;
        var value = args.shift();
        if (token === '%d') return Number(value);
        if (token === '%j') { try { return JSON.stringify(value); } catch (e) { return '[object]'; } }
        return String(value);
      });
    },
    isArray: Array.isArray,
    isDate: function (value) { return value instanceof Date; },
    isRegExp: function (value) { return value instanceof RegExp; },
    isError: function (value) { return value instanceof Error; },
    promisify: function (fn) {
      return function () {
        var args = Array.prototype.slice.call(arguments);
        return new Promise(function (resolve, reject) {
          args.push(function (error, result) { if (error) reject(error); else resolve(result); });
          fn.apply(null, args);
        });
      };
    }
  };

  var cryptoModule = {
    randomBytes: function (size) {
      var bytes = new Uint8Array(size || 16);
      if (window.crypto && window.crypto.getRandomValues) {
        window.crypto.getRandomValues(bytes);
      } else {
        for (var i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
      }
      return new SparkBuffer(bytes);
    },
    randomUUID: function () {
      if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
      var bytes = cryptoModule.randomBytes(16)._bytes;
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      var hex = Array.prototype.map.call(bytes, function (value) {
        return (value < 16 ? '0' : '') + value.toString(16);
      }).join('');
      return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
    },
    createHash: function () {
      var chunks = [];
      return {
        update: function (value) { chunks.push(toText(value)); return this; },
        digest: function () {
          var text = chunks.join('');
          var hash = 0;
          for (var i = 0; i < text.length; i++) {
            hash = ((hash << 5) - hash + text.charCodeAt(i)) | 0;
          }
          var hex = ('0000000' + (hash >>> 0).toString(16)).slice(-8);
          while (hex.length < 40) hex += hex;
          return hex.slice(0, 40);
        }
      };
    }
  };

  var childProcess = {
    exec: function (command, options, callback) {
      if (typeof options === 'function') callback = options;
      if (callback) setTimeout(function () { callback(new Error('child_process is unavailable on iOS'), '', ''); }, 0);
    },
    execSync: function () { throw new Error('child_process is unavailable on iOS'); },
    spawn: function () {
      var emitter = new EventEmitter();
      emitter.stdout = new EventEmitter();
      emitter.stderr = new EventEmitter();
      emitter.stdin = { write: function () {}, end: function () {} };
      emitter.kill = function () {};
      setTimeout(function () { emitter.emit('exit', 127); }, 0);
      return emitter;
    }
  };

  // MARK: - require

  function tolerantModule(name) {
    log('unsupported Node module: ' + name);
    var target = function () {};
    if (typeof Proxy === 'function') {
      return new Proxy(target, {
        get: function (object, property) {
          if (property === 'default') return object;
          if (property === '__esModule') return false;
          if (property === Symbol.toPrimitive) return function () { return ''; };
          return function () { return undefined; };
        },
        apply: function () { return undefined; },
        construct: function () { return {}; }
      });
    }
    return target;
  }

  var moduleCache = {};

  function localRequire(name) {
    var key = String(name || '');
    if (moduleCache[key]) return moduleCache[key];

    var module;
    switch (key) {
      case 'fs':
      case 'fs-extra':
        module = fs;
        break;
      case 'path':
        module = pathModule;
        break;
      case 'os':
        module = osModule;
        break;
      case 'process':
        module = processStub;
        break;
      case 'events':
        module = { EventEmitter: EventEmitter };
        break;
      case 'util':
        module = utilModule;
        break;
      case 'crypto':
        module = cryptoModule;
        break;
      case 'child_process':
        module = childProcess;
        break;
      case 'nw.gui':
        module = nwGui;
        break;
      case 'nw':
        module = { gui: nwGui, Window: nwGui.Window, App: nwGui.App, Shell: nwGui.Shell };
        break;
      default:
        module = tolerantModule(key);
        break;
    }

    moduleCache[key] = module;
    return module;
  }

  // MARK: - Install globals

  // Some webviews expose a read-only `process`/`nw`; a failed assignment must
  // degrade quietly instead of aborting the whole shim.
  try { if (typeof window.require !== 'function') window.require = localRequire; } catch (error) { log('require install failed: ' + error); }
  try { if (!window.process) window.process = processStub; } catch (error) { log('process install failed: ' + error); }
  try { if (!window.global) window.global = window; } catch (error) { log('global install failed: ' + error); }
  try { if (!window.Buffer) window.Buffer = SparkBuffer; } catch (error) { log('Buffer install failed: ' + error); }
  try {
    if (!window.nw) {
      window.nw = { gui: nwGui, Window: nwGui.Window, App: nwGui.App, Shell: nwGui.Shell };
    }
  } catch (error) { log('nw install failed: ' + error); }
  window.__sparkNwShim = true;

  Spark.require = window.require;
  Spark.fs = fs;
  Spark.path = pathModule;
  Spark.buffer = SparkBuffer;
  Spark.writeNativeFile = function (path, text) {
    requestFS('write', toRelativePath(path), { data: String(text) }, null);
  };

  log('nw.js shim ready (virtual cwd: ' + (cfg.virtualCwd || '/') + ')');
})();
