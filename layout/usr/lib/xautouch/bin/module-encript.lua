--[[

    本文件仅作为参考，请不要修改本文件
    本文件会在重装、更新时被原版覆盖

--]]

local lfs = require('lfs')
local zip = require('zip')
local noexecute = require('no_os_execute')
local archive = require('archive')
local posix = require('posix')
local path_manager = require('path')
local serpent = require('serpent')
local localization = require('localization')

local response_messages = {
    en = {
        ["operation completed"] = "operation completed", ["operation failed: %s"] = "operation failed: %s",
        ["unknown error"] = "unknown error", ["connection failed"] = "connection failed",
        ["request failed"] = "request failed", ['"/encript_file" api not found'] = '"/encript_file" api not found',
        ["main.lua not found"] = "main.lua not found", ["`%s` is not a file"] = "`%s` is not a file",
        ["failed to read `%s`"] = "failed to read `%s`", ["cannot read `%s`"] = "cannot read `%s`",
        ["`%s` format is not supported"] = "`%s` format is not supported",
        ["`%s` is not a file or directory"] = "`%s` is not a file or directory",
    },
    ["zh-Hans"] = {
        ["operation completed"] = "操作完成", ["operation failed: %s"] = "操作失败：%s",
        ["unknown error"] = "未知错误", ["connection failed"] = "连接失败",
        ["request failed"] = "请求失败", ['"/encript_file" api not found'] = "未找到 /encript_file API",
        ["main.lua not found"] = "未找到 main.lua", ["`%s` is not a file"] = "`%s` 不是文件",
        ["failed to read `%s`"] = "读取 `%s` 失败", ["cannot read `%s`"] = "无法读取 `%s`",
        ["`%s` format is not supported"] = "不支持 `%s` 的格式",
        ["`%s` is not a file or directory"] = "`%s` 不是文件或目录",
    },
    ["zh-Hant"] = {
        ["operation completed"] = "操作完成", ["operation failed: %s"] = "操作失敗：%s",
        ["unknown error"] = "未知錯誤", ["connection failed"] = "連線失敗",
        ["request failed"] = "請求失敗", ['"/encript_file" api not found'] = "找不到 /encript_file API",
        ["main.lua not found"] = "找不到 main.lua", ["`%s` is not a file"] = "`%s` 不是檔案",
        ["failed to read `%s`"] = "讀取 `%s` 失敗", ["cannot read `%s`"] = "無法讀取 `%s`",
        ["`%s` format is not supported"] = "不支援 `%s` 的格式",
        ["`%s` is not a file or directory"] = "`%s` 不是檔案或目錄",
    },
    vi = {
        ["operation completed"] = "Thao tác hoàn tất", ["operation failed: %s"] = "Thao tác thất bại: %s",
        ["unknown error"] = "Lỗi không xác định", ["connection failed"] = "Kết nối thất bại",
        ["request failed"] = "Yêu cầu thất bại", ['"/encript_file" api not found'] = "Không tìm thấy API /encript_file",
        ["main.lua not found"] = "Không tìm thấy main.lua", ["`%s` is not a file"] = "`%s` không phải là tệp",
        ["failed to read `%s`"] = "Không thể đọc `%s`", ["cannot read `%s`"] = "Không thể đọc `%s`",
        ["`%s` format is not supported"] = "Không hỗ trợ định dạng của `%s`",
        ["`%s` is not a file or directory"] = "`%s` không phải là tệp hoặc thư mục",
    },
    ja = {
        ["operation completed"] = "操作が完了しました", ["operation failed: %s"] = "操作に失敗しました：%s",
        ["unknown error"] = "不明なエラー", ["connection failed"] = "接続に失敗しました",
        ["request failed"] = "リクエストに失敗しました", ['"/encript_file" api not found'] = "/encript_file API が見つかりません",
        ["main.lua not found"] = "main.lua が見つかりません", ["`%s` is not a file"] = "`%s` はファイルではありません",
        ["failed to read `%s`"] = "`%s` の読み込みに失敗しました", ["cannot read `%s`"] = "`%s` を読み込めません",
        ["`%s` format is not supported"] = "`%s` の形式はサポートされていません",
        ["`%s` is not a file or directory"] = "`%s` はファイルまたはディレクトリではありません",
    },
    ko = {
        ["operation completed"] = "작업이 완료되었습니다", ["operation failed: %s"] = "작업에 실패했습니다: %s",
        ["unknown error"] = "알 수 없는 오류", ["connection failed"] = "연결에 실패했습니다",
        ["request failed"] = "요청에 실패했습니다", ['"/encript_file" api not found'] = "/encript_file API를 찾을 수 없습니다",
        ["main.lua not found"] = "main.lua를 찾을 수 없습니다", ["`%s` is not a file"] = "`%s`은(는) 파일이 아닙니다",
        ["failed to read `%s`"] = "`%s` 읽기에 실패했습니다", ["cannot read `%s`"] = "`%s`을(를) 읽을 수 없습니다",
        ["`%s` format is not supported"] = "`%s` 형식은 지원되지 않습니다",
        ["`%s` is not a file or directory"] = "`%s`은(는) 파일 또는 디렉터리가 아닙니다",
    },
    es = {
        ["operation completed"] = "Operación completada", ["operation failed: %s"] = "La operación falló: %s",
        ["unknown error"] = "Error desconocido", ["connection failed"] = "Error de conexión",
        ["request failed"] = "La solicitud falló", ['"/encript_file" api not found'] = "No se encontró la API /encript_file",
        ["main.lua not found"] = "No se encontró main.lua", ["`%s` is not a file"] = "`%s` no es un archivo",
        ["failed to read `%s`"] = "No se pudo leer `%s`", ["cannot read `%s`"] = "No se puede leer `%s`",
        ["`%s` format is not supported"] = "El formato de `%s` no es compatible",
        ["`%s` is not a file or directory"] = "`%s` no es un archivo ni un directorio",
    },
    ["pt-BR"] = {
        ["operation completed"] = "Operação concluída", ["operation failed: %s"] = "Falha na operação: %s",
        ["unknown error"] = "Erro desconhecido", ["connection failed"] = "Falha na conexão",
        ["request failed"] = "Falha na solicitação", ['"/encript_file" api not found'] = "API /encript_file não encontrada",
        ["main.lua not found"] = "main.lua não encontrado", ["`%s` is not a file"] = "`%s` não é um arquivo",
        ["failed to read `%s`"] = "Falha ao ler `%s`", ["cannot read `%s`"] = "Não foi possível ler `%s`",
        ["`%s` format is not supported"] = "O formato de `%s` não é compatível",
        ["`%s` is not a file or directory"] = "`%s` não é um arquivo nem diretório",
    },
    ru = {
        ["operation completed"] = "Операция выполнена", ["operation failed: %s"] = "Операция не выполнена: %s",
        ["unknown error"] = "Неизвестная ошибка", ["connection failed"] = "Ошибка подключения",
        ["request failed"] = "Ошибка запроса", ['"/encript_file" api not found'] = "API /encript_file не найден",
        ["main.lua not found"] = "Файл main.lua не найден", ["`%s` is not a file"] = "`%s` не является файлом",
        ["failed to read `%s`"] = "Не удалось прочитать `%s`", ["cannot read `%s`"] = "Невозможно прочитать `%s`",
        ["`%s` format is not supported"] = "Формат `%s` не поддерживается",
        ["`%s` is not a file or directory"] = "`%s` не является файлом или каталогом",
    },
    fr = {
        ["operation completed"] = "Opération terminée", ["operation failed: %s"] = "Échec de l’opération : %s",
        ["unknown error"] = "Erreur inconnue", ["connection failed"] = "Échec de la connexion",
        ["request failed"] = "Échec de la requête", ['"/encript_file" api not found'] = "API /encript_file introuvable",
        ["main.lua not found"] = "main.lua introuvable", ["`%s` is not a file"] = "`%s` n’est pas un fichier",
        ["failed to read `%s`"] = "Échec de la lecture de `%s`", ["cannot read `%s`"] = "Impossible de lire `%s`",
        ["`%s` format is not supported"] = "Le format de `%s` n’est pas pris en charge",
        ["`%s` is not a file or directory"] = "`%s` n’est ni un fichier ni un dossier",
    },
    de = {
        ["operation completed"] = "Vorgang abgeschlossen", ["operation failed: %s"] = "Vorgang fehlgeschlagen: %s",
        ["unknown error"] = "Unbekannter Fehler", ["connection failed"] = "Verbindung fehlgeschlagen",
        ["request failed"] = "Anfrage fehlgeschlagen", ['"/encript_file" api not found'] = "API /encript_file nicht gefunden",
        ["main.lua not found"] = "main.lua nicht gefunden", ["`%s` is not a file"] = "`%s` ist keine Datei",
        ["failed to read `%s`"] = "`%s` konnte nicht gelesen werden", ["cannot read `%s`"] = "`%s` kann nicht gelesen werden",
        ["`%s` format is not supported"] = "Das Format von `%s` wird nicht unterstützt",
        ["`%s` is not a file or directory"] = "`%s` ist weder Datei noch Verzeichnis",
    },
}

