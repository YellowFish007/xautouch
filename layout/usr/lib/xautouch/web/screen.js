$(document).ready(function () {
  var SCREEN_SERVER_PATH = "bin/web-screen.lua";
  var SCREEN_WS_PORT = 46968;
  var SCREEN_WS_PROTOCOL = "RC";
  var HEARTBEAT_INTERVAL_MS = 10000;
  var HEARTBEAT_TIMEOUT_MS = 10000;
  var HARDWARE_KEYBOARD_REQUEST_TIMEOUT_MS = 5000;
  var HARDWARE_MOUSE_REQUEST_TIMEOUT_MS = 5000;
  var HARDWARE_MOUSE_MOVE_LIMIT = 2047;
  var HARDWARE_MOUSE_SCROLL_LIMIT = 127;
  var SNAPSHOT_INTERVAL_MS = 10;
  var TOUCH_MOUSE_GUARD_MS = 800;
  var MOUSE_CONTACT_KEY = "mouse-primary";
  var TOUCH_CONTACT_PREFIX = "touch:";
  var TURN_LEFT_ORIEN_MAP = [1, 3, 0, 2];

  var ws_client = null;
  var scr_scale = 1;
  var current_orien = 0;
  var orig_w = 0;
  var orig_h = 0;
  var snapshot_timer = null;
  var heartbeat_interval = null;
  var heartbeat_timeout = null;
  var spawn_attempted = false;
  var has_connected_once = false;
  var is_unloading = false;
  var reconnect_dialog_visible = false;
  var last_touch_timestamp = 0;
  var hardware_keyboard_connected = false;
  var hardware_keyboard_pending_action = null;
  var hardware_keyboard_request_timer = null;
  var hardware_mouse_connected = false;
  var hardware_mouse_pending_action = null;
  var hardware_mouse_request_timer = null;
  var hardware_mouse_consumed_escape = false;
  var hardware_mouse_consumed_escape_until = 0;
  var hardware_mouse_pressed_buttons = {};
  var hardware_mouse_capture_button = null;
  var hardware_mouse_capture_error_timestamp = 0;
  var hardware_mouse_move_dx = 0;
  var hardware_mouse_move_dy = 0;
  var hardware_mouse_move_frame = null;
  var hardware_mouse_scroll_dx = 0;
  var hardware_mouse_scroll_dy = 0;
  var hardware_mouse_scroll_frame = null;

  var all_canvas = document.getElementById("all_canvas");
  var app_bar = document.getElementsByClassName("mdui-appbar mdui-appbar-fixed")[0];
  var main_drawer = document.getElementById("main-drawer");
  var edge_size = 5;
  var default_screen_title = "实时桌面";
  var screen_title_element = $("#screen-title");
  var screen_toolbar = document.getElementById("screen-toolbar");
  var screen_toolbar_brand = document.getElementById("screen-toolbar-brand");
  var screen_toolbar_more = document.getElementById("screen-toolbar-more");
  var screen_toolbar_overflow_menu = document.getElementById("screen-toolbar-overflow-menu");
  var hardware_keyboard_toggle = document.getElementById("toggle-hardware-keyboard");
  var hardware_keyboard_icon = document.getElementById("hardware-keyboard-icon");
  var hardware_mouse_toggle = document.getElementById("toggle-hardware-mouse");
  var hardware_mouse_icon = document.getElementById("hardware-mouse-icon");
  var wheel_settings_toggle = document.getElementById("open-wheel-settings-dialog");
  var toolbar_collapse_order = [
    "open-wheel-settings-dialog",
    "toggle-hardware-mouse",
    "toggle-hardware-keyboard",
    "rotate_turn_left",
    "open-clipboard-dialog"
  ];
  var toolbar_overflow_items = {
    "toggle-hardware-keyboard": document.getElementById("screen-toolbar-menu-keyboard"),
    "toggle-hardware-mouse": document.getElementById("screen-toolbar-menu-mouse"),
    "open-clipboard-dialog": document.getElementById("screen-toolbar-menu-clipboard"),
    "open-wheel-settings-dialog": document.getElementById("screen-toolbar-menu-wheel"),
    "rotate_turn_left": document.getElementById("screen-toolbar-menu-rotate")
  };
  var toolbar_overflow_menu_instance = screen_toolbar_more && screen_toolbar_overflow_menu
    ? new mdui.Menu(screen_toolbar_more, screen_toolbar_overflow_menu, {
      position: "bottom",
      align: "auto",
      covered: false,
      fixed: true
    })
    : null;

  var remote_wheel = window.XXTRemoteWheel || {};
  var remote_touch_allocator = window.XXTRemoteTouchAllocator || {};
  var remote_wheel_defaults = remote_wheel.DEFAULTS || {
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
  var remote_wheel_storage_prefix = remote_wheel.STORAGE_PREFIX || "xxt_webrtc_wheel_";
  var parse_wheel_boolean = remote_wheel.parseBoolean || function (value, fallback) {
    if (typeof value === "boolean") {
      return value;
    }
    if (typeof value === "string") {
      var normalized = value.replace(/^\s+|\s+$/g, "").toLowerCase();
      if (normalized === "true" || normalized === "1") {
        return true;
      }
      if (normalized === "false" || normalized === "0") {
        return false;
      }
    }
    if (typeof value === "number" && isFinite(value)) {
      return value !== 0;
    }
    return fallback;
  };
  var parse_wheel_setting = remote_wheel.parseSetting || function (key, value, fallback) {
    var parsed = typeof value === "number" ? value : parseFloat(String(value == null ? "" : value));
    if (!isFinite(parsed)) {
      return fallback;
    }
    return parsed;
  };
  var normalize_wheel_settings = remote_wheel.normalizeSettings || function (partial) {
    var source = partial || {};
    return {
      enabled: parse_wheel_boolean(source.enabled, remote_wheel_defaults.enabled),
      natural: parse_wheel_boolean(source.natural, remote_wheel_defaults.natural),
      brakeEnabled: parse_wheel_boolean(source.brakeEnabled, remote_wheel_defaults.brakeEnabled),
      stepPx: parse_wheel_setting("stepPx", source.stepPx, remote_wheel_defaults.stepPx),
      coalesceMs: Math.round(parse_wheel_setting("coalesceMs", source.coalesceMs, remote_wheel_defaults.coalesceMs)),
      amp: parse_wheel_setting("amp", source.amp, remote_wheel_defaults.amp),
      durBaseMs: Math.round(parse_wheel_setting("durBaseMs", source.durBaseMs, remote_wheel_defaults.durBaseMs)),
      releaseDelayMs: Math.round(parse_wheel_setting("releaseDelayMs", source.releaseDelayMs, remote_wheel_defaults.releaseDelayMs)),
      brakeReversePx: Math.round(parse_wheel_setting("brakeReversePx", source.brakeReversePx, remote_wheel_defaults.brakeReversePx))
    };
  };

  var wheel_checkbox_map = {
    enabled: "wheel-enabled",
    natural: "wheel-natural",
    brakeEnabled: "wheel-brake-enabled"
  };
  var wheel_slider_map = {
    stepPx: "wheel-step",
    coalesceMs: "wheel-coalesce",
    amp: "wheel-amp",
    durBaseMs: "wheel-dur-base",
    releaseDelayMs: "wheel-release-delay",
    brakeReversePx: "wheel-brake-reverse"
  };
  var wheel_value_map = {
    stepPx: "wheel-step-value",
    coalesceMs: "wheel-coalesce-value",
    amp: "wheel-amp-value",
    durBaseMs: "wheel-dur-base-value",
    releaseDelayMs: "wheel-release-delay-value",
    brakeReversePx: "wheel-brake-reverse-value"
  };
  var wheel_value_formatters = {
    stepPx: function (value) {
      return Math.round(value) + "px";
    },
    coalesceMs: function (value) {
      return Math.round(value) + "ms";
    },
    amp: function (value) {
      return Number(value).toFixed(2);
    },
    durBaseMs: function (value) {
      return Math.round(value) + "ms";
    },
    releaseDelayMs: function (value) {
      return Math.round(value) + "ms";
    },
    brakeReversePx: function (value) {
      return Math.round(value) + "px";
    }
  };

  var wheel_settings = loadWheelSettings();
  var wheel_batcher = remote_wheel.createBatcher ? remote_wheel.createBatcher(sendWheelMessage) : {
    schedule: function (payload) {
      sendWheelMessage(payload);
    },
    clear: function () { }
  };
  var active_remote_contacts = createTouchAllocator();

  all_canvas.style.cursor = "crosshair";
  document.oncontextmenu = new Function("event.returnValue=false;");
  document.onselectstart = new Function("event.returnValue=false;");
  window.closeWheelSettingsDialog = closeWheelSettingsDialog;

  setScreenTitle(default_screen_title);
  updateHardwareKeyboardToggle();
  updateHardwareMouseToggle();
  loadDeviceName();
  bindWheelSettingsDialogEvents();
  syncWheelSettingsUI();
  bindInputEvents();
  bindToolbarEvents();
  setTimeout(layoutScreenToolbar, 0);
  refreshSnapshot();
  connectScreenSocket();

  function setScreenTitle(title) {
    var safe_title = typeof title === "string" ? title.replace(/^\s+|\s+$/g, "") : "";
    if (screen_title_element.length) {
      screen_title_element.text(safe_title || default_screen_title);
      layoutScreenToolbar();
    }
  }

  function setToolbarActionCollapsed(action_id, collapsed) {
    var action = document.getElementById(action_id);
    var overflow_item = toolbar_overflow_items[action_id];
    if (!action || !overflow_item) {
      return;
    }
    $(action).toggleClass("screen-toolbar-action-collapsed", collapsed);
    overflow_item.hidden = !collapsed;
    overflow_item.setAttribute("aria-hidden", collapsed ? "false" : "true");
  }

  function isScreenToolbarOverflowing() {
    var toolbar_rect;
    var power_rect;
    var power_button;
    if (!screen_toolbar) {
      return false;
    }
    power_button = document.getElementById("power");
    if (!power_button) {
      return false;
    }
    toolbar_rect = screen_toolbar.getBoundingClientRect();
    power_rect = power_button.getBoundingClientRect();
    return power_rect.right > toolbar_rect.right + 1;
  }

  function layoutScreenToolbar() {
    var index;
    if (!screen_toolbar || !screen_toolbar_more) {
      return;
    }

    if (toolbar_overflow_menu_instance) {
      toolbar_overflow_menu_instance.close();
    }
    if (document.activeElement === screen_toolbar_more) {
      screen_toolbar_more.blur();
    }
    $(screen_toolbar).removeClass("screen-toolbar-title-compact");
    if (screen_toolbar_brand) {
      $(screen_toolbar_brand).removeClass("screen-toolbar-brand-collapsed");
    }
    screen_toolbar_more.hidden = true;
    screen_toolbar_more.setAttribute("aria-hidden", "true");
    for (index = 0; index < toolbar_collapse_order.length; index += 1) {
      setToolbarActionCollapsed(toolbar_collapse_order[index], false);
    }

    if (!isScreenToolbarOverflowing()) {
      return;
    }

    if (screen_toolbar_brand && window.getComputedStyle(screen_toolbar_brand).display !== "none") {
      $(screen_toolbar_brand).addClass("screen-toolbar-brand-collapsed");
      if (!isScreenToolbarOverflowing()) {
        return;
      }
    }

    screen_toolbar_more.hidden = false;
    screen_toolbar_more.setAttribute("aria-hidden", "false");
    for (index = 0; index < toolbar_collapse_order.length; index += 1) {
      setToolbarActionCollapsed(toolbar_collapse_order[index], true);
      if (!isScreenToolbarOverflowing()) {
        return;
      }
    }

    $(screen_toolbar).addClass("screen-toolbar-title-compact");
  }

  function syncToolbarOverflowAction(action_id, label, icon_name, pressed, disabled) {
    var overflow_item = toolbar_overflow_items[action_id];
    var action;
    var icon;
    var label_element;
    var translated_label;
    if (!overflow_item) {
      return;
    }

    action = overflow_item.getElementsByTagName("a")[0];
    icon = overflow_item.getElementsByTagName("i")[0];
    label_element = overflow_item.getElementsByTagName("span")[0];
    translated_label = window.XXTI18n && typeof window.XXTI18n.t === "function"
      ? window.XXTI18n.t(label)
      : label;

    if (action) {
      action.setAttribute("aria-label", translated_label);
      action.setAttribute("aria-disabled", disabled ? "true" : "false");
      action.setAttribute("tabindex", disabled ? "-1" : "0");
      if (typeof pressed === "boolean") {
        action.setAttribute("aria-pressed", pressed ? "true" : "false");
      } else {
        action.removeAttribute("aria-pressed");
      }
    }
    if (icon && icon_name) {
      icon.textContent = icon_name;
    }
    if (icon && typeof pressed === "boolean") {
      $(icon).toggleClass("mdui-text-color-theme-accent", pressed);
    }
    if (label_element) {
      label_element.textContent = translated_label;
    }
    if (disabled) {
      overflow_item.setAttribute("disabled", "");
    } else {
      overflow_item.removeAttribute("disabled");
    }
  }

  function loadDeviceName() {
    $.post("/deviceinfo", "", function (resp) {
      var devname = "";
      if (resp && resp.code === 0 && resp.data && typeof resp.data.devname === "string") {
        devname = resp.data.devname.replace(/^\s+|\s+$/g, "");
      }
      setScreenTitle(devname || default_screen_title);
    }, "json").error(function () {
      setScreenTitle(default_screen_title);
    });
  }

  function createTouchAllocator() {
    if (remote_touch_allocator && typeof remote_touch_allocator.createAllocator === "function") {
      return remote_touch_allocator.createAllocator();
    }
    var contacts = {};
    return {
      size: function () {
        return this.entries().length;
      },
      get: function (contactKey) {
        return contacts[contactKey];
      },
      entries: function () {
        var list = [];
        var key;
        for (key in contacts) {
          if (Object.prototype.hasOwnProperty.call(contacts, key)) {
            list.push([key, contacts[key]]);
          }
        }
        return list;
      },
      acquire: function (contactKey, data) {
        var existing = contacts[contactKey];
        var used = {};
        var key;
        var finger;
        if (existing) {
          return existing;
        }
        for (key in contacts) {
          if (Object.prototype.hasOwnProperty.call(contacts, key)) {
            used[contacts[key].finger] = true;
          }
        }
        for (finger = 28; finger >= 1; finger -= 1) {
          if (!used[finger]) {
            contacts[contactKey] = {
              finger: finger,
              data: data
            };
            return contacts[contactKey];
          }
        }
        return null;
      },
      update: function (contactKey, data) {
        var existing = contacts[contactKey];
        if (!existing) {
          return undefined;
        }
        existing.data = data;
        return existing;
      },
      release: function (contactKey) {
        var existing = contacts[contactKey];
        if (!existing) {
          return undefined;
        }
        delete contacts[contactKey];
        return existing;
      },
      clear: function () {
        var snapshot = this.entries();
        contacts = {};
        return snapshot;
      }
    };
  }

  function normalizeRotateQuarter(value) {
    var normalized = parseInt(value, 10) || 0;
    normalized = normalized % 4;
    if (normalized < 0) {
      normalized += 4;
    }
    return normalized;
  }

  function isRemoteControlReady() {
    return !!(ws_client && ws_client.readyState === WebSocket.OPEN);
  }

  function clearHardwareKeyboardRequest() {
    if (hardware_keyboard_request_timer) {
      clearTimeout(hardware_keyboard_request_timer);
      hardware_keyboard_request_timer = null;
    }
    hardware_keyboard_pending_action = null;
  }

  function updateHardwareKeyboardToggle() {
    var label;
    var icon_name;
    if (!hardware_keyboard_toggle || !hardware_keyboard_icon) {
      return;
    }

    if (hardware_keyboard_pending_action === "connect") {
      label = "正在连接硬件键盘";
      icon_name = "sync";
    } else if (hardware_keyboard_pending_action === "disconnect") {
      label = "正在断开硬件键盘";
      icon_name = "sync";
    } else if (hardware_keyboard_connected) {
      label = "断开硬件键盘";
      icon_name = "keyboard_hide";
    } else {
      label = "连接硬件键盘";
      icon_name = "keyboard";
    }

    hardware_keyboard_icon.textContent = icon_name;
    hardware_keyboard_toggle.setAttribute("aria-label", label);
    hardware_keyboard_toggle.setAttribute("aria-pressed", hardware_keyboard_connected ? "true" : "false");
    hardware_keyboard_toggle.setAttribute("aria-disabled", hardware_keyboard_pending_action ? "true" : "false");
    $(hardware_keyboard_toggle).toggleClass("mdui-text-color-theme-accent", hardware_keyboard_connected);
    syncToolbarOverflowAction(
      "toggle-hardware-keyboard",
      label,
      icon_name,
      hardware_keyboard_connected,
      !!hardware_keyboard_pending_action
    );
  }

  function handleHardwareKeyboardState(payload) {
    var pending_action = hardware_keyboard_pending_action;
    if (pending_action && payload.action !== pending_action) {
      return;
    }
    clearHardwareKeyboardRequest();
    hardware_keyboard_connected = payload.connected === true;
    updateHardwareKeyboardToggle();

    if (payload.ok === false) {
      mdui.snackbar({
        message: XXTI18n.raw(payload.message || XXTI18n.t("硬件键盘操作失败"))
      });
      return;
    }
    if (pending_action && payload.action === pending_action) {
      mdui.snackbar({
        message: hardware_keyboard_connected ? "硬件键盘已连接" : "硬件键盘已断开"
      });
    }
  }

  function clearHardwareMouseRequest() {
    if (hardware_mouse_request_timer) {
      clearTimeout(hardware_mouse_request_timer);
      hardware_mouse_request_timer = null;
    }
    hardware_mouse_pending_action = null;
  }

  function isHardwareMouseModeSelected() {
    return hardware_mouse_connected || hardware_mouse_pending_action !== null;
  }

  function updateHardwareMouseToggle() {
    var label;
    var icon_name;
    var wheel_settings_disabled = isHardwareMouseModeSelected();
    if (hardware_mouse_toggle && hardware_mouse_icon) {
      if (hardware_mouse_pending_action === "connect") {
        label = "正在连接硬件鼠标";
        icon_name = "sync";
      } else if (hardware_mouse_pending_action === "disconnect") {
        label = "正在断开硬件鼠标";
        icon_name = "sync";
      } else if (hardware_mouse_connected) {
        label = "断开硬件鼠标";
        icon_name = "mouse";
      } else {
        label = "连接硬件鼠标";
        icon_name = "mouse";
      }

      hardware_mouse_icon.textContent = icon_name;
      hardware_mouse_toggle.setAttribute("aria-label", label);
      hardware_mouse_toggle.setAttribute("aria-pressed", hardware_mouse_connected ? "true" : "false");
      hardware_mouse_toggle.setAttribute("aria-disabled", hardware_mouse_pending_action ? "true" : "false");
      $(hardware_mouse_toggle).toggleClass("mdui-text-color-theme-accent", hardware_mouse_connected);
      syncToolbarOverflowAction(
        "toggle-hardware-mouse",
        label,
        icon_name,
        hardware_mouse_connected,
        !!hardware_mouse_pending_action
      );
    }
    if (wheel_settings_toggle) {
      wheel_settings_toggle.setAttribute("aria-disabled", wheel_settings_disabled ? "true" : "false");
      syncToolbarOverflowAction(
        "open-wheel-settings-dialog",
        "滚轮设置",
        "unfold_more",
        null,
        wheel_settings_disabled
      );
    }
    all_canvas.style.cursor = hardware_mouse_connected ? "pointer" : "crosshair";
    all_canvas.title = hardware_mouse_connected ? "点击画面开始鼠标操作" : "";
    if (wheel_settings_disabled && window.wheelSettingsDialogOpen) {
      closeWheelSettingsDialog();
    }
    updateWheelSettingsDependentState();
  }

  function handleHardwareMouseState(payload) {
    var pending_action = hardware_mouse_pending_action;
    var action = payload.action;
    var is_control_action = action === "status" || action === "connect" || action === "disconnect";
    if (pending_action && is_control_action && action !== pending_action) {
      return;
    }

    if (is_control_action) {
      clearHardwareMouseRequest();
    }
    hardware_mouse_connected = payload.connected === true;
    if (!hardware_mouse_connected) {
      resetHardwareMouseInput(false, true);
    }
    updateHardwareMouseToggle();

    if (payload.ok === false) {
      mdui.snackbar({
        message: XXTI18n.raw(payload.message || XXTI18n.t("硬件鼠标操作失败"))
      });
      return;
    }
    if (pending_action && action === pending_action) {
      mdui.snackbar({
        message: hardware_mouse_connected ? "硬件鼠标已连接，点击画面开始操作" : "硬件鼠标已断开"
      });
    }
  }

  function isDialogBlockingInput() {
    return !!(window.clipboardDialogOpen || window.wheelSettingsDialogOpen);
  }

  function canHandleRemoteInput() {
    return !isDialogBlockingInput() && isRemoteControlReady();
  }

  function isTargetInsideBlockingDialog(target) {
    return $(target).closest("#clipboard-dialog, #wheel-settings-dialog").length > 0;
  }

  function clampUnit(value) {
    if (value < 0) {
      return 0;
    }
    if (value > 1) {
      return 1;
    }
    return value;
  }

  function isRecentSyntheticMouse(event) {
    if (event && event.sourceCapabilities && event.sourceCapabilities.firesTouchEvents === true) {
      return true;
    }
    return !isHardwareMouseCaptured() && Date.now() - last_touch_timestamp < TOUCH_MOUSE_GUARD_MS;
  }

  function markTouchActivity() {
    last_touch_timestamp = Date.now();
  }

  function loadWheelSettings() {
    var settings = {};
    var bool_keys = ["enabled", "natural", "brakeEnabled"];
    var number_keys = ["stepPx", "coalesceMs", "amp", "durBaseMs", "releaseDelayMs", "brakeReversePx"];
    var index;
    try {
      for (index = 0; index < bool_keys.length; index += 1) {
        settings[bool_keys[index]] = parse_wheel_boolean(localStorage.getItem(remote_wheel_storage_prefix + bool_keys[index]), remote_wheel_defaults[bool_keys[index]]);
      }
      for (index = 0; index < number_keys.length; index += 1) {
        settings[number_keys[index]] = parse_wheel_setting(number_keys[index], localStorage.getItem(remote_wheel_storage_prefix + number_keys[index]), remote_wheel_defaults[number_keys[index]]);
      }
    } catch (error) {
      console.warn("读取滚轮设置失败:", error);
    }
    return normalize_wheel_settings(settings);
  }

  function persistWheelSetting(key, value) {
    try {
      localStorage.setItem(remote_wheel_storage_prefix + key, String(value));
    } catch (error) {
      console.warn("保存滚轮设置失败:", error);
    }
  }

  function getWheelDialogElement(element_id) {
    return document.getElementById(element_id);
  }

  function updateWheelSettingsDependentState() {
    var reverse_slider = getWheelDialogElement("wheel-brake-reverse");
    var controls = document.querySelectorAll("#wheel-settings-dialog input");
    var disabled = isHardwareMouseModeSelected();
    var index;
    for (index = 0; index < controls.length; index += 1) {
      controls[index].disabled = disabled;
    }
    if (reverse_slider) {
      reverse_slider.disabled = disabled || !wheel_settings.brakeEnabled;
    }
  }

  function updateWheelValueDisplay(setting_key) {
    var display = getWheelDialogElement(wheel_value_map[setting_key]);
    var formatter = wheel_value_formatters[setting_key];
    if (display && formatter) {
      display.textContent = formatter(wheel_settings[setting_key]);
    }
  }

  function setWheelSetting(setting_key, value) {
    var next_partial = {};
    next_partial[setting_key] = value;
    wheel_settings = normalize_wheel_settings($.extend({}, wheel_settings, next_partial));
    persistWheelSetting(setting_key, wheel_settings[setting_key]);
    return wheel_settings[setting_key];
  }

  function syncWheelSettingsUI() {
    var checkbox_key;
    var slider_key;
    var checkbox;
    var slider;

    for (checkbox_key in wheel_checkbox_map) {
      if (Object.prototype.hasOwnProperty.call(wheel_checkbox_map, checkbox_key)) {
        checkbox = getWheelDialogElement(wheel_checkbox_map[checkbox_key]);
        if (checkbox) {
          checkbox.checked = !!wheel_settings[checkbox_key];
        }
      }
    }

    for (slider_key in wheel_slider_map) {
      if (Object.prototype.hasOwnProperty.call(wheel_slider_map, slider_key)) {
        slider = getWheelDialogElement(wheel_slider_map[slider_key]);
        if (slider) {
          slider.value = String(wheel_settings[slider_key]);
        }
        updateWheelValueDisplay(slider_key);
      }
    }

    updateWheelSettingsDependentState();
  }

  function openWheelSettingsDialog() {
    if (isHardwareMouseModeSelected()) {
      return;
    }
    if (window.clipboardDialogOpen && typeof closeClipboardDialog === "function") {
      closeClipboardDialog();
    }
    wheel_settings = loadWheelSettings();
    syncWheelSettingsUI();
    getWheelDialogElement("wheel-settings-overlay").style.display = "block";
    getWheelDialogElement("wheel-settings-dialog").style.display = "block";
    window.wheelSettingsDialogOpen = true;
  }

  function closeWheelSettingsDialog() {
    getWheelDialogElement("wheel-settings-overlay").style.display = "none";
    getWheelDialogElement("wheel-settings-dialog").style.display = "none";
    window.wheelSettingsDialogOpen = false;
  }

  function bindWheelSettingsDialogEvents() {
    var open_btn = getWheelDialogElement("open-wheel-settings-dialog");
    var close_btn = getWheelDialogElement("close-wheel-settings-dialog");
    var overlay = getWheelDialogElement("wheel-settings-overlay");
    var dialog = getWheelDialogElement("wheel-settings-dialog");
    var key;

    function bindDialogStopPropagation(event_name) {
      dialog.addEventListener(event_name, function (event) {
        event.stopPropagation();
      });
    }

    if (open_btn) {
      open_btn.addEventListener("click", function (event) {
        event.preventDefault();
        event.stopPropagation();
        openWheelSettingsDialog();
      });
    }
    if (close_btn) {
      close_btn.addEventListener("click", function (event) {
        event.preventDefault();
        event.stopPropagation();
        closeWheelSettingsDialog();
      });
    }
    if (overlay) {
      overlay.addEventListener("click", function (event) {
        if (event.target === overlay) {
          event.preventDefault();
          event.stopPropagation();
          closeWheelSettingsDialog();
        }
      });
    }
    if (dialog) {
      bindDialogStopPropagation("click");
      bindDialogStopPropagation("keydown");
      bindDialogStopPropagation("keyup");
      bindDialogStopPropagation("keypress");
      bindDialogStopPropagation("wheel");
      bindDialogStopPropagation("mousedown");
      bindDialogStopPropagation("mouseup");
      bindDialogStopPropagation("touchstart");
      bindDialogStopPropagation("touchmove");
      bindDialogStopPropagation("touchend");
    }

    for (key in wheel_checkbox_map) {
      if (Object.prototype.hasOwnProperty.call(wheel_checkbox_map, key)) {
        bindWheelCheckbox(wheel_checkbox_map[key], key);
      }
    }
    for (key in wheel_slider_map) {
      if (Object.prototype.hasOwnProperty.call(wheel_slider_map, key)) {
        bindWheelSlider(wheel_slider_map[key], key);
      }
    }
  }

  function bindWheelCheckbox(element_id, setting_key) {
    var checkbox = getWheelDialogElement(element_id);
    if (!checkbox) {
      return;
    }
    checkbox.addEventListener("change", function (event) {
      setWheelSetting(setting_key, !!event.target.checked);
      updateWheelSettingsDependentState();
    });
  }

  function bindWheelSlider(element_id, setting_key) {
    var slider = getWheelDialogElement(element_id);
    if (!slider) {
      return;
    }
    slider.addEventListener("input", function (event) {
      var next_value = parse_wheel_setting(setting_key, event.target.value, remote_wheel_defaults[setting_key]);
      event.target.value = String(setWheelSetting(setting_key, next_value));
      updateWheelValueDisplay(setting_key);
      updateWheelSettingsDependentState();
    });
  }

  function rotateImage90(image, degrees) {
    var canvas = document.createElement("canvas");
    var ctx = canvas.getContext("2d");

    if (degrees === 90 || degrees === 270) {
      canvas.width = image.height;
      canvas.height = image.width;
    } else {
      canvas.width = image.width;
      canvas.height = image.height;
    }

    ctx.translate(canvas.width / 2, canvas.height / 2);
    ctx.rotate((degrees * Math.PI) / 180);
    ctx.drawImage(image, -image.width / 2, -image.height / 2);
    return canvas.toDataURL();
  }

  function scheduleNextSnapshot() {
    clearTimeout(snapshot_timer);
    snapshot_timer = setTimeout(refreshSnapshot, SNAPSHOT_INTERVAL_MS);
  }

  function refreshSnapshot() {
    var orig_img = new Image();
    var snapshot_url;
    if ("localhost" === document.domain || "127.0.0.1" === document.domain) {
      snapshot_url = "snapshot?ext=jpg&compress=0.7&zoom=1&t=" + (new Date()).getTime().toString();
    } else {
      snapshot_url = "snapshot?ext=jpg&compress=0.00001&zoom=1&t=" + (new Date()).getTime().toString();
    }
    orig_img.src = snapshot_url;

    orig_img.onload = function () {
      var rect = main_drawer.getBoundingClientRect();
      var drawer_real_width = rect.x + rect.width;
      var app_bar_real_height = app_bar.clientHeight;
      var width_spacing;
      var height_spacing;

      orig_w = orig_img.width;
      orig_h = orig_img.height;
      drawer_real_width = drawer_real_width > 0 ? drawer_real_width : 0;
      width_spacing = drawer_real_width + edge_size * 2;
      height_spacing = app_bar_real_height + edge_size * 2;

      if (current_orien !== 0) {
        var omap = [0, 270, 90, 180];
        var rotated_img = new Image();
        rotated_img.src = rotateImage90(orig_img, omap[current_orien % 4]);
        rotated_img.onload = function () {
          drawSnapshot(rotated_img, width_spacing, height_spacing, true);
        };
        rotated_img.onerror = function () {
          scheduleNextSnapshot();
        };
        return;
      }

      drawSnapshot(orig_img, width_spacing, height_spacing, false);
    };

    orig_img.onerror = function () {
      scheduleNextSnapshot();
    };
  }

  function drawSnapshot(image, width_spacing, height_spacing, rotated) {
    var w;
    var h;
    if (rotated && (current_orien === 1 || current_orien === 2)) {
      w = $(window).width() - width_spacing;
      scr_scale = w / image.width;
      h = image.height * scr_scale;
      if (h > $(window).height() - height_spacing) {
        h = $(window).height() - height_spacing;
        scr_scale = h / image.height;
        w = image.width * scr_scale;
      }
    } else {
      h = $(window).height() - height_spacing;
      scr_scale = h / image.height;
      w = image.width * scr_scale;
      if (w > $(window).width() - width_spacing) {
        w = $(window).width() - width_spacing;
        scr_scale = w / image.width;
        h = image.height * scr_scale;
      }
    }

    $("#all_canvas").attr("height", h);
    $("#all_canvas").attr("width", w);
    all_canvas.getContext("2d").drawImage(image, 0, 0, image.width, image.height, 0, 0, w, h);
    scheduleNextSnapshot();
  }

  function unrotateXY(x, y, orien) {
    switch (normalizeRotateQuarter(orien)) {
      case 1:
        return { x: orig_w - y - 1, y: x };
      case 2:
        return { x: y, y: orig_h - x - 1 };
      case 3:
        return { x: orig_w - x - 1, y: orig_h - y - 1 };
      default:
        return { x: x, y: y };
    }
  }

  function coordsToNorm(client_x, client_y, clamp) {
    var rect = all_canvas.getBoundingClientRect();
    var px = client_x - rect.left;
    var py = client_y - rect.top;
    var local_x;
    var local_y;
    var pos;

    if (!orig_w || !orig_h || !scr_scale) {
      return null;
    }

    if (!clamp && (px < 0 || py < 0 || px > rect.width || py > rect.height)) {
      return null;
    }

    local_x = Math.max(0, Math.min(rect.width, px));
    local_y = Math.max(0, Math.min(rect.height, py));
    pos = unrotateXY(local_x / scr_scale, local_y / scr_scale, current_orien);

    return {
      nx: clampUnit(pos.x / orig_w),
      ny: clampUnit(pos.y / orig_h)
    };
  }

  function isSocketOpen(socket) {
    return !!(socket && socket.readyState === WebSocket.OPEN);
  }

  function sendSocketMessage(socket, payload, error_prefix) {
    if (!isSocketOpen(socket)) {
      return false;
    }
    try {
      socket.send(JSON.stringify(payload));
      return true;
    } catch (error) {
      console.warn(error_prefix, error);
      return false;
    }
  }

  function sendMessage(payload) {
    return sendSocketMessage(ws_client, payload, "发送远控消息失败:");
  }

  function requestInputFrame(callback) {
    if (typeof window.requestAnimationFrame === "function") {
      return window.requestAnimationFrame(callback);
    }
    return window.setTimeout(callback, 16);
  }

  function cancelInputFrame(frame_id) {
    if (typeof window.cancelAnimationFrame === "function") {
      window.cancelAnimationFrame(frame_id);
      return;
    }
    window.clearTimeout(frame_id);
  }

  function truncateTowardZero(value) {
    return value < 0 ? Math.ceil(value) : Math.floor(value);
  }

  function rotateRelativeDelta(dx, dy, orien) {
    switch (normalizeRotateQuarter(orien)) {
      case 1:
        return { dx: -dy, dy: dx };
      case 2:
        return { dx: dy, dy: -dx };
      case 3:
        return { dx: -dx, dy: -dy };
      default:
        return { dx: dx, dy: dy };
    }
  }

  function sendChunkedHardwareMouseDelta(mode, dx, dy, limit) {
    var remaining_x = dx;
    var remaining_y = dy;
    var chunk_x;
    var chunk_y;
    while (remaining_x !== 0 || remaining_y !== 0) {
      chunk_x = Math.max(-limit, Math.min(limit, remaining_x));
      chunk_y = Math.max(-limit, Math.min(limit, remaining_y));
      if (!sendMessage({
        mode: mode,
        dx: chunk_x,
        dy: chunk_y
      })) {
        return false;
      }
      remaining_x -= chunk_x;
      remaining_y -= chunk_y;
    }
    return true;
  }

  function clearHardwareMouseMoveBatch() {
    if (hardware_mouse_move_frame !== null) {
      cancelInputFrame(hardware_mouse_move_frame);
      hardware_mouse_move_frame = null;
    }
    hardware_mouse_move_dx = 0;
    hardware_mouse_move_dy = 0;
  }

  function flushHardwareMouseMove() {
    var send_dx;
    var send_dy;
    if (hardware_mouse_move_frame !== null) {
      cancelInputFrame(hardware_mouse_move_frame);
      hardware_mouse_move_frame = null;
    }
    if (!hardware_mouse_connected || !isRemoteControlReady()) {
      clearHardwareMouseMoveBatch();
      return;
    }
    send_dx = truncateTowardZero(hardware_mouse_move_dx);
    send_dy = truncateTowardZero(hardware_mouse_move_dy);
    hardware_mouse_move_dx -= send_dx;
    hardware_mouse_move_dy -= send_dy;
    if (send_dx !== 0 || send_dy !== 0) {
      sendChunkedHardwareMouseDelta("hardware-mouse-move", send_dx, send_dy, HARDWARE_MOUSE_MOVE_LIMIT);
    }
  }

  function queueHardwareMouseMove(dx, dy) {
    var rotated;
    if (!hardware_mouse_connected || !isRemoteControlReady() || !isFinite(dx) || !isFinite(dy)) {
      return;
    }
    rotated = rotateRelativeDelta(dx, dy, current_orien);
    hardware_mouse_move_dx += rotated.dx;
    hardware_mouse_move_dy += rotated.dy;
    if (hardware_mouse_move_frame === null) {
      hardware_mouse_move_frame = requestInputFrame(function () {
        hardware_mouse_move_frame = null;
        flushHardwareMouseMove();
      });
    }
  }

  function clearHardwareMouseScrollBatch() {
    if (hardware_mouse_scroll_frame !== null) {
      cancelInputFrame(hardware_mouse_scroll_frame);
      hardware_mouse_scroll_frame = null;
    }
    hardware_mouse_scroll_dx = 0;
    hardware_mouse_scroll_dy = 0;
  }

  function flushHardwareMouseScroll() {
    var send_dx;
    var send_dy;
    if (hardware_mouse_scroll_frame !== null) {
      cancelInputFrame(hardware_mouse_scroll_frame);
      hardware_mouse_scroll_frame = null;
    }
    if (!hardware_mouse_connected || !isRemoteControlReady()) {
      clearHardwareMouseScrollBatch();
      return;
    }
    send_dx = truncateTowardZero(hardware_mouse_scroll_dx);
    send_dy = truncateTowardZero(hardware_mouse_scroll_dy);
    hardware_mouse_scroll_dx -= send_dx;
    hardware_mouse_scroll_dy -= send_dy;
    if (send_dx !== 0 || send_dy !== 0) {
      sendChunkedHardwareMouseDelta("hardware-mouse-scroll", send_dx, send_dy, HARDWARE_MOUSE_SCROLL_LIMIT);
    }
  }

  function queueHardwareMouseScroll(dx, dy) {
    var rotated;
    if (!hardware_mouse_connected || !isRemoteControlReady() || !isFinite(dx) || !isFinite(dy)) {
      return;
    }
    rotated = rotateRelativeDelta(dx, dy, current_orien);
    hardware_mouse_scroll_dx += rotated.dx;
    hardware_mouse_scroll_dy += rotated.dy;
    if (hardware_mouse_scroll_frame === null) {
      hardware_mouse_scroll_frame = requestInputFrame(function () {
        hardware_mouse_scroll_frame = null;
        flushHardwareMouseScroll();
      });
    }
  }

  function hardwareMouseButtonNumber(event_button) {
    if (event_button === 0) {
      return 1;
    }
    if (event_button === 2) {
      return 2;
    }
    return null;
  }

  function releaseAllHardwareMouseButtons() {
    var button;
    flushHardwareMouseMove();
    flushHardwareMouseScroll();
    for (button = 1; button <= 2; button += 1) {
      if (hardware_mouse_pressed_buttons[button]) {
        sendMessage({ mode: "hardware-mouse-up", button: button });
      }
    }
    hardware_mouse_pressed_buttons = {};
  }

  function getPointerLockElement() {
    return document.pointerLockElement || document.mozPointerLockElement || document.webkitPointerLockElement || null;
  }

  function isHardwareMouseCaptured() {
    return getPointerLockElement() === all_canvas;
  }

  function clearHardwareMouseConsumedEscape() {
    hardware_mouse_consumed_escape = false;
    hardware_mouse_consumed_escape_until = 0;
  }

  function exitHardwareMouseCapture() {
    var exit_pointer_lock;
    if (!isHardwareMouseCaptured()) {
      return;
    }
    exit_pointer_lock = document.exitPointerLock || document.mozExitPointerLock || document.webkitExitPointerLock;
    if (typeof exit_pointer_lock === "function") {
      exit_pointer_lock.call(document);
    }
  }

  function resetHardwareMouseInput(send_releases, exit_capture) {
    if (send_releases && hardware_mouse_connected && isRemoteControlReady()) {
      releaseAllHardwareMouseButtons();
    } else {
      hardware_mouse_pressed_buttons = {};
    }
    clearHardwareMouseMoveBatch();
    clearHardwareMouseScrollBatch();
    hardware_mouse_capture_button = null;
    if (exit_capture) {
      clearHardwareMouseConsumedEscape();
      exitHardwareMouseCapture();
    }
  }

  function requestHardwareMouseCapture() {
    var request_pointer_lock = all_canvas.requestPointerLock || all_canvas.mozRequestPointerLock || all_canvas.webkitRequestPointerLock;
    var request_result;
    if (!hardware_mouse_connected || isHardwareMouseCaptured()) {
      return;
    }
    if (typeof request_pointer_lock !== "function") {
      hardware_mouse_capture_button = null;
      mdui.snackbar({
        message: "当前浏览器不支持鼠标捕获"
      });
      return;
    }
    try {
      request_result = request_pointer_lock.call(all_canvas);
      if (request_result && typeof request_result.catch === "function") {
        request_result.catch(function () {
          handleHardwareMouseCaptureError();
        });
      }
    } catch (error) {
      hardware_mouse_capture_button = null;
      mdui.snackbar({
        message: "无法捕获鼠标，请重试"
      });
    }
  }

  function handleHardwareMouseCaptureChange() {
    if (isHardwareMouseCaptured()) {
      hardware_mouse_capture_button = null;
    } else {
      resetHardwareMouseInput(true, false);
    }
    updateHardwareMouseToggle();
  }

  function handleHardwareMouseCaptureError() {
    var now = Date.now();
    hardware_mouse_capture_button = null;
    if (!hardware_mouse_connected) {
      return;
    }
    if (now - hardware_mouse_capture_error_timestamp < 500) {
      return;
    }
    hardware_mouse_capture_error_timestamp = now;
    mdui.snackbar({
      message: "无法捕获鼠标，请重试"
    });
  }

  function sendTouchPhase(phase, norm, finger) {
    if (!norm) {
      return false;
    }
    return sendMessage({
      mode: "norm-touch-" + phase,
      x: norm.nx,
      y: norm.ny,
      norm: true,
      finger: finger
    });
  }

  function sendWheelMessage(payload) {
    var settings;
    if (!payload || !isRemoteControlReady()) {
      return;
    }
    settings = normalize_wheel_settings(payload.settings || wheel_settings);
    sendMessage({
      mode: "wheel",
      x: payload.nx,
      y: payload.ny,
      norm: true,
      deltaY: payload.deltaY,
      rotateQuarter: normalizeRotateQuarter(payload.rotateQuarter),
      enabled: settings.enabled,
      natural: settings.natural,
      brakeEnabled: settings.brakeEnabled,
      stepPx: settings.stepPx,
      coalesceMs: settings.coalesceMs,
      amp: settings.amp,
      durBaseMs: settings.durBaseMs,
      releaseDelayMs: settings.releaseDelayMs,
      brakeReversePx: settings.brakeReversePx
    });
  }

  function sendTouchUpMessage(socket, norm, finger) {
    if (!norm) {
      return false;
    }
    return sendSocketMessage(socket, {
      mode: "norm-touch-up",
      x: norm.nx,
      y: norm.ny,
      norm: true,
      finger: finger
    }, "发送抬手事件失败:");
  }

  function releaseRemoteContact(contact_key, norm, target_socket) {
    var existing = active_remote_contacts.release(contact_key);
    var final_norm = norm;
    var socket = typeof target_socket === "undefined" ? ws_client : target_socket;
    if (!existing) {
      return;
    }
    if (!final_norm && existing.data) {
      final_norm = existing.data.lastNorm;
    }
    if (!socket || socket.readyState !== WebSocket.OPEN || !final_norm) {
      return;
    }
    sendTouchUpMessage(socket, final_norm, existing.finger);
  }

  function releaseAllRemoteContacts(target_socket) {
    var contacts = active_remote_contacts.clear();
    var socket = typeof target_socket === "undefined" ? ws_client : target_socket;
    var index;
    var contact;
    for (index = 0; index < contacts.length; index += 1) {
      contact = contacts[index][1];
      if (contact && contact.data) {
        sendTouchUpMessage(socket, contact.data.lastNorm, contact.finger);
      }
    }
  }

  function updateContactLastNorm(contact_key, norm) {
    var contact;
    if (!norm) {
      return null;
    }
    contact = active_remote_contacts.get(contact_key);
    if (!contact || !contact.data) {
      return null;
    }
    contact.data.lastNorm = norm;
    return contact;
  }

  function beginRemoteContact(contact_key, norm) {
    var contact;
    if (!norm || active_remote_contacts.get(contact_key)) {
      return null;
    }
    contact = active_remote_contacts.acquire(contact_key, { lastNorm: norm });
    if (!contact) {
      return null;
    }
    updateContactLastNorm(contact_key, norm);
    sendTouchPhase("down", norm, contact.finger);
    return contact;
  }

  function moveRemoteContact(contact_key, norm) {
    var contact = active_remote_contacts.get(contact_key);
    if (!contact || !norm) {
      return null;
    }
    updateContactLastNorm(contact_key, norm);
    sendTouchPhase("move", norm, contact.finger);
    return contact;
  }

  function getMouseContact() {
    return active_remote_contacts.get(MOUSE_CONTACT_KEY);
  }

  function releaseMouseContactFromEvent(event, clamp) {
    var existing = getMouseContact();
    var norm;
    if (isRecentSyntheticMouse(event) || !existing) {
      return false;
    }
    norm = coordsToNorm(event.clientX, event.clientY, clamp) || existing.data.lastNorm;
    releaseRemoteContact(MOUSE_CONTACT_KEY, norm);
    return true;
  }

  function handleKeyboardPhase(event, phase) {
    var code = event.keyCode || event.which || event.charCode;
    if (code === 27) {
      if (hardware_mouse_consumed_escape && phase === "up") {
        clearHardwareMouseConsumedEscape();
        return true;
      }
      if (hardware_mouse_consumed_escape) {
        if (event.repeat || Date.now() <= hardware_mouse_consumed_escape_until) {
          return true;
        }
        clearHardwareMouseConsumedEscape();
      }
      if (phase === "down" && isHardwareMouseCaptured()) {
        hardware_mouse_consumed_escape = true;
        hardware_mouse_consumed_escape_until = Date.now() + TOUCH_MOUSE_GUARD_MS;
        return true;
      }
    }
    if (isTargetInsideBlockingDialog(event.target) || !isRemoteControlReady()) {
      return true;
    }
    sendMessage({
      mode: "input_" + phase,
      key: code
    });
    event.returnValue = false;
    event.preventDefault();
    return false;
  }

  function onCanvasMouseDown(event) {
    var norm;
    var mouse_button;
    if (isRecentSyntheticMouse(event)) {
      return;
    }
    if (!canHandleRemoteInput()) {
      return;
    }
    if (isHardwareMouseModeSelected()) {
      mouse_button = hardwareMouseButtonNumber(event.button);
      if (mouse_button === null) {
        return;
      }
      event.preventDefault();
      event.stopPropagation();
      if (!hardware_mouse_connected) {
        return;
      }
      if (!isHardwareMouseCaptured()) {
        if (event.button === 0) {
          hardware_mouse_capture_button = event.button;
          requestHardwareMouseCapture();
        }
        return;
      }
      if (!hardware_mouse_pressed_buttons[mouse_button]) {
        flushHardwareMouseMove();
        flushHardwareMouseScroll();
        if (sendMessage({ mode: "hardware-mouse-down", button: mouse_button })) {
          hardware_mouse_pressed_buttons[mouse_button] = true;
        }
      }
      return;
    }
    if (event.button === 2) {
      event.preventDefault();
      event.stopPropagation();
      sendMessage({ mode: "home" });
      return;
    }
    if (event.button !== 0) {
      return;
    }
    if (active_remote_contacts.size() > 0 && !getMouseContact()) {
      return;
    }
    norm = coordsToNorm(event.clientX, event.clientY, false);
    if (!norm) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    wheel_batcher.clear();
    beginRemoteContact(MOUSE_CONTACT_KEY, norm);
  }

  function onDocumentMouseMove(event) {
    var norm;
    var movement_x;
    var movement_y;
    if (isRecentSyntheticMouse(event)) {
      return;
    }
    if (isHardwareMouseModeSelected()) {
      if (!hardware_mouse_connected || !isHardwareMouseCaptured() || !canHandleRemoteInput()) {
        return;
      }
      movement_x = typeof event.movementX === "number" ? event.movementX :
        (typeof event.mozMovementX === "number" ? event.mozMovementX :
          (typeof event.webkitMovementX === "number" ? event.webkitMovementX : 0));
      movement_y = typeof event.movementY === "number" ? event.movementY :
        (typeof event.mozMovementY === "number" ? event.mozMovementY :
          (typeof event.webkitMovementY === "number" ? event.webkitMovementY : 0));
      if (movement_x !== 0 || movement_y !== 0) {
        queueHardwareMouseMove(movement_x, movement_y);
      }
      if (event.cancelable) {
        event.preventDefault();
      }
      event.stopPropagation();
      return;
    }
    if (!getMouseContact() || (event.buttons & 1) !== 1 || !canHandleRemoteInput()) {
      return;
    }
    norm = coordsToNorm(event.clientX, event.clientY, false);
    if (!norm) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    moveRemoteContact(MOUSE_CONTACT_KEY, norm);
  }

  function onDocumentMouseUp(event) {
    var mouse_button;
    if (isHardwareMouseModeSelected()) {
      if (event.sourceCapabilities && event.sourceCapabilities.firesTouchEvents === true) {
        return;
      }
      mouse_button = hardwareMouseButtonNumber(event.button);
      if (mouse_button === null) {
        return;
      }
      event.preventDefault();
      event.stopPropagation();
      if (hardware_mouse_capture_button === event.button) {
        hardware_mouse_capture_button = null;
        return;
      }
      if (hardware_mouse_connected && hardware_mouse_pressed_buttons[mouse_button]) {
        flushHardwareMouseMove();
        flushHardwareMouseScroll();
        sendMessage({ mode: "hardware-mouse-up", button: mouse_button });
        delete hardware_mouse_pressed_buttons[mouse_button];
      }
      return;
    }
    if (!releaseMouseContactFromEvent(event, true)) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
  }

  function onCanvasMouseLeave(event) {
    if (isHardwareMouseModeSelected()) {
      return;
    }
    releaseMouseContactFromEvent(event, true);
  }

  function onCanvasTouchStart(event) {
    var touches = event.changedTouches;
    var handled = false;
    var index;
    markTouchActivity();
    if (!canHandleRemoteInput()) {
      return;
    }
    if (getMouseContact()) {
      return;
    }
    for (index = 0; index < touches.length; index += 1) {
      var touch_item = touches[index];
      var contact_key = TOUCH_CONTACT_PREFIX + touch_item.identifier;
      var norm = coordsToNorm(touch_item.clientX, touch_item.clientY, false);
      if (!norm) {
        continue;
      }
      if (beginRemoteContact(contact_key, norm)) {
        handled = true;
      }
    }
    if (handled && event.cancelable) {
      event.preventDefault();
      wheel_batcher.clear();
    }
  }

  function onDocumentTouchMove(event) {
    var touches = event.changedTouches;
    var handled = false;
    var index;
    markTouchActivity();
    if (!canHandleRemoteInput()) {
      return;
    }
    for (index = 0; index < touches.length; index += 1) {
      var touch_item = touches[index];
      var contact_key = TOUCH_CONTACT_PREFIX + touch_item.identifier;
      var norm;
      norm = coordsToNorm(touch_item.clientX, touch_item.clientY, false);
      if (moveRemoteContact(contact_key, norm)) {
        handled = true;
      }
    }
    if (handled && event.cancelable) {
      event.preventDefault();
    }
  }

  function onDocumentTouchEnd(event) {
    var touches = event.changedTouches;
    var handled = false;
    var index;
    markTouchActivity();
    for (index = 0; index < touches.length; index += 1) {
      var touch_item = touches[index];
      var contact_key = TOUCH_CONTACT_PREFIX + touch_item.identifier;
      var existing = active_remote_contacts.get(contact_key);
      var norm;
      if (!existing) {
        continue;
      }
      norm = coordsToNorm(touch_item.clientX, touch_item.clientY, true) || existing.data.lastNorm;
      releaseRemoteContact(contact_key, norm);
      handled = true;
    }
    if (handled && event.cancelable) {
      event.preventDefault();
    }
  }

  function wheelDeltaToHardwareUnits(delta, delta_mode) {
    if (!isFinite(delta) || delta === 0) {
      return 0;
    }
    if (delta_mode === 1) {
      return delta / 3;
    }
    if (delta_mode === 2) {
      return delta;
    }
    return delta / 100;
  }

  function handleCanvasWheel(event) {
    var settings;
    var delta_y;
    var norm;
    var hardware_dx;
    var hardware_dy;
    if (isHardwareMouseModeSelected()) {
      if (event.cancelable) {
        event.preventDefault();
      }
      event.stopPropagation();
      if (!hardware_mouse_connected || !canHandleRemoteInput() || event.ctrlKey) {
        return;
      }
      hardware_dx = typeof event.wheelDeltaX === "number" ? event.wheelDeltaX / 120 :
        wheelDeltaToHardwareUnits(event.deltaX, event.deltaMode);
      hardware_dy = typeof event.wheelDeltaY === "number" ? event.wheelDeltaY / 120 :
        -wheelDeltaToHardwareUnits(event.deltaY, event.deltaMode);
      if (hardware_dx !== 0 || hardware_dy !== 0) {
        queueHardwareMouseScroll(hardware_dx, hardware_dy);
      }
      return;
    }
    if (!remote_wheel.normalizeWheelDeltaY || !remote_wheel.canHandle) {
      return;
    }
    if (!canHandleRemoteInput()) {
      return;
    }
    settings = normalize_wheel_settings(wheel_settings);
    delta_y = remote_wheel.normalizeWheelDeltaY(event.deltaY, event.deltaMode, all_canvas.clientHeight || all_canvas.getBoundingClientRect().height || 0);
    if (!remote_wheel.canHandle({
      enabled: settings.enabled,
      pointerActive: active_remote_contacts.size() > 0,
      deltaY: delta_y
    })) {
      return;
    }
    norm = coordsToNorm(event.clientX, event.clientY, false);
    if (!norm) {
      return;
    }
    if (event.cancelable) {
      event.preventDefault();
    }
    event.stopPropagation();
    wheel_batcher.schedule({
      mergeKey: "screen-wheel:" + String(normalizeRotateQuarter(current_orien)),
      nx: norm.nx,
      ny: norm.ny,
      deltaY: delta_y,
      rotateQuarter: normalizeRotateQuarter(current_orien),
      settings: settings
    });
  }

  function bindInputEvents() {
    $("#main-drawer a[href='./screen.html']").addClass("mdui-list-item-active");
    $("#all_canvas").on("selectstart", function () {
      return false;
    });

    document.addEventListener("keydown", function (event) {
      return handleKeyboardPhase(event, "down");
    });

    document.addEventListener("keyup", function (event) {
      return handleKeyboardPhase(event, "up");
    });

    all_canvas.addEventListener("mousedown", onCanvasMouseDown);
    document.addEventListener("mousemove", onDocumentMouseMove);
    document.addEventListener("mouseup", onDocumentMouseUp);
    all_canvas.addEventListener("mouseleave", onCanvasMouseLeave);
    all_canvas.addEventListener("contextmenu", function (event) {
      event.preventDefault();
    });
    all_canvas.addEventListener("wheel", handleCanvasWheel, { passive: false });
    all_canvas.addEventListener("touchstart", onCanvasTouchStart, { passive: false });
    document.addEventListener("touchmove", onDocumentTouchMove, { passive: false });
    document.addEventListener("touchend", onDocumentTouchEnd, { passive: false });
    document.addEventListener("touchcancel", onDocumentTouchEnd, { passive: false });
    document.addEventListener("pointerlockchange", handleHardwareMouseCaptureChange);
    document.addEventListener("mozpointerlockchange", handleHardwareMouseCaptureChange);
    document.addEventListener("webkitpointerlockchange", handleHardwareMouseCaptureChange);
    document.addEventListener("pointerlockerror", handleHardwareMouseCaptureError);
    document.addEventListener("mozpointerlockerror", handleHardwareMouseCaptureError);
    document.addEventListener("webkitpointerlockerror", handleHardwareMouseCaptureError);

    window.addEventListener("blur", function () {
      var mouse_contact = getMouseContact();
      if (isHardwareMouseModeSelected()) {
        resetHardwareMouseInput(true, true);
      }
      if (mouse_contact) {
        releaseRemoteContact(MOUSE_CONTACT_KEY, mouse_contact.data.lastNorm);
      }
    });

    $(window).on("beforeunload unload", function () {
      is_unloading = true;
      clearSocketTimers();
      clearHardwareKeyboardRequest();
      clearHardwareMouseRequest();
      resetHardwareMouseInput(true, true);
      wheel_batcher.clear();
      releaseAllRemoteContacts(ws_client);
      clearTimeout(snapshot_timer);
      if (ws_client) {
        if (isSocketOpen(ws_client)) {
          sendSocketMessage(ws_client, { mode: "quit" }, "退出远控服务失败:");
        }
        try {
          ws_client.close();
        } catch (close_error) {
          console.warn("关闭远控连接失败:", close_error);
        }
      }
    });
  }

  function bindToolbarEvents() {
    $(screen_toolbar_overflow_menu).on("click", ".screen-toolbar-overflow-action", function (event) {
      var target = document.getElementById(this.getAttribute("data-toolbar-target"));
      event.preventDefault();
      if (!target || target.getAttribute("aria-disabled") === "true") {
        return;
      }
      target.click();
    });

    $(screen_toolbar_overflow_menu).on("open.mdui.menu", function () {
      screen_toolbar_more.setAttribute("aria-expanded", "true");
    });

    $(screen_toolbar_overflow_menu).on("close.mdui.menu closed.mdui.menu", function () {
      screen_toolbar_more.setAttribute("aria-expanded", "false");
    });

    $(window).on("load", layoutScreenToolbar);
    $(window).on("resize orientationchange", mdui.JQ.throttle(layoutScreenToolbar, 50));

    $("#toggle-hardware-keyboard").on("click", function (event) {
      var action;
      event.preventDefault();
      event.stopPropagation();
      if (hardware_keyboard_pending_action) {
        return;
      }
      if (!isRemoteControlReady()) {
        mdui.snackbar({
          message: "远控连接尚未建立"
        });
        return;
      }

      action = hardware_keyboard_connected ? "disconnect" : "connect";
      hardware_keyboard_pending_action = action;
      updateHardwareKeyboardToggle();
      if (!sendMessage({ mode: "hardware-keyboard-" + action })) {
        clearHardwareKeyboardRequest();
        updateHardwareKeyboardToggle();
        mdui.snackbar({
          message: "发送硬件键盘操作失败"
        });
        return;
      }

      hardware_keyboard_request_timer = setTimeout(function () {
        hardware_keyboard_request_timer = null;
        hardware_keyboard_pending_action = null;
        updateHardwareKeyboardToggle();
        sendMessage({ mode: "hardware-keyboard-status" });
        mdui.snackbar({
          message: "硬件键盘操作超时，请重试"
        });
      }, HARDWARE_KEYBOARD_REQUEST_TIMEOUT_MS);
    });

    $("#toggle-hardware-mouse").on("click", function (event) {
      var action;
      var mouse_contact;
      event.preventDefault();
      event.stopPropagation();
      if (hardware_mouse_pending_action) {
        return;
      }
      if (!isRemoteControlReady()) {
        mdui.snackbar({
          message: "远控连接尚未建立"
        });
        return;
      }

      action = hardware_mouse_connected ? "disconnect" : "connect";
      if (action === "disconnect") {
        resetHardwareMouseInput(true, true);
      } else {
        mouse_contact = getMouseContact();
        if (mouse_contact) {
          releaseRemoteContact(MOUSE_CONTACT_KEY, mouse_contact.data.lastNorm);
        }
        wheel_batcher.clear();
      }
      hardware_mouse_pending_action = action;
      updateHardwareMouseToggle();
      if (!sendMessage({ mode: "hardware-mouse-" + action })) {
        clearHardwareMouseRequest();
        updateHardwareMouseToggle();
        mdui.snackbar({
          message: "发送硬件鼠标操作失败"
        });
        return;
      }

      hardware_mouse_request_timer = setTimeout(function () {
        hardware_mouse_request_timer = null;
        hardware_mouse_pending_action = null;
        updateHardwareMouseToggle();
        sendMessage({ mode: "hardware-mouse-status" });
        mdui.snackbar({
          message: "硬件鼠标操作超时，请重试"
        });
      }, HARDWARE_MOUSE_REQUEST_TIMEOUT_MS);
    });

    $("#home").on("click", function () {
      sendMessage({ mode: "home" });
    });

    $("#power").on("click", function () {
      sendMessage({ mode: "power" });
    });

    $("#rotate_turn_left").on("click", function () {
      var next_orien;
      flushHardwareMouseMove();
      flushHardwareMouseScroll();
      next_orien = TURN_LEFT_ORIEN_MAP[normalizeRotateQuarter(current_orien)];
      current_orien = next_orien;
      wheel_batcher.clear();
      clearTimeout(snapshot_timer);
      refreshSnapshot();
    });
  }

  function clearSocketTimers() {
    if (heartbeat_interval) {
      clearInterval(heartbeat_interval);
      heartbeat_interval = null;
    }
    if (heartbeat_timeout) {
      clearTimeout(heartbeat_timeout);
      heartbeat_timeout = null;
    }
  }

  function resetHeartbeatWatchdog() {
    if (heartbeat_timeout) {
      clearTimeout(heartbeat_timeout);
    }
    heartbeat_timeout = setTimeout(function () {
      if (ws_client && ws_client.readyState === WebSocket.OPEN) {
        try {
          ws_client.close();
        } catch (error) {
          console.warn("心跳超时关闭连接失败:", error);
        }
      }
    }, HEARTBEAT_TIMEOUT_MS);
  }

  function startHeartbeatLoop() {
    clearSocketTimers();
    heartbeat_interval = setInterval(function () {
      sendMessage({ mode: "heart" });
    }, HEARTBEAT_INTERVAL_MS);
    resetHeartbeatWatchdog();
  }

  function showReconnectDialog() {
    if (reconnect_dialog_visible) {
      return;
    }
    reconnect_dialog_visible = true;
    mdui.dialog({
      title: "远控连接已断开",
      content: "请等待服务恢复后重新建立连接",
      buttons: [{
        text: "重新连接",
        onClick: function () {
          reconnect_dialog_visible = false;
          has_connected_once = false;
          spawn_attempted = false;
          connectScreenSocket();
        }
      }, {
        text: "WebRTC 远控",
        onClick: function (inst) {
          reconnect_dialog_visible = false;
          inst.close();
          setTimeout(function () {
            window.location.href = "./webrtc/";
          }, 100);
        }
      }]
    });
  }

  function handleSocketMessage(socket, event) {
    var payload;
    if (socket !== ws_client) {
      return;
    }
    try {
      payload = JSON.parse(event.data);
    } catch (error) {
      return;
    }
    if (payload && payload.mode === "heart") {
      resetHeartbeatWatchdog();
      sendMessage({ mode: "heart" });
      return;
    }
    if (payload && payload.mode === "hardware-keyboard-state") {
      handleHardwareKeyboardState(payload);
      return;
    }
    if (payload && payload.mode === "hardware-mouse-state") {
      handleHardwareMouseState(payload);
    }
  }

  function handleSocketClose(socket) {
    if (socket !== ws_client) {
      return;
    }
    ws_client = null;
    clearSocketTimers();
    clearHardwareKeyboardRequest();
    hardware_keyboard_connected = false;
    updateHardwareKeyboardToggle();
    clearHardwareMouseRequest();
    hardware_mouse_connected = false;
    resetHardwareMouseInput(false, true);
    updateHardwareMouseToggle();
    wheel_batcher.clear();
    releaseAllRemoteContacts(socket);
    if (is_unloading) {
      return;
    }
    if (!has_connected_once && !spawn_attempted) {
      spawn_attempted = true;
      spawnScreenService();
      return;
    }
    mdui.snackbar({
      message: "远控连接已断开"
    });
    showReconnectDialog();
  }

  function attachSocketHandlers(socket) {
    socket.onopen = function () {
      if (socket !== ws_client) {
        return;
      }
      has_connected_once = true;
      spawn_attempted = false;
      reconnect_dialog_visible = false;
      clearHardwareKeyboardRequest();
      hardware_keyboard_connected = false;
      updateHardwareKeyboardToggle();
      clearHardwareMouseRequest();
      hardware_mouse_connected = false;
      resetHardwareMouseInput(false, true);
      updateHardwareMouseToggle();
      startHeartbeatLoop();
      sendMessage({ mode: "hardware-keyboard-status" });
      sendMessage({ mode: "hardware-mouse-status" });
    };

    socket.onmessage = function (event) {
      handleSocketMessage(socket, event);
    };

    socket.onclose = function () {
      handleSocketClose(socket);
    };

    socket.onerror = function (error) {
      if (socket !== ws_client) {
        return;
      }
      console.warn("远控连接异常:", error);
    };
  }

  function connectScreenSocket() {
    var host = window.location.hostname || document.domain;
    var socket;
    if (ws_client && (ws_client.readyState === WebSocket.OPEN || ws_client.readyState === WebSocket.CONNECTING)) {
      return;
    }
    clearSocketTimers();
    socket = new WebSocket("ws://" + host + ":" + SCREEN_WS_PORT, SCREEN_WS_PROTOCOL);
    ws_client = socket;
    attachSocketHandlers(socket);
  }

  function spawnScreenService() {
    $.post("/daemon_spawn", JSON.stringify({
      filename: SCREEN_SERVER_PATH
    }), function () {
      setTimeout(function () {
        connectScreenSocket();
      }, 1000);
    }, "json").error(function () {
      mdui.snackbar({
        message: "与设备通讯无法达成"
      });
      showReconnectDialog();
    });
  }
});
