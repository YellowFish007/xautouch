local json = require "cjson.safe"
local lfs = require "lfs"
local socket = require('socket')
local localization = require "localization"
local udp_recieve_port = 35452

local runtime_profile = rawget(_G, "XXT_RUNTIME_PROFILE")
local XXT_HOME_PATH = rawget(_G, "XXT_HOME_PATH") or
    (type(runtime_profile) == "table" and runtime_profile.home) or os.getenv("XXT_HOME_PATH")
assert(type(XXT_HOME_PATH) == "string" and XXT_HOME_PATH ~= "", "XXT runtime profile is unavailable")
local runtime_ports = type(XXT_RUNTIME_PORTS) == "table" and XXT_RUNTIME_PORTS or {}
local cc_path = XXT_HOME_PATH .. "/cc"

sys.mkdir_p(cc_path .. '/data')
sys.mkdir_p(cc_path .. '/log')

function sys.msleep(n) socket.select(nil, nil, n / 1000) end

function sys.sleep(n) socket.select(nil, nil, n) end

--[[建立UDP通讯]]
local udp_service = socket.udp4()
udp_service:settimeout(0)
udp_service:setsockname('*', udp_recieve_port)

--[[创建用于储存的列表]]
local devices = {}
local cc_catalogs = {
  en = {
    ["无"] = "None",
    ["超时"] = "Timed out",
    ["请把所有设备升级高版本 X.X.T.。"] = "Please update XXTouch on all devices.",
    ["批量授权错误"] = "Batch Authorization Error",
    ["授权成功"] = "Authorization successful",
    ["设备访问超时"] = "Device access timed out",
    ["授权成功:"] = "Authorized:",
    ["出错设备:"] = "Devices with errors:",
    ["出错授权码:"] = "Authorization codes with errors:",
    ["未使用授权码:"] = "Unused authorization codes:",
    ["记录已储存在\"{path}\""] = "The record was saved to \"{path}\"",
    ["批量授权结果"] = "Batch Authorization Results",
    ["清理成功"] = "Cleared successfully",
    ["操作成功"] = "Operation successful",
    ["操作失败"] = "Operation failed",
    ["不存在\"{method}\"命令"] = "The \"{method}\" command does not exist",
  },
  ["zh-Hant"] = {
    ["无"] = "無",
    ["超时"] = "逾時",
    ["请把所有设备升级高版本 X.X.T.。"] = "請將所有裝置的 X.X.T. 更新至較新版本。",
    ["批量授权错误"] = "批次授權錯誤",
    ["授权成功"] = "授權成功",
    ["设备访问超时"] = "裝置存取逾時",
    ["授权成功:"] = "授權成功：",
    ["出错设备:"] = "發生錯誤的裝置：",
    ["出错授权码:"] = "發生錯誤的授權碼：",
    ["未使用授权码:"] = "未使用的授權碼：",
    ["记录已储存在\"{path}\""] = "記錄已儲存至「{path}」",
    ["批量授权结果"] = "批次授權結果",
    ["清理成功"] = "清理成功",
    ["操作成功"] = "操作成功",
    ["操作失败"] = "操作失敗",
    ["不存在\"{method}\"命令"] = "不存在「{method}」指令",
  },
  vi = {
    ["无"] = "Không có",
    ["超时"] = "Hết thời gian",
    ["请把所有设备升级高版本 X.X.T.。"] = "Vui lòng cập nhật XXTouch trên tất cả thiết bị.",
    ["批量授权错误"] = "Lỗi ủy quyền hàng loạt",
    ["授权成功"] = "Ủy quyền thành công",
    ["设备访问超时"] = "Truy cập thiết bị hết thời gian",
    ["授权成功:"] = "Ủy quyền thành công:",
    ["出错设备:"] = "Thiết bị gặp lỗi:",
    ["出错授权码:"] = "Mã ủy quyền gặp lỗi:",
    ["未使用授权码:"] = "Mã ủy quyền chưa dùng:",
    ["记录已储存在\"{path}\""] = "Bản ghi đã được lưu tại \"{path}\"",
    ["批量授权结果"] = "Kết quả ủy quyền hàng loạt",
    ["清理成功"] = "Đã xóa thành công",
    ["操作成功"] = "Thao tác thành công",
    ["操作失败"] = "Thao tác thất bại",
    ["不存在\"{method}\"命令"] = "Lệnh \"{method}\" không tồn tại",
  },
  ja = {
    ["无"] = "なし",
    ["超时"] = "タイムアウト",
    ["请把所有设备升级高版本 X.X.T.。"] = "すべてのデバイスの XXTouch を新しいバージョンへ更新してください。",
    ["批量授权错误"] = "一括認証エラー",
    ["授权成功"] = "認証しました",
    ["设备访问超时"] = "デバイスへのアクセスがタイムアウトしました",
    ["授权成功:"] = "認証成功：",
    ["出错设备:"] = "エラーが発生したデバイス：",
    ["出错授权码:"] = "エラーが発生した認証コード：",
    ["未使用授权码:"] = "未使用の認証コード：",
    ["记录已储存在\"{path}\""] = "記録を「{path}」に保存しました",
    ["批量授权结果"] = "一括認証結果",
    ["清理成功"] = "消去しました",
    ["操作成功"] = "操作に成功しました",
    ["操作失败"] = "操作に失敗しました",
    ["不存在\"{method}\"命令"] = "「{method}」コマンドは存在しません",
  },
  ko = {
    ["无"] = "없음",
    ["超时"] = "시간 초과",
    ["请把所有设备升级高版本 X.X.T.。"] = "모든 기기의 XXTouch를 최신 버전으로 업데이트하세요.",
    ["批量授权错误"] = "일괄 인증 오류",
    ["授权成功"] = "인증 성공",
    ["设备访问超时"] = "기기 접근 시간 초과",
    ["授权成功:"] = "인증 성공:",
    ["出错设备:"] = "오류가 발생한 기기:",
    ["出错授权码:"] = "오류가 발생한 인증 코드:",
    ["未使用授权码:"] = "사용하지 않은 인증 코드:",
    ["记录已储存在\"{path}\""] = "기록을 \"{path}\"에 저장했습니다",
    ["批量授权结果"] = "일괄 인증 결과",
    ["清理成功"] = "정리했습니다",
    ["操作成功"] = "작업 성공",
    ["操作失败"] = "작업 실패",
    ["不存在\"{method}\"命令"] = "\"{method}\" 명령이 없습니다",
  },
  es = {
    ["无"] = "Ninguno", ["超时"] = "Tiempo agotado", ["请把所有设备升级高版本 X.X.T.。"] = "Actualiza XXTouch en todos los dispositivos.",
    ["批量授权错误"] = "Error de autorización por lotes", ["授权成功"] = "Autorización correcta", ["设备访问超时"] = "Se agotó el tiempo de acceso al dispositivo",
    ["授权成功:"] = "Autorizados:", ["出错设备:"] = "Dispositivos con errores:", ["出错授权码:"] = "Códigos de autorización con errores:",
    ["未使用授权码:"] = "Códigos de autorización sin usar:", ["记录已储存在\"{path}\""] = "El registro se guardó en \"{path}\"",
    ["批量授权结果"] = "Resultados de autorización por lotes", ["清理成功"] = "Limpieza completada", ["操作成功"] = "Operación correcta",
    ["操作失败"] = "La operación falló", ["不存在\"{method}\"命令"] = "El comando \"{method}\" no existe",
  },
  ["pt-BR"] = {
    ["无"] = "Nenhum", ["超时"] = "Tempo esgotado", ["请把所有设备升级高版本 X.X.T.。"] = "Atualize o XXTouch em todos os dispositivos.",
    ["批量授权错误"] = "Erro de autorização em lote", ["授权成功"] = "Autorização concluída", ["设备访问超时"] = "O acesso ao dispositivo expirou",
    ["授权成功:"] = "Autorizados:", ["出错设备:"] = "Dispositivos com erro:", ["出错授权码:"] = "Códigos de autorização com erro:",
    ["未使用授权码:"] = "Códigos de autorização não usados:", ["记录已储存在\"{path}\""] = "O registro foi salvo em \"{path}\"",
    ["批量授权结果"] = "Resultados da autorização em lote", ["清理成功"] = "Limpeza concluída", ["操作成功"] = "Operação concluída",
    ["操作失败"] = "Falha na operação", ["不存在\"{method}\"命令"] = "O comando \"{method}\" não existe",
  },
  ru = {
    ["无"] = "Нет", ["超时"] = "Время ожидания истекло", ["请把所有设备升级高版本 X.X.T.。"] = "Обновите XXTouch на всех устройствах.",
    ["批量授权错误"] = "Ошибка пакетной авторизации", ["授权成功"] = "Авторизация выполнена", ["设备访问超时"] = "Время доступа к устройству истекло",
    ["授权成功:"] = "Авторизовано:", ["出错设备:"] = "Устройства с ошибками:", ["出错授权码:"] = "Коды авторизации с ошибками:",
    ["未使用授权码:"] = "Неиспользованные коды авторизации:", ["记录已储存在\"{path}\""] = "Запись сохранена в \"{path}\"",
    ["批量授权结果"] = "Результаты пакетной авторизации", ["清理成功"] = "Очистка выполнена", ["操作成功"] = "Операция выполнена",
    ["操作失败"] = "Операция не выполнена", ["不存在\"{method}\"命令"] = "Команда \"{method}\" не существует",
  },
  fr = {
    ["无"] = "Aucun", ["超时"] = "Délai dépassé", ["请把所有设备升级高版本 X.X.T.。"] = "Mettez à jour XXTouch sur tous les appareils.",
    ["批量授权错误"] = "Erreur d’autorisation groupée", ["授权成功"] = "Autorisation réussie", ["设备访问超时"] = "Délai d’accès à l’appareil dépassé",
    ["授权成功:"] = "Autorisés :", ["出错设备:"] = "Appareils en erreur :", ["出错授权码:"] = "Codes d’autorisation en erreur :",
    ["未使用授权码:"] = "Codes d’autorisation inutilisés :", ["记录已储存在\"{path}\""] = "L’enregistrement a été sauvegardé dans \"{path}\"",
    ["批量授权结果"] = "Résultats de l’autorisation groupée", ["清理成功"] = "Nettoyage réussi", ["操作成功"] = "Opération réussie",
    ["操作失败"] = "Échec de l’opération", ["不存在\"{method}\"命令"] = "La commande \"{method}\" n’existe pas",
  },
  de = {
    ["无"] = "Keine", ["超时"] = "Zeitüberschreitung", ["请把所有设备升级高版本 X.X.T.。"] = "Aktualisiere XXTouch auf allen Geräten.",
    ["批量授权错误"] = "Fehler bei der Sammelautorisierung", ["授权成功"] = "Autorisierung erfolgreich", ["设备访问超时"] = "Zeitüberschreitung beim Gerätezugriff",
    ["授权成功:"] = "Autorisiert:", ["出错设备:"] = "Fehlerhafte Geräte:", ["出错授权码:"] = "Fehlerhafte Autorisierungscodes:",
    ["未使用授权码:"] = "Nicht verwendete Autorisierungscodes:", ["记录已储存在\"{path}\""] = "Der Datensatz wurde unter \"{path}\" gespeichert",
    ["批量授权结果"] = "Ergebnisse der Sammelautorisierung", ["清理成功"] = "Bereinigung erfolgreich", ["操作成功"] = "Vorgang erfolgreich",
    ["操作失败"] = "Vorgang fehlgeschlagen", ["不存在\"{method}\"命令"] = "Der Befehl \"{method}\" ist nicht vorhanden",
  },
}