local function response_message(key, language)
    return localization.text(response_messages, key, language)
end

local function localize_error_detail(detail, language)
    detail = tostring(detail)
    local exact = response_message(detail, language)
    if exact ~= detail then
        return exact
    end
    local path = detail:match("^`(.-)` is not a file$")
    if path then return string.format(response_message("`%s` is not a file", language), path) end
    path = detail:match("^read `(.-)` failed$")
    if path then return string.format(response_message("failed to read `%s`", language), path) end
    path = detail:match("^can not read `(.-)`$")
    if path then return string.format(response_message("cannot read `%s`", language), path) end
    path = detail:match("^`(.-)` format not support$")
    if path then return string.format(response_message("`%s` format is not supported", language), path) end
    path = detail:match("^`(.-)` is not file or directory$")
    if path then return string.format(response_message("`%s` is not a file or directory", language), path) end
    return detail
end

local function stringify(v, opt)
    opt = type(opt) == 'table' and opt or {}
    opt.comment = false
    opt.nocode = true
    return serpent.block(v, opt)
end

local function tar_extract(tar_path, to_path, uid, gid, mode)
    local arfh, err = io.open(tar_path, 'r')
    if not arfh then
        return false, err
    end
    if not to_path then
        to_path = path_manager.ensure_dir_end(path_manager.splitext(tar_path))
    end
    file.remove(to_path) -- 解包之前删除掉原来的目录
    sys.mkdir_p(to_path)
    uid = uid or 501
    gid = gid or 501
    mode = mode or 755
    local ar = archive.read {
        format = 'tar',
        reader = function(reader)
            return arfh:read(1024 * 1024)
        end,
    }
    for h in ar.next_header, ar do
        local fname = path_manager.basename(h:pathname())
        if not (fname == '.DS_Store' or fname:sub(1, 2) == '._') then
            local filepath = path_manager.join(to_path, h:pathname())
            if posix.S_ISDIR(h:mode()) == 1 then
                sys.mkdir_p(filepath)
            else
                local dir = path_manager.dirname(filepath)
                if not path_manager.isdir(dir) then
                    sys.mkdir_p(dir)
                end
                local f, err = io.open(filepath, 'w')
                if not f then
                    return false, err
                end
                for s in ar.data, ar do
                    f:write(s)
                end
                f:close()
            end
        end
    end
    noexecute.lchownmod_r(to_path, uid, gid, mode)
    return true, to_path
