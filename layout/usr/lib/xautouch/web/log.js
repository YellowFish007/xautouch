$(document).ready(function () {
  $("#main-drawer a[href='./log.html']").addClass("mdui-list-item-active");
  $("#logTextArea").height(($(window).height() - 270));
  $(window).resize(function () {
    $("#logTextArea").height(($(window).height() - 270))
  });
  var logTextArea = document.getElementById("logTextArea");
  var statusLabel = $("#statusLabel");
  var pauseBtn = $("#pauseBtn");

  var maxLogLength = 512 * 1024; // 页面最多保留 512KB 日志，避免老设备浏览器卡死
  var trimAmount = 256 * 1024;   // 超过时，从开头截掉 256KB

  function setLogStatus(status) {
    statusLabel.text(status)
  }
  function trimLogTail(text, targetLength) {
    if (text.length <= targetLength) {
      return text;
    }

    var startIndex = text.length - targetLength;
    var cutPoint = text.indexOf('\n', startIndex);
    return text.substring((cutPoint !== -1) ? (cutPoint + 1) : startIndex);
  }
  function trimLogHead(text, targetTrimLength) {
    if (text.length <= targetTrimLength) {
      return "";
    }

    var cutPoint = text.indexOf('\n', targetTrimLength);
    return text.substring((cutPoint !== -1) ? (cutPoint + 1) : targetTrimLength);
  }
  function appendLog(message) {
    var normalizedMessage = trimLogTail(message, maxLogLength);

    // 首次连接可能一次收到很长 backlog，这里先截掉旧内容和超长新消息，只保留尾部可见日志。
    while (logTextArea.value.length + normalizedMessage.length > maxLogLength && logTextArea.value.length > 0) {
      logTextArea.value = trimLogHead(logTextArea.value, trimAmount);
    }

    // 使用 setRangeText 在末尾追加新消息
    logTextArea.setRangeText(normalizedMessage, logTextArea.value.length, logTextArea.value.length, "end");

    if (logTextArea.value.length > maxLogLength) {
      logTextArea.value = trimLogTail(logTextArea.value, maxLogLength);
    }

    logTextArea.scrollTop = logTextArea.scrollHeight
  }
  function normalizeLogMessage(message) {
    if (!message) {
      return "";
    }
    return message.charAt(message.length - 1) === "\n" ? message : (message + "\n");
  }
  var sseUri = "/api/log/stream";
  var eventSource = null;
  var paused = false;
  var pageHidden = false;
  var checkTimer = null;
  var lastErrorTime = 0;
  $("#clearLogs").click(function () {
    logTextArea.value = ""
  });
  $("#pauseBtn").click(function () {
    paused = !paused;
    if (paused) {
      stopEventSource();
      pauseBtn.removeClass("mdui-xxtouch-button");
      pauseBtn.addClass("mdui-xxtouch-color");
      pauseBtn.html("<i class='mdui-icon material-icons'>&#xe037;</i>继续接收")
    } else {
      initEventSource();
      pauseBtn.removeClass("mdui-xxtouch-color");
      pauseBtn.addClass("mdui-xxtouch-button");
      pauseBtn.html("<i class='mdui-icon material-icons'>&#xe034;</i>暂停接收")
    }
  });
  function initEventSource() {
    if (pageHidden) return;
    if (typeof EventSource === "undefined") {
      setLogStatus("浏览器不支持日志流")
      return;
    }
    stopEventSource();
    var opened = false;
    try {
      eventSource = new EventSource(sseUri);
      eventSource.onopen = function () {
        opened = true;
        setLogStatus("日志服务已连接")
      };
      eventSource.onmessage = function (evt) {
        appendLog(normalizeLogMessage(evt.data))
      };
      eventSource.onerror = function () {
        lastErrorTime = new Date().getTime();
        if (!opened && !paused) {
          setLogStatus("等待设备初始化日志服务……")
        }
      };
    } catch (exception) {
      lastErrorTime = new Date().getTime();
      setLogStatus("日志服务初始化失败")
    }
  }
  function stopEventSource() {
    if (eventSource) {
      eventSource.onopen = eventSource.onmessage = eventSource.onerror = null;
      eventSource.close();
      eventSource = null;
    }
  }
  function while_check() {
    if (pageHidden) return;
    if (!paused) {
      if (eventSource == null || eventSource.readyState === 2) {
        setLogStatus("等待设备初始化日志服务……");
        initEventSource()
      } else if (eventSource.readyState === 1) {
        setLogStatus("日志服务已连接")
      } else {
        setLogStatus("等待设备初始化日志服务……")
      }
    } else {
      setLogStatus("暂停获取日志")
    }
    if (lastErrorTime != 0) {
      lastErrorTime = 0;
      checkTimer = setTimeout(while_check, 10000)
    } else {
      checkTimer = setTimeout(while_check, 1000)
    }
  }
  window.addEventListener("pagehide", function () {
    pageHidden = true;
    clearTimeout(checkTimer);
    stopEventSource();
  });
  window.addEventListener("pageshow", function (event) {
    if (event.persisted) {
      pageHidden = false;
      while_check();
    }
  });
  while_check();
});