local function localized(language, key, values)
  local catalog = cc_catalogs[language]
  local result = (catalog and catalog[key]) or key
  if type(values) == "table" then
    for name, value in pairs(values) do
      result = result:gsub("{" .. name .. "}", function() return tostring(value) end)
    end
  end
  return result
end

local stable_authorization_log_messages = {
  [-2] = "授权码无效或已被使用，请检查您的输入是否完全正确。",
  [-3] = "网络连接错误-3",
  [-8] = "内存不足",
}

local function stable_authorization_log_message(response)
  return stable_authorization_log_messages[tonumber(response.code)] or tostring(response.message or "")
end

local function remote_state_fallback_key(response)
  return tonumber(response.code) == 0 and "操作成功" or "操作失败"
end

local function request_headers(language, headers)
  headers = headers or {}
  headers[#headers + 1] = "Accept-Language: " .. language
  return headers
end

local function set_message_state(device, key)
  device.state_key = key
  device.state_fallback_key = nil
  device.state_by_language = {}
end

local function set_remote_state(device, language, message, fallback_key)
  device.state_key = nil
  device.state_fallback_key = fallback_key or "操作失败"
  device.state_by_language = { [language] = message }
end

local function set_shared_state(device, message)
  device.state_key = nil
  device.state_fallback_key = nil
  device.state_by_language = { ["*"] = message }
end

local function state_for_language(device, language)
  local states = device.state_by_language or {}
  return states[language] or states["*"] or
    localized(language, device.state_fallback_key or device.state_key or "无")
end

local function device_for_language(device, language)
  local result = {}
  for key, value in pairs(device) do
    if key ~= "state_key" and key ~= "state_fallback_key" and key ~= "state_by_language" then
      result[key] = value
    end
  end
  result.state = state_for_language(device, language)
  return result
end

local http = {
  get = (function(host, port, path)
    local socket = require "socket"
    local socket_http = require "socket.http"
    socket_http.TIMEOUT = 5
    local ltn12 = require("ltn12")
    local response_body = {}
    local rep, code = socket_http.request {
      url = string.format("http://%s:%s/%s", host, port, path),
      method = "GET",
      sink = ltn12.sink.table(response_body),
    }
    return code, string.format('%s', response_body[1])
  end),
  post = (function(host, port, path, data, connect_timeout, timeout, headers)
    local curl = require("curl.safe")
    headers = (type(headers) == "table" and headers) or {}
    connect_timeout = (type(connect_timeout) == "number" and connect_timeout) or 2
    timeout = (type(timeout) == "number" and timeout) or 2

    local buffer = {}
    local function writef(s)
      buffer[#buffer + 1] = s
    end
    local code = 0
    pcall(function()
      local c = curl.easy()
          :setopt(curl.OPT_URL, string.format("http://%s:%s/%s", host, port, path))
          :setopt(curl.OPT_CONNECTTIMEOUT, connect_timeout)
          :setopt(curl.OPT_TIMEOUT, timeout)

      if (#headers > 0) then
        c:setopt_httpheader(headers)
      end

      c:setopt_postfields(data)
          :setopt_writefunction(writef)
          :perform()

      code = c:getinfo(curl.INFO_RESPONSE_CODE)
      c:close()
    end)

    local body

    if (code == 0) then
      code = -1
    else
      body = table.concat(buffer)
    end
    return math.floor(code), body
  end)
}

local search_device = function()
  local config_json = {}
  local f = io.open(XXT_CONF_FILE_NAME or (XXT_HOME_PATH .. "/1ferver.conf"), 'r')
  if f then
    config_json = json.decode(f:read("*a")) or {}
    f:close()
  end
  local device_port = tonumber(runtime_ports.port) or
    (type(sys.port) == "function" and tonumber(sys.port())) or
    tonumber(config_json.port) or 46952
  local discovery_port = tonumber(runtime_ports.udp_port) or tonumber(config_json.udp_port) or 46953

  local severlist = {}
  local ip, resolved = socket.dns.toip(socket.dns.gethostname())
  local code, device_info = http.post("127.0.0.1", device_port, "deviceinfo", "", "")
  if not device_info then return end
  local info_json = json.decode(device_info)
  local ip = info_json['data']['wifi_ip']
  local sender = socket.udp4()
  sender:setsockname(ip, math.random(40000, 60000))
  sender:setoption("broadcast", true)
  sender:sendto('{"ip":"' .. ip .. '","port":' .. udp_recieve_port .. '}', "255.255.255.255", discovery_port)
  sender:close()
  while true do
    local receive = udp_service:receivefrom()
    if receive then
      local device_json = json.decode(receive)
      if not devices[device_json['deviceid']] then
        device_json.check = false
        set_message_state(device_json, "无")
        device_json.log = {}
        devices[device_json['deviceid']] = device_json
      end
    else
      break
    end
  end
end

local selected_script_file = ''

--[[/var/mobile/Media/1ferver/bin/1ferver dofile /var/mobile/Media/1ferver/bin/WebSocket_CC.lua]]

local ev = require 'ev'
local loop = ev.Loop.default
local websocket = require 'websocket'
local server = websocket.server.ev.listen
    {
      protocols = {
        ['XXTouch-CC-Web'] = function(ws)
          ws:on_message(
            function(ws, message, opcode)
              if opcode ~= websocket.TEXT then return end
              local jobj = json.decode(message)
              if type(jobj) ~= 'table' then return end
              local language = localization.normalize(jobj.language)
              local web_log = function(_type, msg, title)
                ws:send(
                  json.encode(
                    {
                      method = 'web_log',
                      type = _type,
                      message = msg,
                      title = title
                    }
                  )
                )
              end

              local method = {
                ['getlog'] = function() --[[日志]]
                  --[[
								{"method":"log"}
								{"method":"log","devices":{"e27ce83a6955959eea72d53f07fcc5c1ec5bfd54":"Fuck"}}
							--]]
                  local log = {}
                  for deviceid, info in pairs(devices) do
                    log[deviceid] = {
                      state = state_for_language(info, language),
                      log = info.log
                    }
                  end
                  ws:send(
                    json.encode(
                      {
                        ['method'] = 'log',
                        ['devices'] = log
                      }
                    )
                  )
                end,
                ['check_devices'] = function() --[[勾选设备]]
                  --[[
								{"method":"check_devices"}
								{"method":"check_devices","devices":["e27ce83a6955959eea72d53f07fcc5c1ec5bfd54"]}
							--]]
                  for _, d_info in pairs(devices) do d_info.check = false end
                  for _, deviceid in pairs(jobj["deviceid"]) do
                    if devices[deviceid] then
                      devices[deviceid].check = true
                    end
                  end
                end,
                ['search'] = function() --[[扫描]]
                  --[[
								{"method":"search"}
								{"method":"search","devices":{"e27ce83a6955959eea72d53f07fcc5c1ec5bfd54":{xxxxxxxxxxxxxxxxxxxx}}}
							--]]
                  search_device()
                  local localized_devices = {}
                  for deviceid, info in pairs(devices) do
                    localized_devices[deviceid] = device_for_language(info, language)
                  end
                  ws:send(
                    json.encode(
                      {
                        ['method'] = 'devices',
                        ['devices'] = localized_devices
                      }
                    )
                  )
                end,
                ['spawn'] = function() --[[运行]]
                  --[[
								{
									"method":"spawn",
									"deviceid":["e27ce83a6955959eea72d53f07fcc5c1ec5bfd54"],
									"args": {
										"server_ip":"10.0.0.88"
									},
									"script_data":""
								}
							--]]
                  local script_byte = jobj['script_hex']:from_hex()
                  local spawn_args = jobj['args'] or {}
                  for _, deviceid in pairs(jobj['deviceid']) do
                    if devices[deviceid] then
                      local ip = devices[deviceid]['ip']
                      local port = devices[deviceid]['port']
                      local code, receive_message = http.post(ip, port, "spawn", script_byte, nil, nil,
                        request_headers(language, { "spawn_args: " .. json.encode(spawn_args) }))
                      local receive_message_json = json.decode(receive_message)
                      if type(receive_message_json) == 'table' then
                        set_remote_state(devices[deviceid], language, receive_message_json.message,
                          remote_state_fallback_key(receive_message_json))
                      else
                        set_message_state(devices[deviceid], '超时')
                      end
                    end
                  end
                end,
                ['recycle'] = function() --[[停止]]
                  --[[
								{
									"method":"spawn",
									"deviceid":["e27ce83a6955959eea72d53f07fcc5c1ec5bfd54"]
								}
							--]]
                  for _, deviceid in pairs(jobj['deviceid']) do
                    if devices[deviceid] then
                      local ip = devices[deviceid]['ip']
                      local port = devices[deviceid]['port']
                      local code, receive_message = http.post(ip, port, "recycle", "", nil, nil,
                        request_headers(language))
                      local receive_message_json = json.decode(receive_message)
                      if type(receive_message_json) == 'table' then
                        set_remote_state(devices[deviceid], language, receive_message_json.message,
                          remote_state_fallback_key(receive_message_json))
                      else
                        set_message_state(devices[deviceid], '超时')
                      end
                    end
                  end
                end,
                ['send_file'] = function() --[[发送文件]]
                  --[[
								{
									"method":"send_file",
									"deviceid":[
										"e27ce83a6955959eea72d53f07fcc5c1ec5bfd54"
									],
									"path":"/",
									"file":[
										"xxx.xxt":"十六进制"
									]
								}
							--]]
                  for _, deviceid in pairs(jobj['deviceid']) do
                    if devices[deviceid] then
                      local ip = devices[deviceid]['ip']
                      local port = devices[deviceid]['port']
                      for file_name, file_data in pairs(jobj['file']) do
                        local send_data = json.encode(
                          {
                            ['filename'] = jobj['path'] .. '/' .. file_name,
                            ['data'] = file_data:from_hex():base64_encode(),
                          }
                        )
                        local code, receive_message = http.post(ip, port, "write_file", send_data, nil, nil,
                          request_headers(language))
                        local receive_message_json = json.decode(receive_message)
                        if type(receive_message_json) == 'table' then
                          set_remote_state(devices[deviceid], language, receive_message_json.message,
                            remote_state_fallback_key(receive_message_json))
                        else
                          set_message_state(devices[deviceid], '超时')
                        end
                      end
                    end
                  end
                end,
                ['detect.auth'] = function() --[[检测授权]]
                  --[[
								{
									"method":"auth",
									"deviceid":[
										"e27ce83a6955959eea72d53f07fcc5c1ec5bfd54"
									]
								}
							--]]
                  for _, deviceid in pairs(jobj['deviceid']) do
                    if devices[deviceid] then
                      local ip = devices[deviceid]['ip']
                      local port = devices[deviceid]['port']
                      local _, receive_message = http.post(ip, port, "device_auth_info", "", nil, nil,
                        request_headers(language))
                      local receive_message_json = json.decode(receive_message)
                      if type(receive_message_json) == 'table' then
                        local b_timeout = (receive_message_json.data.expireDate - receive_message_json.data.nowDate) <= 0
                        local expire_date_text = os.date("%Y/%m/%d %H:%M:%S", receive_message_json.data.expireDate)
                        if b_timeout then
                          set_shared_state(devices[deviceid], [[<span style="color:red;">]] .. expire_date_text .. [[</span>]])
                        else
                          set_shared_state(devices[deviceid], [[<span style="color:blue;">]] .. expire_date_text .. [[</span>]])
                        end
                      else
                        set_message_state(devices[deviceid], '超时')
                      end
                    end
                  end
                end,
                ['auth'] = function() --[[批量授权]]
                  --[[
								{
									"method":"auth",
									"additional":true;
									"deviceid":[
										"e27ce83a6955959eea72d53f07fcc5c1ec5bfd54"
									],
									"code":[
										"十六位授权码"
									]
								}
							--]]
                  local code_index = 1
                  local device_index = 1
                  local _success = {}
                  local _device_error = {}
                  local _key_error = {}
                  local _device_error_log = {}
                  local _key_error_log = {}
                  local _code = jobj['code']


                  for _, deviceid in pairs(jobj['deviceid']) do
                    if devices[deviceid] then
                      if string.compare_version(devices[deviceid].tsversion, '1.3.8-20250428120000') < 0 then
                        web_log('message', localized(language, "请把所有设备升级高版本 X.X.T.。"),
                          localized(language, "批量授权错误"))
                        return
                      end
                    end
                  end

                  while true do
                    --[[防止超出范围]]
                    if device_index > #(jobj['deviceid']) or code_index > #(jobj['code']) then break end
                    local deviceid = jobj['deviceid'][device_index]
                    local device = devices[deviceid]
                    local code = _code[code_index]

                    if not device then
                      table.insert(_device_error,
                        string.format("%s\t\t%s", deviceid, localized(language, "设备访问超时")))
                      table.insert(_device_error_log, string.format("%s\t\t设备访问超时", deviceid))
                      device_index = device_index + 1
                    else
                      local _, receive_message = http.post(
                        device.ip,
                        device.port,
                        "bind_code",
                        string.format(
                          "code=%s&mustbeless=%s",
                          code,
                          ((jobj.mustbeless and 0) or 7 * 24 * 3600)
                        ),
                        nil,
                        nil,
                        request_headers(language)
                      )
                      local receive_json = json.decode(receive_message)
                      if type(receive_json) == 'table' then
                        if receive_json.code == 0 then
                          --[[授权成功]]
                          table.insert(_success, string.format("%s\t%s\t%s", deviceid, device.devsn, code))
                          set_message_state(device, '授权成功')
                          device_index = device_index + 1
                          code_index = code_index + 1
                        elseif receive_json.code == 1 then
                          --[[链接服务器异常]]
                          table.insert(_device_error,
                            string.format("%s\t%s\t%s", deviceid, device.devsn, receive_json.message))
                          table.insert(_device_error_log,
                            string.format("%s\t%s\t%s", deviceid, device.devsn,
                              stable_authorization_log_message(receive_json)))
                          set_remote_state(device, language, receive_json.message,
                            remote_state_fallback_key(receive_json))
                          device_index = device_index + 1
                        elseif receive_json.code > 1 then
                          --[[服务器异常]]
                          table.insert(_device_error,
                            string.format("%s\t%s\t%s", deviceid, device.devsn, receive_json.message))
                          table.insert(_device_error_log,
                            string.format("%s\t%s\t%s", deviceid, device.devsn,
                              stable_authorization_log_message(receive_json)))
                          set_remote_state(device, language, receive_json.message,
                            remote_state_fallback_key(receive_json))
                          device_index = device_index + 1
                        elseif receive_json.code == -9 then
                          --[[设备授权时间超过规定时间范围外]]
                          table.insert(_device_error,
                            string.format("%s\t%s\t%s", deviceid, device.devsn, receive_json.message))
                          table.insert(_device_error_log,
                            string.format("%s\t%s\t%s", deviceid, device.devsn,
                              stable_authorization_log_message(receive_json)))
                          set_remote_state(device, language, receive_json.message,
                            remote_state_fallback_key(receive_json))
                          device_index = device_index + 1
                        elseif receive_json.code ~= -9 and receive_json.code < 0 then
                          --[[key有问题]]
                          table.insert(_key_error, string.format("%s\t%s", code, receive_json.message))
                          table.insert(_key_error_log,
                            string.format("%s\t%s", code, stable_authorization_log_message(receive_json)))
                          set_remote_state(device, language, receive_json.message,
                            remote_state_fallback_key(receive_json))
                          code_index = code_index + 1
                        end
                      else
                        table.insert(_device_error,
                          string.format("%s\t%s\t%s", deviceid, device.devsn,
                            localized(language, "设备访问超时")))
                        table.insert(_device_error_log,
                          string.format("%s\t%s\t设备访问超时", deviceid, device.devsn))
                        set_message_state(device, "设备访问超时")
                        device_index = device_index + 1
                      end
                    end
                  end

                  local unused = {}
                  for i = code_index, #_code do
                    table.insert(unused, _code[i])
                  end
                  local now_str = os.date("%Y/%m/%d %H:%M:%S", os.time())
                  local log_message = table.concat(
                    {
                      now_str,
                      "授权成功:",
                      table.concat(_success, '\r\n'),
                      "出错设备:",
                      table.concat(_device_error_log, '\r\n'),
                      "出错授权码:",
                      table.concat(_key_error_log, '\r\n'),
                      "未使用授权码:",
                      table.concat(unused, '\r\n'),
                      "==================================================================="
                    },
                    '\r\n'
                  )
                  local display_message = table.concat(
                    {
                      now_str,
                      localized(language, "授权成功:"),
                      table.concat(_success, '\r\n'),
                      localized(language, "出错设备:"),
                      table.concat(_device_error, '\r\n'),
                      localized(language, "出错授权码:"),
                      table.concat(_key_error, '\r\n'),
                      localized(language, "未使用授权码:"),
                      table.concat(unused, '\r\n'),
                      "==================================================================="
                    },
                    '\r\n'
                  )
                  local f = io.open(cc_path .. "/log/授权记录.log", 'a')
                  f:write(log_message .. '\r\n')
                  f:close()
                  web_log('message', display_message .. "\r\n" .. localized(language, "记录已储存在\"{path}\"", {
                    path = cc_path .. "/log/授权记录.log"
                  }), localized(language, "批量授权结果"))
                end,
                ['clear.log'] = function() --[[清理日志]]
                  --[[
								{"method":"clear.log","devices":["e27ce83a6955959eea72d53f07fcc5c1ec5bfd54"]}
							--]]
                  for _, deviceid in pairs(jobj['deviceid']) do
                    if devices[deviceid] then
                      devices[deviceid].log = {}
                      set_message_state(devices[deviceid], "清理成功")
                    end
                  end
                end,
                ['quit'] = function() --[[退出监听]]
                  os.exit()
                end,
              }
              if method[jobj['method']] then
                method[jobj['method']]();
              else
                web_log('error', localized(language, '不存在"{method}"命令', { method = jobj['method'] }))
              end
            end
          )
          ws:on_close(
            function()

            end
          )
        end,
        ['XXTouch-CC-Client'] = function(ws)
          ws:on_message(
            function(ws, message, opcode)
              if opcode ~= websocket.TEXT then return end
              local jobj = json.decode(message)
              if type(jobj) ~= 'table' then return end
              local receive = function(s) ws:send(json.encode(s)) end

              local method = {
                ['log'] = function() --[[日志]]
                  if not devices[jobj["deviceid"]] then return end --[[非存在设备]]
                  if not type(jobj["message"]) == 'table' then return end --[[非表]]
                  local t_log = devices[jobj["deviceid"]].log
                  for col, value in pairs(jobj["message"]) do
                    t_log[col] = value
                  end
                end,
                ['run'] = function() --[[中控端运行脚本]]
                  local send = function(msg) ws:send(msg) end
                  local s, err = pcall(load(jobj["lua_script"]))
                  receive(
                    {
                      ['success'] = s,
                      ['message'] = err
                    }
                  )
                end,
                ['file.exists'] = function() --[[判断文件存在与否]]
                  local attr = lfs.attributes(cc_path .. "/data/" .. jobj["path"])
                  if type(attr) == "table" then
                    receive({ exists = true, mode = attr.mode })
                  else
                    receive({ exists = false })
                  end
                end,
                ['file.take'] = function() --[[读取第一行并删掉]]
                  local f = io.open(cc_path .. "/data/" .. jobj["path"], 'rb')
                  if f then
                    local data = f:read("*a")
                    f:close()
                    local _rn = data:split("\r\n")
                    local _r = data:split("\r")
                    local _n = data:split("\n")
                    local data_table = (#_rn > 1 and _rn) or (#_r > 1 and _r) or (#_n > 1 and _n)
                    local rd = data_table[1]
                    table.remove(data_table, 1)
                    local f = io.open(cc_path .. "/data/" .. jobj["path"], 'rb')
                    f:write(table.concat(data_table, '\r\n'))
                    f:close()
                    receive({ data = rd:to_hex(), exists = true })
                  else
                    receive({ exists = false })
                  end
                end,
                ['file.reads'] = function() --[[读取所有内容]]
                  local f = io.open(cc_path .. "/data/" .. jobj["path"], 'rb')
                  if f then
                    local data = f:read("*a")
                    f:close()
                    receive({ data = data:to_hex(), exists = true })
                  else
                    receive({ exists = false })
                  end
                end,
                ['file.writes'] = function() --[[写入文件]]
                  local f = io.open(cc_path .. "/data/" .. jobj["path"], 'wb')
                  if f then
                    f:write((jobj["data"]):from_hex())
                    f:close()
                    receive({ success = true })
                  else
                    receive({ success = false })
                  end
                end,
                ['file.appends'] = function() --[[追加至文件尾部]]
                  local f = io.open(cc_path .. "/data/" .. jobj["path"], 'a')
                  if f then
                    f:write((jobj["data"]):from_hex())
                    f:close()
                    receive({ success = true })
                  else
                    receive({ success = false })
                  end
                end,
              }
              if method[jobj['method']] then
                method[jobj['method']]();
              else
                print("命令不存在")
              end
            end
          )
          ws:on_close(
            function()

            end
          )
        end
      },
      port = 46969
    }

loop:loop()