end

function zip_pack(zipfilename, path, vpath)
    vpath = vpath or ""
    local zip_arc, err = zip.open(zipfilename, zip.CREATE | zip.EXCL)
    if not zip_arc then
        return false, err
    end
    if lfs.attributes(path, 'mode') == 'directory' then
        path = path_manager.ensure_dir_end(path)
        path_manager.each(path .. '*', function(v, mode)
            local fn = v:split(path)[2]
            local mode = lfs.symlinkattributes(v, 'mode')
            if mode == 'directory' then
                zip_arc:add_dir(vpath .. fn)
            elseif mode == 'file' then
                zip_arc:add(vpath .. fn, 'file', v)
            else
                -- nLog('skiped:', v)
            end
        end, {
            param = "fm",   -- request full path and mode
            delay = true,   -- use snapshot of directory
            recurse = true, -- include subdirs
        })
    else
        zip_arc:add(path_manager.basename(path), 'file', path)
    end
    zip_arc:close()
    return true
end

local _M = {}

local function decode_json_table(raw)
    if type(raw) == 'table' then
        return raw
    end
    if type(raw) == 'string' and raw ~= '' then
        local decoded = json.decode(raw)
        if type(decoded) == 'table' then
            return decoded
        end
    end
    return nil
end

local function normalize_error_result(raw, fallback_code, fallback_message)
    local ret = decode_json_table(raw)
    if type(ret) == 'table' then
        if type(ret.code) ~= 'number' then
            ret.code = fallback_code or 99
        end
        if type(ret.message) ~= 'string' or ret.message == '' then
            if type(ret.detail) == 'string' and ret.detail ~= '' then
                ret.message = ret.detail
            else
                ret.message = fallback_message or 'unknown error'
            end
        end
        return ret
    end
    local message = fallback_message or 'unknown error'
    if type(raw) == 'string' and raw ~= '' then
        message = raw
    end
    local errtab = {
        code = fallback_code or 99,
        message = message,
    }
    if type(raw) == 'string' and raw ~= '' then
        errtab.detail = raw
    end
    return errtab
end

