(function (global) {
  var remoteWheelLimits = {
    stepPx: [5, 1000],
    coalesceMs: [0, 200],
    amp: [0, 5],
    durBaseMs: [0, 800],
    releaseDelayMs: [0, 500],
    brakeReversePx: [2, 20]
  };

  var remoteWheelDefaults = {
    enabled: true,
    natural: true,
    brakeEnabled: false,
    stepPx: 48,
    coalesceMs: 60,
    amp: 0.18,
    durBaseMs: 50,
    releaseDelayMs: 120,
    brakeReversePx: 5
  };

  function freezeIfPossible(value) {
    if (typeof Object.freeze === 'function') {
      return Object.freeze(value);
    }
    return value;
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function clampRemoteWheelSetting(key, value) {
    var limits = remoteWheelLimits[key];
    if (!limits) {
      return value;
    }
    return clamp(value, limits[0], limits[1]);
  }

  function parseRemoteWheelBoolean(value, fallback) {
    if (typeof value === 'boolean') {
      return value;
    }
    if (typeof value === 'string') {
      var normalized = value.replace(/^\s+|\s+$/g, '').toLowerCase();
      if (normalized === 'true' || normalized === '1') {
        return true;
      }
      if (normalized === 'false' || normalized === '0') {
        return false;
      }
    }
    if (typeof value === 'number' && isFinite(value)) {
      return value !== 0;
    }
    return fallback;
  }

  function parseRemoteWheelSetting(key, value, fallback) {
    var parsed;
    if (typeof fallback === 'undefined') {
      fallback = remoteWheelDefaults[key];
    }
    if (typeof value === 'number') {
      parsed = value;
    } else {
      parsed = parseFloat(String(value == null ? '' : value));
    }
    if (!isFinite(parsed)) {
      return fallback;
    }
    return clampRemoteWheelSetting(key, parsed);
  }

  function normalizeRemoteWheelSettings(partial) {
    var source = partial || {};
    return {
      enabled: parseRemoteWheelBoolean(source.enabled, remoteWheelDefaults.enabled),
      natural: parseRemoteWheelBoolean(source.natural, remoteWheelDefaults.natural),
      brakeEnabled: parseRemoteWheelBoolean(source.brakeEnabled, remoteWheelDefaults.brakeEnabled),
      stepPx: parseRemoteWheelSetting('stepPx', source.stepPx),
      coalesceMs: Math.round(parseRemoteWheelSetting('coalesceMs', source.coalesceMs)),
      amp: parseRemoteWheelSetting('amp', source.amp),
      durBaseMs: Math.round(parseRemoteWheelSetting('durBaseMs', source.durBaseMs)),
      releaseDelayMs: Math.round(parseRemoteWheelSetting('releaseDelayMs', source.releaseDelayMs)),
      brakeReversePx: Math.round(parseRemoteWheelSetting('brakeReversePx', source.brakeReversePx))
    };
  }

  function normalizeWheelDeltaY(deltaY, deltaMode, pageHeightPx, lineHeightPx) {
    var height = pageHeightPx;
    var lineHeight = lineHeightPx;
    if (!isFinite(deltaY)) {
      return 0;
    }
    if (!isFinite(lineHeight) || lineHeight <= 0) {
      lineHeight = 16;
    }
    if (!isFinite(height) || height <= 0) {
      height = lineHeight;
    }
    if (deltaMode === 1) {
      return deltaY * lineHeight;
    }
    if (deltaMode === 2) {
      return deltaY * Math.max(height, lineHeight);
    }
    return deltaY;
  }

  function canHandleRemoteWheel(options) {
    return Boolean(
      options &&
      options.enabled &&
      !options.pointerActive &&
      isFinite(options.deltaY) &&
      Math.abs(options.deltaY) > 0.01
    );
  }

  function copyOwnProperties(target, source, excludedKey) {
    var key;
    for (key in source) {
      if (Object.prototype.hasOwnProperty.call(source, key) && key !== excludedKey) {
        target[key] = source[key];
      }
    }
    return target;
  }

  function createRemoteWheelBatcher(send, options) {
    var opts = options || {};
    var requestFrame = opts.requestFrame || function (callback) {
      if (typeof global.requestAnimationFrame === 'function') {
        return global.requestAnimationFrame(callback);
      }
      return global.setTimeout(callback, 16);
    };
    var cancelFrame = opts.cancelFrame || function (id) {
      if (typeof global.cancelAnimationFrame === 'function') {
        global.cancelAnimationFrame(id);
        return;
      }
      global.clearTimeout(id);
    };
    var pending;
    var rafId;

    function emitPending() {
      var current;
      if (!pending) {
        return;
      }
      current = pending;
      pending = void 0;
      send(copyOwnProperties({}, current, 'mergeKey'));
    }

    function flush() {
      if (typeof rafId !== 'undefined') {
        cancelFrame(rafId);
        rafId = void 0;
      }
      emitPending();
    }

    return {
      hasPending: function () {
        return typeof pending !== 'undefined';
      },
      schedule: function (payload) {
        var nextPayload;
        if (!pending) {
          pending = payload;
        } else if ((pending.mergeKey || '') === (payload.mergeKey || '')) {
          nextPayload = copyOwnProperties({}, payload);
          nextPayload.deltaY = pending.deltaY + payload.deltaY;
          pending = nextPayload;
        } else {
          flush();
          pending = payload;
        }

        if (typeof rafId !== 'undefined') {
          return;
        }
        rafId = requestFrame(function () {
          rafId = void 0;
          emitPending();
        });
      },
      flush: flush,
      clear: function () {
        pending = void 0;
        if (typeof rafId !== 'undefined') {
          cancelFrame(rafId);
          rafId = void 0;
        }
      }
    };
  }

  global.XXTRemoteWheel = {
    STORAGE_PREFIX: 'xxt_webrtc_wheel_',
    LIMITS: freezeIfPossible(remoteWheelLimits),
    DEFAULTS: freezeIfPossible(remoteWheelDefaults),
    clampSetting: clampRemoteWheelSetting,
    parseBoolean: parseRemoteWheelBoolean,
    parseSetting: parseRemoteWheelSetting,
    normalizeSettings: normalizeRemoteWheelSettings,
    normalizeWheelDeltaY: normalizeWheelDeltaY,
    canHandle: canHandleRemoteWheel,
    createBatcher: createRemoteWheelBatcher
  };
})(window);
