function strturn(a) {
  var b, c;
  if ("" != a) {
    for (b = "", c = a.length - 1; c >= 0; c--) b += a.charAt(c);
    return b
  }
}
function GetFileExt(a) {
  if ("" != a) {
    var b = "." + a.replace(/.+\./, "");
    return b
  }
}
function GetFileNameNoExt(a) {
  var b = strturn(GetFileExt(a)),
    c = strturn(a),
    d = strturn(c.replace(b, "")),
    e = GetFileName(d);
  return e
}
function GetFileName(a) {
  if ("" != a) {
    var b = a.split("\\");
    return b[b.length - 1]
  }
}
$(document).ready(function () {
  var supportedFormats = [];
  var defaultFormatVersion;
  var formatLabels = {3: "v3（2023-10-19）", 4: "v4（2026-10-30）"};
  function updateFormatOptions() {
    var selected = $("#format_version").val();
    var effectiveVersion = selected === "default" ? defaultFormatVersion : Number(selected);
    $("#format_version option[value='default']").text(defaultFormatVersion
      ? XXTI18n.t("跟随偏好设置（{version}）", {version: "v" + defaultFormatVersion})
      : XXTI18n.t("跟随偏好设置"));
    if (selected === "default" && defaultFormatVersion) {
      $("#default_format_preview").text(XXTI18n.t("当前默认：{format}", {
        format: XXTI18n.t(formatLabels[defaultFormatVersion] || "v" + defaultFormatVersion)
      })).show();
    } else $("#default_format_preview").hide();
    if (effectiveVersion === 3) $("#legacy_debug_options").show();
    else $("#legacy_debug_options").hide();
  }
  $("#format_version").on("change", updateFormatOptions);
  updateFormatOptions();
  function parseBlobJson(blob, callback) {
    var reader = new FileReader;
    reader.readAsText(blob),
      reader.onload = function () {
        var json = null;
        try {
          json = JSON.parse(this.result)
        } catch (e) { }
        callback(json)
      }
  }
  function getEncryptErrorMessage(json) {
    if (!json) return "出现一个错误";
    if ("string" == typeof json.detail && "" !== json.detail) return XXTI18n.raw(json.detail);
    if ("string" == typeof json.message && "" !== json.message) return XXTI18n.raw(json.message);
    return "出现一个错误"
  }
  function arrayBufferToBase64(a) {
    var e, b = "",
      c = new Uint8Array(a),
      d = c.byteLength;
    for (e = 0; d > e; e++) b += String.fromCharCode(c[e]);
    return window.btoa(b)
  }
  function base64ToArrayBuffer(a) {
    var e, b = window.atob(a),
      c = b.length,
      d = new Uint8Array(c);
    for (e = 0; c > e; e++) d[e] = b.charCodeAt(e);
    return d.buffer
  }
  function timeoutrun() {
    $.post("/deviceinfo", "",
      function (a) {
        supportedFormats = a.data && Array.isArray(a.data.script_formats) ? a.data.script_formats : [];
        defaultFormatVersion = a.data && a.data.default_encryption_format_version;
        updateFormatOptions();
        0 == a.code ? $("#zeversion").html(a.data.zeversion) : mdui.snackbar({
          message: XXTI18n.raw(a.message)
        }),
          $("#bform").show(),
          $("#display-message").hide()
      },
      "json").error(function () {
        setTimeout(timeoutrun, 3e3)
      })
  }
  function up_file(files) {
    var fileloaded, reader, _file = files[0];
    var selected = $("#format_version").val();
    var formatVersion = selected === "default" ? undefined : Number(selected);
    var isXUI = /\.xui$/i.test(_file.name);
    if (!isXUI && formatVersion === 4 && supportedFormats.indexOf(4) < 0) {
      mdui.alert("请升级 X.X.T. 后再生成 v4 格式的脚本");
      return;
    }
    _file.size > 31457280 ? mdui.alert("脚本大于30M不允许加密") : ($("#display-message").show(), $("#bform").hide(), fileloaded = 0, reader = new FileReader, reader.readAsBinaryString(_file), reader.onload = function () {
      XMLHttpRequest.prototype.sendAsBinary || (XMLHttpRequest.prototype.sendAsBinary = function (a) {
        function b(a) {
          return 255 & a.charCodeAt(0)
        }
        var c = Array.prototype.map.call(a, b),
          d = new Uint8Array(c);
        this.send(d.buffer)
      });
      var xhr = new XMLHttpRequest;
      xhr.open("POST", "encript"),
        xhr.timeout = 60000,
        xhr.onerror = xhr.ontimeout = xhr.onabort = function () {
          $("#display-message").hide();
          $("#bform").show();
          mdui.alert("连接服务失败，请稍后重试");
        },
        xhr.overrideMimeType("application/octet-stream"),
        isXUI ? xhr.setRequestHeader("args", JSON.stringify({
          xuic: !0,
          filename: encodeURI(_file.name.replace(/(.*\/)*([^.]+).*/gi, "$2"))
        })) : xhr.setRequestHeader("args", JSON.stringify({
          format_version: formatVersion,
          no_strip: (formatVersion === 3 || formatVersion === undefined) && $("#no_strip").is(":checked"),
          filename: encodeURI(GetFileNameNoExt(_file.name)),
          entitlements: {
            "allow-external-require": $("#allow_external_require").is(":checked")
          }
        })),
        xhr.responseType = "blob",
        xhr.sendAsBinary(reader.result),
        xhr.onreadystatechange = function () {
          if (xhr.readyState === 4 && xhr.status === 0) return;
          4 == xhr.readyState && (200 == xhr.status ? (parseBlobJson(xhr.response, function (json) {
            if (!isXUI && (!json || !json.data ||
              typeof json.data.format_version !== "number" ||
              supportedFormats.indexOf(json.data.format_version) < 0 || json.data.format_version < 3 ||
              (formatVersion !== undefined && json.data.format_version !== formatVersion))) {
              mdui.alert("生成的脚本格式与请求不一致，请升级 X.X.T. 后重试");
              return;
            }
            json && json.data && json.data.download_uri ? location.href = json.data.download_uri : mdui.snackbar({
              message: "出现一个错误"
            })
          }),
            $("#display-message").hide(), $("#bform").show()) : (parseBlobJson(xhr.response, function (json) {
              mdui.alert(getEncryptErrorMessage(json)),
                $("#display-message").hide(),
                $("#bform").show()
            })))
        }
    })
  }
  $("#main-drawer a[href='./encript.html']").addClass("mdui-list-item-active"),
    $("#choose_file_upgrade").click(function () {
      var a = $('<input type="file" style="display:none" name="upload"/>');
      a.change(function (a) {
        up_file(a.target.files)
      }),
        a.click()
    });
  var dropbox = document.getElementById("dropbox");
  document.addEventListener("dragenter",
    function () {
      dropbox.style.borderColor = "gray"
    },
    !1),
    document.addEventListener("dragleave",
      function () {
        dropbox.style.borderColor = "silver"
      },
      !1),
    dropbox.addEventListener("dragenter",
      function () {
        dropbox.style.borderColor = "gray",
          dropbox.style.backgroundColor = "white"
      },
      !1),
    dropbox.addEventListener("dragleave",
      function () {
        dropbox.style.backgroundColor = "transparent"
      },
      !1),
    dropbox.addEventListener("dragenter",
      function (a) {
        a.stopPropagation(),
          a.preventDefault()
      },
      !1),
    dropbox.addEventListener("dragover",
      function (a) {
        a.stopPropagation(),
          a.preventDefault()
      },
      !1),
    dropbox.addEventListener("drop",
      function (a) {
        a.stopPropagation(),
          a.preventDefault(),
          handleFiles(a.dataTransfer.files)
      },
      !1),
    $("#no_strip").on("click",
      function () {
        switch (this.checked) {
          case !0: $(".xxtouch-tip").css("color", "#FF0000");
            break;
          case !1: $(".xxtouch-tip").css("color", "rgba(0,0,0,.54)")
        }
      }),
    handleFiles = function (a) {
      up_file(a)
    }
  timeoutrun();
});
