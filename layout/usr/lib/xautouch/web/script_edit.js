function Str2Bytes(a) {
  var d, e, f, g, b = 0,
    c = a.length;
  if (0 != c % 4) return null;
  for (c /= 4, d = new Array, e = 0; c > e; e++) {
    if (f = a.substr(b, 4), "\\x" != f.substr(0, 2)) return null;
    f = f.substr(2, 2),
      g = parseInt(f, 16),
      d.push(g),
      b += 4
  }
  return d
}
$(document).ready(function () {
  var a, e, f, b = CodeMirror.fromTextArea(document.getElementById("debug_textArea"), {
    lineWrapping: !1,
    matchBrackets: !0,
    indentUnit: 4,
    tabSize: 4,
    theme: "base16-dark",
    styleActiveLine: !0,
    scrollbarStyle: "simple"
  }),
    maxLogLength = 512 * 1024,
    trimAmount = 256 * 1024,
    trimLogTail = function (a, b) {
      if (a.length <= b) return a;
      var c = a.length - b,
        d = a.indexOf("\n", c);
      return a.substring(-1 !== d ? d + 1 : c)
    },
    trimLogHead = function (a, b) {
      if (a.length <= b) return "";
      var c = a.indexOf("\n", b);
      return a.substring(-1 !== c ? c + 1 : b)
    },
    appendDebugLog = function (a) {
      var c, d;
      a && (c = trimLogTail(a, maxLogLength),
        d = b.getValue(),
        d.length + c.length > maxLogLength && d.length > 0 && (d = trimLogHead(d, trimAmount)),
        d += c,
        d.length > maxLogLength && (d = trimLogTail(d, maxLogLength)),
        b.setValue(d),
        b.setSelection({
          line: b.lastLine(),
          ch: 0
        }, {
          line: b.lastLine(),
          ch: 0
        }))
    },
    c = function (c) {
      var d = "file_textarea";
      c && (document.getElementById(d).innerHTML = c),
        a = CodeMirror.fromTextArea(document.getElementById("file_textarea"), {
          lineNumbers: !0,
          lineWrapping: !1,
          matchBrackets: !0,
          indentUnit: 4,
          tabSize: 4,
          theme: "base16-dark",
          styleActiveLine: !0,
          scrollbarStyle: "simple",
          highlightSelectionMatches: {
            showToken: /\w/,
            annotateScrollbar: !0
          },
          mode: {
            name: "lua",
            lobalVars: !0
          },
          extraKeys: {
            "Ctrl-Q": "autocomplete",
            "Ctrl-S": function () {
              e()
            },
            "Ctrl-Z": function (a) {
              a.undo()
            },
            "Ctrl-Y": function (a) {
              a.redo()
            },
            "Cmd-S": function () {
              e()
            },
            "Cmd-Z": function (a) {
              a.undo()
            },
            "Cmd-Y": function (a) {
              a.redo()
            }
          }
        }),
        a.setSize("auto", $(window).height() - 375 + "px"),
        b.setSize("auto", "255px"),
        $(window).resize(function () {
          a.setSize("auto", $(window).height() - 375 + "px"),
            $(window).height() < 600
        }),
        $("#path-file-undo").on("click",
          function () {
            a.undo()
          }),
        $("#path-file-redo").on("click",
          function () {
            a.redo()
          }),
        $("#path-file-save").on("click",
          function () {
            e()
          })
    },
    d = $.req("file");
  d ? ($("#path-file")[0].innerHTML = XXTI18n.t("编辑") + " " + d, $.post("/read_file", JSON.stringify({
    filename: d
  }),
    function (a) {
      var b, e;
      0 == a.code ? (b = d.split(".").pop().toLowerCase(), e = Base64.decode(a.data), c(e, b)) : (mdui.snackbar({
        message: XXTI18n.raw(a.message + "\n")
      }), c())
    },
    "json").error(function () {
      mdui.snackbar({
        message: "与设备通讯无法达成\n"
      }),
        c()
    })) : ($("#path-file")[0].innerHTML = XXTI18n.t("异常"), c()),
    e = function () {
      d && "" != d && $.post("/write_file", JSON.stringify({
        filename: d,
        data: Base64.encode(a.getValue())
      }),
        function (a) {
          0 == a.code ? f("保存成功\n") : mdui.snackbar({
            message: XXTI18n.raw(a.message + "\n")
          })
        },
        "json").error(function () {
          mdui.snackbar({
            message: "与设备通讯无法达成\n"
          })
        })
    },
    $("#launch-script-file").on("click",
      function () {
        $.post("/write_file", JSON.stringify({
          filename: d,
          data: Base64.encode(a.getValue())
        }),
          function (b) {
            0 == b.code ? (f("保存成功\n"), $.post("/check_syntax", a.getValue(),
              function (a) {
                0 != a.code ? f("脚本存在语法错误:" + a.detail + "\n") : $.post("/spawn", 'nLog = (function() local select = select local insert = table.insert local deep_print = table.deep_print local type = type local format = string.format local getinfo = debug.getinfo local concat = table.concat local SendMessage = function(...) local _m = {}; for i = 1, select("#", ...) do if type(select(i, ...)) == "table" then insert(_m, table.deep_print(({...})[i])) elseif type(select(i, ...)) == "nil" then insert(_m, "nil") elseif type(select(i, ...)) == "string" then local m = tostring(select(i, ...)):gsub("%[DATE%]",os.date("[%Y-%m-%d %H:%M:%S]")):gsub("%[LINE%]","["..tostring(debug.getinfo(2).currentline).."]") insert(_m, m) else insert(_m, format("%s",select(i, ...))) end end local _message = concat(_m,"	") sys.log(_message) end return SendMessage end)(); dofile(XXT_HOME_PATH .. "/" .. ' + JSON.stringify(d.replace(/^\/+/, "")) + ')',
                  function (a) {
                    f(a.message + "\n")
                  },
                  "json").error(function () {
                    mdui.snackbar({
                      message: "与设备通讯无法达成\n"
                    })
                  })
              },
              "json").error(function () {
                mdui.snackbar({
                  message: "与设备通讯无法达成\n"
                })
              })) : mdui.snackbar({
                message: XXTI18n.raw(b.message + "\n")
              })
          },
          "json").error(function () {
            mdui.snackbar({
              message: "与设备通讯无法达成\n"
            })
          })
      }),
    $("#recycle").on("click",
      function () {
        $.post("/recycle", "",
          function (a) {
            f(a.message + "\n")
          },
          "json").error(function () {
            mdui.snackbar({
              message: "与设备通讯无法达成\n"
            })
          })
      }),
    f = function (a) {
      appendDebugLog(a)
    };
  var eventSource = null;
  function startLogStream() {
    if (typeof EventSource === "undefined") {
      f("浏览器不支持日志流\n");
      return;
    }
    try {
      eventSource = new EventSource("/api/log/stream");
      eventSource.onopen = function () {
        f("日志服务已连接\n");
      };
      eventSource.onmessage = function (event) {
        var message = event.data;
        if (message) f(message.charAt(message.length - 1) === "\n" ? message : message + "\n");
      };
      eventSource.onerror = function () {
        f("日志服务出现错误\n");
      };
    } catch (error) {
      f("日志服务出现错误\n");
    }
  }
  window.addEventListener("pagehide", function () {
    if (eventSource) {
      eventSource.onopen = eventSource.onmessage = eventSource.onerror = null;
      eventSource.close();
      eventSource = null;
    }
  });
  window.addEventListener("pageshow", function (event) {
    if (event.persisted) startLogStream();
  });
  startLogStream();
});