local function encript_file(in_file, out_file, info, entitlements, encrypt_args)
    local xuic = false
    if in_file:sub(-4) == '.xui' then
        xuic = true
    end
    local format_version = encrypt_args.format_version
    if format_version ~= nil and format_version ~= 3 and format_version ~= 4 then
        return nil, {code = 400, message = 'Unsupported script format version'}
    end
    local metadata_bindings = encrypt_args.metadata_bindings
    if metadata_bindings ~= nil and (type(metadata_bindings) ~= 'table' or format_version == 3 or xuic) then
        return nil, {code = 400, message = 'Metadata bindings require an XXT4 script and a field mapping'}
    end
    if not xuic and format_version == 4 then
        local supported = false
        if get_openapi_func then
            supported = type(xxt_encript4) == 'function'
        else
            local _, _, response = xxtouch.post('/deviceinfo', '{}', '{}')
            local caps = decode_json_table(response)
            local formats = type(caps) == 'table' and type(caps.data) == 'table' and caps.data.script_formats
            if type(formats) == 'table' then
                for _, version in ipairs(formats) do if version == 4 then supported = true end end
            end
        end
        if not supported then return nil, {code = 400, message = 'Upgrade XXTouch to generate XXT4 scripts'} end
    end
    local function verify_output(response)
        if xuic then return out_file end
        local actual_version = type(response.data) == 'table' and response.data.format_version
        local file = io.open(out_file, 'rb')
        local header = file and file:read(5)
        if file then file:close() end
        if type(actual_version) ~= 'number' or actual_version < 3 or actual_version > 255 or
            actual_version % 1 ~= 0 or (format_version ~= nil and actual_version ~= format_version) or
            not header or header ~= string.char(27) .. 'XXT' .. string.char(actual_version) then
            return nil, {code = 400, message = 'Generated script format does not match the request'}
        end
        if metadata_bindings ~= nil then
            local generated = type(response.data) == 'table' and response.data.generation
            if type(generated) ~= 'table' or generated.format_version ~= 4 or
                generated.metadata_bindings_accepted ~= true then
                return nil, {code = 400, message = 'Generated script does not support metadata bindings'}
            end
        end
        return out_file
    end
    local content = json.encode {
        format_version = format_version,
        in_file = in_file,
        out_file = out_file,
        no_strip = true,
        cert = encrypt_args.cert,
        prikey = encrypt_args.prikey,
        metadata_bindings = metadata_bindings,
        xuic = xuic,
        info = type(info) == 'table' and json.encode(info) or nil,
        entitlements = type(entitlements) == 'table' and json.encode(entitlements) or nil,
    }
    if not get_openapi_func then
        local c, h, r = xxtouch.post('/encript_file', '{}', content)
        local ret = decode_json_table(r)
        if type(ret) == 'table' and ret.code == 0 then
            return verify_output(ret)
        end
        if c == -1 then
            return nil, normalize_error_result(ret or r, -1, 'connection failed')
        end
        return nil, normalize_error_result(ret or r, c == 200 and nil or c, 'request failed')
    end
    local api_encript_file = get_openapi_func('/encript_file')
    if type(api_encript_file) ~= "function" then
        return nil, { code = 98, message = '"/encript_file" api not found' }
    end
    local fakectx = {}
    setmetatable(fakectx, {
        __index = function(obj, name)
            if name == 'content' then
                return content
            elseif name == 'header' then
                return function(obj, item) --[[return ctx:header(item)]] end
            elseif name == 'request_method' then
                return 'POST'
            end
        end,
    })
    local r, err = api_encript_file(fakectx)
    if not r then
        return nil, normalize_error_result(err)
    end
    local ret = decode_json_table(r)
    if type(ret) == 'table' and ret.code == 0 then
        return verify_output(ret)
    end
    return nil, normalize_error_result(ret or r)
end

local function is_hidden_path(path)
    local components = path:split('/')
    for _, component in ipairs(components) do
        if component:sub(1, 1) == '.' and component:sub(1, 8) ~= ".jbroot-" then -- roothide 环境中，越狱根有中间隐藏路径
            return true
        end
    end
    return false
end

