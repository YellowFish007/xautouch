--[[

    本文件仅作为参考，请不要修改本文件
    本文件会在重装、更新时被原版覆盖

--]]

local proc_value_operations = {}
local proc_queue_operations = {}
local proc_dict_operations = {}
local localization = require('localization')
local messages = {
    en = {
        ["argument error."] = "argument error.", ["operation failed"] = "operation failed",
        ["operation completed"] = "operation completed", ["`key` is invalid"] = "`key` is invalid",
        ["`value` is invalid"] = "`value` is invalid",
    },
    ["zh-Hans"] = {
        ["argument error."] = "参数错误。", ["operation failed"] = "操作失败",
        ["operation completed"] = "操作完成", ["`key` is invalid"] = "`key` 无效",
        ["`value` is invalid"] = "`value` 无效",
    },
    ["zh-Hant"] = {
        ["argument error."] = "參數錯誤。", ["operation failed"] = "操作失敗",
        ["operation completed"] = "操作完成", ["`key` is invalid"] = "`key` 無效",
        ["`value` is invalid"] = "`value` 無效",
    },
    vi = {
        ["argument error."] = "Đối số không hợp lệ.", ["operation failed"] = "Thao tác thất bại",
        ["operation completed"] = "Thao tác hoàn tất", ["`key` is invalid"] = "`key` không hợp lệ",
        ["`value` is invalid"] = "`value` không hợp lệ",
    },
    ja = {
        ["argument error."] = "引数が正しくありません。", ["operation failed"] = "操作に失敗しました",
        ["operation completed"] = "操作が完了しました", ["`key` is invalid"] = "`key` が無効です",
        ["`value` is invalid"] = "`value` が無効です",
    },
    ko = {
        ["argument error."] = "인수가 올바르지 않습니다.", ["operation failed"] = "작업에 실패했습니다",
        ["operation completed"] = "작업이 완료되었습니다", ["`key` is invalid"] = "`key`가 올바르지 않습니다",
        ["`value` is invalid"] = "`value`가 올바르지 않습니다",
    },
    es = {
        ["argument error."] = "Argumento no válido.", ["operation failed"] = "La operación falló",
        ["operation completed"] = "Operación completada", ["`key` is invalid"] = "`key` no es válido",
        ["`value` is invalid"] = "`value` no es válido",
    },
    ["pt-BR"] = {
        ["argument error."] = "Argumento inválido.", ["operation failed"] = "Falha na operação",
        ["operation completed"] = "Operação concluída", ["`key` is invalid"] = "`key` é inválido",
        ["`value` is invalid"] = "`value` é inválido",
    },
    ru = {
        ["argument error."] = "Недопустимый аргумент.", ["operation failed"] = "Операция не выполнена",
        ["operation completed"] = "Операция выполнена", ["`key` is invalid"] = "Недопустимый `key`",
        ["`value` is invalid"] = "Недопустимый `value`",
    },
    fr = {
        ["argument error."] = "Argument non valide.", ["operation failed"] = "Échec de l’opération",
        ["operation completed"] = "Opération terminée", ["`key` is invalid"] = "`key` n’est pas valide",
        ["`value` is invalid"] = "`value` n’est pas valide",
    },
    de = {
        ["argument error."] = "Ungültiges Argument.", ["operation failed"] = "Vorgang fehlgeschlagen",
        ["operation completed"] = "Vorgang abgeschlossen", ["`key` is invalid"] = "`key` ist ungültig",
        ["`value` is invalid"] = "`value` ist ungültig",
    },
}

local function message(key, language)
    return localization.text(messages, key, language)
end

proc_dict_operations['run'] = function(lua_code, language)
    if "string" ~= type(lua_code) then
        return nil, message('argument error.', language)
    end
    local result, err = proc_dict_run(lua_code)
    if not result then
        return { code = 1, message = message("operation failed", language), ok = false, error = tostring(err):gsub("^%[string \".*\"%]:", "") }
    end
    result = result:base64_encode()
    return { code = 0, message = message("operation completed", language), ok = true, result = result, result_encoding = "base64" }
end

proc_value_operations['put'] = function(body, language)
    if "string" ~= type(body.value) then
        return nil, message('argument error.', language)
    end
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, message('`key` is invalid', language)
    end
    local raw_value = body.value
    if body.value_encoding == "base64" then
        raw_value = raw_value:base64_decode()
    else
        body.value_encoding = nil
    end
    if not raw_value then
        return nil, message('`value` is invalid', language)
    end
    local old_val = proc_put(raw_key, raw_value)
    if body.value_encoding == "base64" then
        old_val = old_val:base64_encode()
    end
    return { code = 0, message = message("operation completed", language), key = body.key, old_value = old_val, value = body.value, key_encoding =
    body.key_encoding, value_encoding = body.value_encoding }
end
proc_value_operations['get'] = function(body, language)
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, message('`key` is invalid', language)
    end
    local val = proc_get(raw_key)
    if body.value_encoding == "base64" then
        val = val:base64_encode()
    else
        body.value_encoding = nil
    end
    return { code = 0, message = message("operation completed", language), key = body.key, value = val, key_encoding = body.key_encoding, value_encoding =
    body.value_encoding }