local function dict_get_keys(dict)
    local keys = {}
    for k, _ in pairs(dict) do
        keys[#keys + 1] = k
    end
    return keys
end

local function read_project_config(dir)
    local conf = file.reads(path_manager.join(dir, '.config'))
    if conf then
        conf = json.decode(conf)
        if type(conf) ~= 'table' then
            conf = nil
        end
    end
    conf = conf or {}
    return conf
end

local function make_long_bracket(data)
    local eq = 1
    while true do
        local close = "]" .. string.rep("=", eq) .. "]"
        if not data:find(close, 1, true) then
            local open = "[" .. string.rep("=", eq) .. "["
            return open .. data .. close
        end
        eq = eq + 1
    end
end

local function read_text_without_utf8_bom(path)
    local data = file.reads(path)
    if type(data) == 'string' and data:sub(1, 3) == string.char(0xEF, 0xBB, 0xBF) then
        data = data:sub(4)
    end
    return data
end

local generated_script_localizer_expression = [====[
(function()
    local catalogs = {
        en = {
            ["This script is recommended to run on XXTouch %s or later."] = "This script is recommended to run on XXTouch %s or later.",
            ["Resource file not found: %s"] = "Resource file not found: %s",
            ["Resource file is invalid: %s"] = "Resource file is invalid: %s",
            ["Script damaged"] = "Script damaged",
        },
        ["zh-Hans"] = {
            ["This script is recommended to run on XXTouch %s or later."] = "当前脚本推荐使用 X.X.T. %s 或更高版本运行。",
            ["Resource file not found: %s"] = "无法找到资源文件：%s",
            ["Resource file is invalid: %s"] = "资源文件不正确：%s",
            ["Script damaged"] = "脚本已损坏",
        },
        ["zh-Hant"] = {
            ["This script is recommended to run on XXTouch %s or later."] = "目前腳本建議使用 X.X.T. %s 或以上版本執行。",
            ["Resource file not found: %s"] = "找不到資源檔案：%s",
            ["Resource file is invalid: %s"] = "資源檔案不正確：%s",
            ["Script damaged"] = "腳本已損壞",
        },
        vi = {
            ["This script is recommended to run on XXTouch %s or later."] = "Nên chạy tập lệnh này trên XXTouch %s trở lên.",
            ["Resource file not found: %s"] = "Không tìm thấy tệp tài nguyên: %s",
            ["Resource file is invalid: %s"] = "Tệp tài nguyên không hợp lệ: %s",
            ["Script damaged"] = "Tập lệnh bị hỏng",
        },
        ja = {
            ["This script is recommended to run on XXTouch %s or later."] = "このスクリプトは XXTouch %s 以降での実行を推奨します。",
            ["Resource file not found: %s"] = "リソースファイルが見つかりません：%s",
            ["Resource file is invalid: %s"] = "リソースファイルが正しくありません：%s",
            ["Script damaged"] = "スクリプトが破損しています",
        },
        ko = {
            ["This script is recommended to run on XXTouch %s or later."] = "이 스크립트는 XXTouch %s 이상에서 실행하는 것이 좋습니다.",
            ["Resource file not found: %s"] = "리소스 파일을 찾을 수 없습니다: %s",
            ["Resource file is invalid: %s"] = "리소스 파일이 올바르지 않습니다: %s",
            ["Script damaged"] = "스크립트가 손상되었습니다",
        },
        es = {
            ["This script is recommended to run on XXTouch %s or later."] = "Se recomienda ejecutar este script en XXTouch %s o posterior.",
            ["Resource file not found: %s"] = "No se encontró el archivo de recursos: %s",
            ["Resource file is invalid: %s"] = "El archivo de recursos no es válido: %s",
            ["Script damaged"] = "El script está dañado",
        },
        ["pt-BR"] = {
            ["This script is recommended to run on XXTouch %s or later."] = "Recomenda-se executar este script no XXTouch %s ou posterior.",
            ["Resource file not found: %s"] = "Arquivo de recursos não encontrado: %s",
            ["Resource file is invalid: %s"] = "Arquivo de recursos inválido: %s",
            ["Script damaged"] = "O script está danificado",
        },
        ru = {
            ["This script is recommended to run on XXTouch %s or later."] = "Рекомендуется запускать этот скрипт в XXTouch %s или новее.",
            ["Resource file not found: %s"] = "Файл ресурса не найден: %s",
            ["Resource file is invalid: %s"] = "Недопустимый файл ресурса: %s",
            ["Script damaged"] = "Скрипт повреждён",
        },
        fr = {
            ["This script is recommended to run on XXTouch %s or later."] = "Il est recommandé d’exécuter ce script sur XXTouch %s ou ultérieur.",
            ["Resource file not found: %s"] = "Fichier de ressources introuvable : %s",
            ["Resource file is invalid: %s"] = "Fichier de ressources non valide : %s",
            ["Script damaged"] = "Le script est endommagé",
        },
        de = {
            ["This script is recommended to run on XXTouch %s or later."] = "Es wird empfohlen, dieses Skript mit XXTouch %s oder neuer auszuführen.",
            ["Resource file not found: %s"] = "Ressourcendatei nicht gefunden: %s",
            ["Resource file is invalid: %s"] = "Ungültige Ressourcendatei: %s",
            ["Script damaged"] = "Das Skript ist beschädigt",
        },
    }
    local ok, localization = pcall(require, "localization")
    if ok and type(localization) == "table" and type(localization.localizer) == "function" then
        return localization.localizer(catalogs)
    end
    return function(key)
        return catalogs["zh-Hans"][key] or catalogs.en[key] or key
    end
end)()
]====]

local function project_merge_files(dir, config_meta)
    dir = path_manager.remove_dir_end(dir)
    config_meta = type(config_meta) == 'table' and config_meta or {}
    local preload_json = not not config_meta.preload_json
    local list = file.list(dir, true) or {}
    local relative_paths = {}
    local main_path
    local is_classic_xxt_format = false
    for _, full_path in ipairs(list) do
        if lfs.attributes(full_path, 'mode') ~= 'file' then
            goto continue
        end
        local path = full_path:sub(#dir + 2)
        if #path <= 0 or is_hidden_path(path) then
            goto continue
        end
        if path == 'main.lua' then
            if main_path then
                relative_paths[#relative_paths + 1] = main_path
            end
            is_classic_xxt_format = false
            main_path = path
            goto continue
        end
        if not main_path and path == 'lua/scripts/main.lua' then
            is_classic_xxt_format = true
            main_path = path
            goto continue
        end
        relative_paths[#relative_paths + 1] = path
        ::continue::
    end
    if not main_path then
        return nil, 'main.lua not found'
    end
    local state = {
        modules = {},
        others = {},
        jsmodules = {},
    }
    local main_full_path = path_manager.join(dir, main_path)
    local func, err = loadfile(main_full_path)
    if func then
        state.main = read_text_without_utf8_bom(main_full_path)
    else
        return nil, err
    end
    for _, path in ipairs(relative_paths) do
        local full_path = path_manager.join(dir, path)
        if path:sub(-4) == '.lua' then
            local module_name = table.concat(path:sub(1, -5):split('/'), '.')
            local func, err = loadfile(full_path)
            if func then
                state.modules[module_name] = read_text_without_utf8_bom(full_path)
            else
                return nil, err
            end
        elseif path:sub(-3) == '.js' then
            state.jsmodules[path] = read_text_without_utf8_bom(full_path)
        elseif path:sub(-5) == '.json' then
            local data = read_text_without_utf8_bom(full_path)
            if preload_json then
                state.jsmodules[path] = data
            else
                state.others[path] = data
            end
        else
            state.others[path] = file.reads(full_path)
        end
    end
    local output = {}
    output[#output + 1] = [[
;(function()
local lfs = require "lfs";
local error = error;
local original_cwd = lfs.currentdir();
lfs.chdir(XXT_SCRIPTS_PATH);
local function unix_stripfilename(filename);
	return string.match(filename, "(.+)/[^/]+$");
end;
local extract_file = function(fn, data) local dir = unix_stripfilename(fn) if dir then sys.mkdir_p(dir) end os.remove(fn) file.writes(fn, data) end;
local _jscore = nil;
]]
    output[#output + 1] = [[
local _jscore_importer = (function(__xxt_generated_text)
return function() local built_xtversion = "]] .. sys.xtversion() .. [[" if _jscore then return _jscore end local ok, ret = pcall(require, 'jscore') if ok then _jscore = ret return _jscore else return error(string.format(__xxt_generated_text("This script is recommended to run on XXTouch %s or later."), built_xtversion)) end end
end)(
]]
    output[#output + 1] = generated_script_localizer_expression
    output[#output + 1] = [[
);
]]
    if is_classic_xxt_format then
        output[#output + 1] = [[lfs.chdir(XXT_HOME_PATH);]]
    end
    for path, data in pairs(state.jsmodules) do
        local js_path = "./" .. path
        output[#output + 1] = string.format(
            '_jscore_importer().preload(%q, %s, %q);',
            js_path,
            make_long_bracket(data),
            js_path
        )
    end
    for path, data in pairs(state.others) do
        output[#output + 1] = string.format('extract_file(%q, "%s");', path, data:to_hex('\\x'))
    end
    if is_classic_xxt_format then
        local module_prefix = 'lua.scripts.'
        for _, name in ipairs(dict_get_keys(state.modules)) do
            if name:starts_with(module_prefix) then
                local short_name = name:sub(#module_prefix + 1)
                state.modules[short_name] = state.modules[name]
                state.modules['lua.' .. short_name] = nil
                state.modules[name] = nil
            end
        end
        module_prefix = 'lua.'
        for _, name in ipairs(dict_get_keys(state.modules)) do
            if name:starts_with(module_prefix) then
                local short_name = name:sub(#module_prefix + 1)
                state.modules[short_name] = state.modules[name]
                state.modules[name] = nil
            end
        end
    end
    for name, module_content in pairs(state.modules) do
        output[#output + 1] = string.format('package.preload[%q] = function(...)\n%s\nend;', name, module_content)
    end
    output[#output + 1] = [[
lfs.chdir(original_cwd);
end)();
]]
    output[#output + 1] = state.main
    return table.concat(output, '\n')
end

local function load_xpp_info(Info_lua_path, config_dump)
    if lfs.attributes(Info_lua_path, 'mode') ~= 'file' then
        return nil, '`' .. Info_lua_path .. '` is not a file'
    end
    local Info_lua_content = file.reads(Info_lua_path)
    if not Info_lua_content then
        return nil, 'read `Info.lua` failed'
    end
    local info_reader, syntax_error = load(config_dump .. Info_lua_content, 'Info.lua', 't', {
        tostring = tostring,
        tonumber = tonumber,
        type = type,
        os = {
            time = os.time,
            difftime = os.difftime,
            clock = os.clock,
            date = os.date,
        },
        device = {
            type = device.type,
        },
        screen = {
            size = screen.size,
        },
        sys = {
            version = sys.version,
            xtversion = sys.xtversion,
            zeversion = sys.zeversion,
        },
        json = {
            null = json.null,
        },
    })
    if type(info_reader) ~= 'function' then
        return nil, syntax_error
    end
    local _, info = maxline_pcall(1000000, info_reader)
    if type(info) ~= 'table' then
        return nil, tostring(info)
    end
    return info
end

local function project_pack_xpa(dir, config_meta, encrypt_args)
    dir = path_manager.remove_dir_end(dir)
    local Info_lua_path = path_manager.join(dir, 'Info.lua')
    local config_dump = '_config = ' .. stringify(config_meta) .. ';_DEBUG = false;'
    local info, err = load_xpp_info(Info_lua_path, config_dump)
    if not info then
        return nil, err
    end
    local main_path
    if type(info.Executable) == 'string' and info.Executable:sub(-4) == '.lua' then
        main_path = path_manager.join(dir, info.Executable)
        info.Executable = info.Executable:sub(1, -5) .. '.xxt'
    end
    if type(info.MainInterfaceFile) == 'string' and info.MainInterfaceFile:sub(-4) == '.xui' then
        info.MainInterfaceFile = info.MainInterfaceFile .. 'c'
    end
    if not main_path then
        main_path = path_manager.join(dir, 'main.lua')
        if lfs.attributes(main_path, 'mode') ~= 'file' then
            main_path = nil
        end
    end
    local need_remove_files = { Info_lua_path }
    local list = file.list(dir, true) or {}
    for _, full_path in ipairs(list) do
        local path = full_path:sub(#dir + 2)
        if is_hidden_path(path) then
            need_remove_files[#need_remove_files + 1] = full_path
        end
    end
    for _, full_path in ipairs(need_remove_files) do
        file.remove(full_path)
    end
    list = file.list(dir, true) or {}
    local file_signs = {}
    local curtime = os.time()
    -- xpp 格式只备会被加密的文件的源码
    local src_dir = path_manager.join(dir .. '-src',
        path_manager.basename(dir) .. '-' .. os.date("%Y%m%d%H%M%S", curtime))
    src_dir = path_manager.remove_dir_end(src_dir)
    for _, full_path in ipairs(list) do
        if lfs.attributes(full_path, 'mode') ~= 'file' then
            goto continue
        end
        local ext = full_path:sub(-4)
        if ext == '.xui' then
            local xui_content = file.reads(full_path)
            if not xui_content then
                return nil, 'can not read `' .. full_path .. '`'
            end
            file.writes(full_path, config_dump .. xui_content)
            local out_file = full_path .. 'c'
            local ret, err = encript_file(full_path, out_file, nil, config_meta.entitlements, encrypt_args)
            if not ret then
                return nil, err
            end
            local relative_path = out_file:sub(#dir + 2)
            file_signs[relative_path] = file.sha1(out_file)
            local src_full_path = path_manager.join(src_dir, full_path:sub(#dir + 2))
            sys.mkdir_p(path_manager.dirname(src_full_path))
            file.move(full_path, src_full_path)
        elseif ext == '.lua' then
            if full_path == main_path then
                goto continue
            end
            local full_path_without_ext = full_path:sub(1, -5)
            local out_file = full_path_without_ext .. '.xxt'
            local info = {}
            info[#info + 1] = { 'Source File', path_manager.basename(full_path) }
            info[#info + 1] = { 'Packaging Date', os.date("%Y-%m-%d %H:%M:%S %z", curtime) }
            local ret, err = encript_file(full_path, out_file, info, config_meta.entitlements, encrypt_args)
            if not ret then
                return nil, err
            end
            local relative_path = out_file:sub(#dir + 2)
            file_signs[relative_path] = file.sha1(out_file)
            local src_full_path = path_manager.join(src_dir, full_path:sub(#dir + 2))
            sys.mkdir_p(path_manager.dirname(src_full_path))
            file.move(full_path, src_full_path)
        else
            local relative_path = full_path:sub(#dir + 2)
            file_signs[relative_path] = file.sha1(full_path)
        end
        ::continue::
    end
    file.writes(Info_lua_path, 'return ' .. stringify(info, { indent = '\t' }))
    file_signs["Info.lua"] = file.sha1(Info_lua_path)
    if main_path then
        local main_content = file.reads(main_path)
        if not main_content then
            return nil, 'can not read `' .. main_path .. '`'
        end
        local signs_dump = {}
        for relative_path, sign in pairs(file_signs) do
            -- 内层文案的占位符需要保留到生成脚本运行时，不能在打包时消耗。
            local s = string.format([[
            ;(function()
                local path = %q
                local real_path = xpp.resource_path(path)
                if not real_path then
                    sys.alert(string.format(__xxt_generated_text('Resource file not found: %%s'), path), 0, __xxt_generated_text('Script damaged'))
                    return os.exit()
                end
                local sign = file.sha1(real_path)
                if sign ~= %q then
                    sys.alert(string.format(__xxt_generated_text('Resource file is invalid: %%s'), path), 0, __xxt_generated_text('Script damaged'))
                    return os.exit()
                end
            end)()
            ]], relative_path, sign)
            signs_dump[#signs_dump + 1] = s:gsub('\n', ';')
        end
        local resource_validation_source = [[
;(function(__xxt_generated_text)
]] .. table.concat(signs_dump, ';') .. [[
end)(
]] .. generated_script_localizer_expression .. [[
);
]]
        file.writes(main_path, resource_validation_source .. main_content)
        local main_path_without_ext = main_path:sub(1, -5)
        local out_file = main_path_without_ext .. '.xxt'
        local main_file_name = path_manager.basename(main_path)
        local info = {}
        info[#info + 1] = { 'Source File', main_file_name }
        info[#info + 1] = { 'Packaging Date', os.date("%Y-%m-%d %H:%M:%S %z", curtime) }
        local ret, err = encript_file(main_path, out_file, info, config_meta.entitlements, encrypt_args)
        if not ret then
            return nil, err
        end
        local src_full_path = path_manager.join(src_dir, main_file_name)
        file.move(main_path, src_full_path)
    end
    local module_name = path_manager.basename(dir)
    local out_file = dir .. '.xpa'
    file.remove(out_file)
    local ret, err = zip_pack(out_file, dir, 'Payload/' .. module_name .. '.xpp/')
    if not ret then
        return nil, err
    end
    file.remove(dir)
    return '/download_file?filename=' .. string.encode_uri_component(out_file)
end

local function project_pack_xxt(dir, config_meta, encrypt_args)
    dir = path_manager.remove_dir_end(dir)
    local data, err = project_merge_files(dir, config_meta)
    if data then
        sys.mkdir_p(dir .. '-src')
        local curtime = os.time()
        local in_file_name = path_manager.basename(dir) .. '-' .. os.date("%Y%m%d%H%M%S", curtime) .. '.lua'
        local in_file = path_manager.join(dir .. '-src', in_file_name)
        local info = config_meta.information
        info = type(info) == "table" and info or {}
        info[#info + 1] = { 'Source File', in_file_name }
        info[#info + 1] = { 'Packaging Date', os.date("%Y-%m-%d %H:%M:%S %z", curtime) }
        local out_file = dir .. '.xxt'
        file.writes(in_file, data)
        local ok, err = encript_file(in_file, out_file, info, config_meta.entitlements, encrypt_args)
        if ok then
            file.remove(dir)
            return '/download_file?filename=' .. string.encode_uri_component(out_file)
        end
        return nil, err
    else
        return nil, err
    end
end

local function project_encrypt_xxt(lua_file, encrypt_args)
    local path = path_manager.splitext(lua_file)
    local in_file = lua_file
    local out_file = path .. '.xxt'
    local info = {}
    info[#info + 1] = { 'Source File', path_manager.basename(lua_file) }
    info[#info + 1] = { 'Packaging Date', os.date("%Y-%m-%d %H:%M:%S %z", os.time()) }
    local ret, err = encript_file(in_file, out_file, info, nil, encrypt_args)
    if ret then
        return '/download_file?filename=' .. string.encode_uri_component(out_file)
    end
    return nil, err
end

local function project_pack(path, encrypt_args)
    local config_meta
    if lfs.attributes(path, 'mode') == 'file' then
        local ext = path_manager.extension(path)
        if ext == '.lua' then
            return project_encrypt_xxt(path, encrypt_args)
        elseif ext == '.tar' or ext == '.tep' then
            local ok, to_path = tar_extract(path)
            if not ok then
                return nil, to_path
            end
            if ext == '.tar' then
                os.remove(path)
            end
            config_meta = read_project_config(to_path)
            path = to_path
        else
            return nil, '`' .. path .. '` format not support'
        end
    elseif lfs.attributes(path, 'mode') == 'directory' then
        config_meta = read_project_config(path)
    else
        return nil, '`' .. path .. '` is not file or directory'
    end
    if config_meta.type == 'xpp' then
        return project_pack_xpa(path, config_meta, encrypt_args)
    end
    return project_pack_xxt(path, config_meta, encrypt_args)
end

function _M.pack(path, encrypt_args, language)
    local download_url, err = project_pack(path, encrypt_args)
    if download_url then
        return { code = 0, message = response_message("operation completed", language), data = { download_url = download_url } }
    end
    if type(err) == 'table' then
        local ret = normalize_error_result(err, 99, response_message('unknown error', language))
        ret.message = localize_error_detail(ret.message, language)
        return ret
    end
    local decoded_err = decode_json_table(err)
    if type(decoded_err) == 'table' then
        local ret = normalize_error_result(decoded_err, 99, response_message('unknown error', language))
        ret.message = localize_error_detail(ret.message, language)
        return ret
    end
    local detail = tostring(err or response_message('unknown error', language))
    return {
        code = 99,
        message = string.format(response_message("operation failed: %s", language), localize_error_detail(detail, language)),
        detail = type(err) == 'string' and err or nil,
    }
end

return _M