end

proc_queue_operations['push-back'] = function(body, language)
    if "string" ~= type(body.value) then
        return nil, message("argument error.", language)
    end
    local queue_size = 0
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    end
    if not raw_key then
        return nil, message("`key` is invalid", language)
    end
    local raw_value = body.value
    if body.value_encoding == "base64" then
        raw_value = raw_value:base64_decode()
    end
    if not raw_value then
        return nil, message("`value` is invalid", language)
    end
    local max_size = type(body.max_size) == "number" and (body.max_size // 1) or 10000
    queue_size = proc_queue_push_back(raw_key, raw_value, max_size)
    return { code = 0, message = message("operation completed", language), key = body.key, size = queue_size, key_encoding = body
    .key_encoding }
end
proc_queue_operations['push-front'] = function(body, language)
    if "string" ~= type(body.value) then
        return nil, message("argument error.", language)
    end
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    end
    if not raw_key then
        return nil, message("`key` is invalid", language)
    end
    local raw_value = body.value
    if body.value_encoding == "base64" then
        raw_value = raw_value:base64_decode()
    end
    if not raw_value then
        return nil, message("`value` is invalid", language)
    end
    local max_size = type(body.max_size) == "number" and (body.max_size // 1) or 10000
    queue_size = proc_queue_push_front(raw_key, raw_value, max_size)
    return { code = 0, message = message("operation completed", language), key = body.key, size = queue_size, key_encoding = body
    .key_encoding }
end
proc_queue_operations['pop-front'] = function(body, language)
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, message("`key` is invalid", language)
    end
    local val = proc_queue_pop_front(raw_key)
    if body.value_encoding == "base64" then
        val = val:base64_encode()
    else
        body.value_encoding = nil
    end
    return { code = 0, message = message("operation completed", language), key = body.key, value = val, key_encoding = body.key_encoding, value_encoding =
    body.value_encoding }
end
proc_queue_operations['pop-back'] = function(body, language)
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, message("`key` is invalid", language)
    end
    local val = proc_queue_pop_back(raw_key)
    if body.value_encoding == "base64" then
        val = val:base64_encode()
    else
        body.value_encoding = nil
    end
    return { code = 0, message = message("operation completed", language), key = body.key, value = val, key_encoding = body.key_encoding, value_encoding =
    body.value_encoding }
end
proc_queue_operations['count-value'] = function(body, language)
    if "string" ~= type(body.value) then
        return nil, message("argument error.", language)
    end
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    end
    if not raw_key then
        return nil, message("`key` is invalid", language)
    end
    local raw_value = body.value
    if body.value_encoding == "base64" then
        raw_value = raw_value:base64_decode()
    end
    if not raw_value then
        return nil, message("`value` is invalid", language)
    end
    local queue_size = proc_queue_count_value(raw_key, raw_value)
    return { code = 0, message = message("operation completed", language), key = body.key, size = queue_size, key_encoding = body
    .key_encoding }
end
proc_queue_operations['pop-value'] = function(body, language)
    if "string" ~= type(body.value) then
        return nil, message("argument error.", language)
    end
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    end
    if not raw_key then
        return nil, message("`key` is invalid", language)
    end
    local raw_value = body.value
    if body.value_encoding == "base64" then
        raw_value = raw_value:base64_decode()
    end
    if not raw_value then
        return nil, message("`value` is invalid", language)
    end
    local queue_size = proc_queue_pop_value(raw_key, raw_value)
    return { code = 0, message = message("operation completed", language), key = body.key, size = queue_size, key_encoding = body
    .key_encoding }
end
proc_queue_operations['clear'] = function(body, language)
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, message("`key` is invalid", language)
    end
    local vals = proc_queue_clear(raw_key)
    if body.value_encoding == "base64" then
        for i = 1, #vals do
            vals[i] = vals[i]:base64_encode()
        end
    else
        body.value_encoding = nil
    end
    return { code = 0, message = message("operation completed", language), key = body.key, values = vals, key_encoding = body.key_encoding, value_encoding =
    body.value_encoding }
end
proc_queue_operations['read'] = function(body, language)
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, message("`key` is invalid", language)
    end
    local vals = proc_queue_read(raw_key)
    if body.value_encoding == "base64" then
        for i = 1, #vals do
            vals[i] = vals[i]:base64_encode()
        end
    else
        body.value_encoding = nil
    end
    return { code = 0, message = message("operation completed", language), key = body.key, values = vals, key_encoding = body.key_encoding, value_encoding =
    body.value_encoding }
end
proc_queue_operations['push'] = proc_queue_operations['push-back']
proc_queue_operations['pop'] = proc_queue_operations['pop-back']

return {
    proc_value_operations = proc_value_operations,
    proc_queue_operations = proc_queue_operations,
    proc_dict_operations = proc_dict_operations,
}
