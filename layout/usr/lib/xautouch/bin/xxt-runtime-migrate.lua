-- 普通安装只合并包资源；目录移动只由用户请求的独立 worker 执行。
local operation, operation_argument, operation_context = ...
if operation == "begin-app-transition" then
    local bid = operation_argument
    if operation_context == "foreground" then
        pcall(app.run, "com.apple.springboard")
    end
    sys.toast(require("localization").text({
        en = { migrating = "Migration in progress. Please do not open the app." },
        ["zh-Hans"] = { migrating = "正在迁移，请勿打开 App" },
        ["zh-Hant"] = { migrating = "正在遷移，請勿開啟 App" },
        vi = { migrating = "Đang di chuyển dữ liệu. Vui lòng không mở ứng dụng." },
        ja = { migrating = "データを移行しています。アプリを開かないでください。" },
        ko = { migrating = "데이터를 이동 중입니다. 앱을 열지 마세요." },
        es = { migrating = "Migración en curso. No abra la aplicación." },
        ["pt-BR"] = { migrating = "Migração em andamento. Não abra o aplicativo." },
        ru = { migrating = "Идёт перенос данных. Не открывайте приложение." },
        fr = { migrating = "Migration en cours. Veuillez ne pas ouvrir l’application." },
        de = { migrating = "Daten werden übertragen. Bitte die App nicht öffnen." },
    }, "migrating"), {allow_screenshot = true})
    sys.msleep(2000)
    app.close(bid)
    -- 缓存数据库随文档一起移动，必须确认旧进程已释放文件；不等待 App 回执。
    for _ = 1, 30 do
        if not app.is_running(bid) then return end
        sys.msleep(100)
    end
    assert(not app.is_running(bid), "XXTExplorer could not be closed before moving data")
    return
elseif operation == "finish-app-transition" then
    if operation_context == "foreground" then
        sys.msleep(3000)
        app.run(operation_argument)
    end
    return
end

local lfs = require("lfs")
local json = require("cjson.safe")
local unix = require("unix")

local FALLBACK_SERIAL = "XXTVM0000000001"
local function trim(value)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    return value ~= "" and value or nil
end

local function real_serial()
    local value
    if type(sys) == "table" then
        local getter = sys.mgcopyanswer or sys.MGCopyAnswer
        if type(getter) == "function" then
            local ok, result = pcall(getter, "SerialNumber")
            if ok then
                value = result
            end
        end
    end
    value = trim(value)
    if not value and type(device) == "table" and type(device.serial_number) == "function" then
        local ok, result = pcall(device.serial_number)
        if ok then
            value = trim(result)
        end
    end
    if not value or value == FALLBACK_SERIAL then
        return nil
    end
    if #value > 64 or not value:match("^[A-Za-z0-9]+$") then
        return nil
    end
    return value
end


local bundled = rawget(_G, "XXT_IS_TROLLSTORE_EDITION")
if bundled == nil then bundled = rawget(_G, "IS_TROLLSTORE_EDITION") == true end
local serial = real_serial()
local legacy_logical = "/var/mobile/Media/1ferver"
local device_logical = serial and ("/var/mobile/Media/XXTouch-" .. serial)
local root_legacy = legacy_logical
local device_home = device_logical
local jailbreak_root = not bundled and assert(sys.realpath(jbroot("/")))
local legacy_home = bundled and root_legacy or jailbreak_root:gsub("/+$", "") .. legacy_logical
local preferences = "/var/mobile/Library/Preferences"
local fixed_preferences = preferences .. "/XXTEUserDefaults.plist"
local device_preferences = serial and (preferences .. "/XXTEUserDefaults-" .. serial .. ".plist")
local script_path = debug.getinfo(1, "S").source:match("^@(.+)$")
local seed = script_path and script_path:match("^(.+)/bin/xxt%-runtime%-migrate%.lua$")
local device_exists = device_home and lfs.symlinkattributes(device_home, "mode") == "directory"
local active_home = device_exists and device_home or legacy_home

local function link_to(path, target)
    if lfs.symlinkattributes(path, "mode") == "link" then
        if unix.raw_readlink(path) == target then return end
        assert(os.remove(path))
    elseif lfs.symlinkattributes(path, "mode") then
        assert(file.remove(path))
    end
    assert(sys.mkdir_p(path:match("^(.+)/[^/]+$")))
    assert(unix.raw_symlink(target, path))
end

local function refresh_environment(home)
    assert(sys.mkdir_p(home .. "/bin"))
    assert(sys.mkdir_p(home .. "/caches"))
    if bundled then
        if lfs.symlinkattributes(home .. "/lib", "mode") == "link" then
            assert(os.remove(home .. "/lib"))
        end
        assert(sys.mkdir_p(home .. "/lib"))
        for _, name in ipairs({ "ReportCrash", "1nstaller", "add1s" }) do
            local path = home .. "/bin/" .. name
            if lfs.symlinkattributes(path, "mode") == "link" then assert(os.remove(path)) end
        end
    else
        local system_home = assert(sys.realpath(jbroot("/usr/bin/1ferver")))
        link_to(home .. "/lib", system_home .. "/lib")
        for _, name in ipairs({ "ReportCrash", "1nstaller", "add1s" }) do
            link_to(home .. "/bin/" .. name, system_home .. "/" .. name)
        end
    end
    if home == device_home then
        if lfs.symlinkattributes(root_legacy, "mode") == "link" then assert(os.remove(root_legacy)) end
    elseif not bundled and legacy_home ~= root_legacy then
        -- 系统根已有实体目录时保留它；这里仅维护越狱版使用的兼容软链。
        local mode = lfs.symlinkattributes(root_legacy, "mode")
        if mode == nil or mode == "link" then link_to(root_legacy, legacy_home) end
    end
end

local function xor_sign_old(value, key)
    local key_bytes = {}
    for index = 1, #key do
        key_bytes[#key_bytes + 1] = string.byte(key, index)
    end
    local result = 0
    local index = 1
    value:gsub("(.)", function(character)
        local byte = string.byte(character)
        for key_index = 1, #key_bytes do
            byte = byte ~ key_bytes[key_index]
            byte = byte ~ (index % 0xff)
            byte = byte ~ (key_index % 0xff)
        end
        byte = byte & 0xff
        result = result + byte
        result = result * result
        result = result ~ (2 ^ (index % 32))
        result = result % 0xffffffff
        index = index + 1
        return ""
    end)
    return string.format("%08x", result)
end


local function rewrite_configuration(home, old_home, old_logical, new_logical, ports)
    local path = home .. "/1ferver.conf"
    local config, failure
    -- 迁移成功后会更新健康备份，不能把读取失败当成空配置覆盖它。
    for _, candidate in ipairs({ path, path .. ".last" }) do
        local input
        input, failure = io.open(candidate, "rb")
        if input then
            local contents
            contents, failure = input:read("*a")
            input:close()
            if contents then config, failure = json.decode(contents) end
            if type(config) == "table" then break end
        end
    end
    assert(type(config) == "table", failure or "runtime configuration is not valid JSON")
    for _, key in ipairs({ "current_script", "startup_script", "webdav_path" }) do
        local value = config[key]
        if type(value) == "string" then
            for _, prefix in ipairs({ old_home, old_logical }) do
                if value == prefix or value:sub(1, #prefix + 1) == prefix .. "/" then
                    config[key] = new_logical .. value:sub(#prefix + 1)
                    break
                end
            end
        end
    end
    if type(config.startup_script) == "string" then
        local signing_serial = type(device) == "table" and device.serial_number() or serial or FALLBACK_SERIAL
        local mask = string.format("%08x%08x%08x", sys.rnd(), sys.rnd(), sys.rnd()):sub(-24)
        config.startup_sign = xor_sign_old(mask .. signing_serial ..
            tostring(config.startup_run == true) .. config.startup_script, "1ferver") .. mask
    end
    for key, value in pairs(ports or {}) do config[key] = value end
    local output = assert(io.open(path .. ".tmp-runtime", "wb"))
    assert(output:write(assert(json.encode(config))))
    assert(output:close())
    assert(os.rename(path .. ".tmp-runtime", path))
    sys.lchown(path, 501, 501)
end

if serial and (operation == "install" or operation == "sync-seed") then
    local preferences_lock = assert(XXT_RUNTIME_PREFERENCES_LOCK(true), "cannot prepare device preferences")
    XXT_RUNTIME_PREFERENCES_UNLOCK(preferences_lock)
end

if operation == "device-exists" then
    os.exit(device_exists and 0 or 4)
elseif operation == "paths" then
    print(json.encode({ serial = serial, device_logical_home = device_logical,
        device_home = device_home, legacy_home = legacy_home,
        device_preferences = device_preferences, fixed_preferences = fixed_preferences }))
elseif operation == "legacy-source-status" then
    local available = lfs.symlinkattributes(legacy_home, "mode") == "directory"
    return json.encode({ state = available and "exact" or "none", available = available,
        merge_available = available and device_exists or false,
        alias_present = lfs.symlinkattributes(root_legacy, "mode") == "link", retained = false })
elseif operation == "install" then
    if device_exists then
        local mode, message, code = lfs.symlinkattributes(legacy_home, "mode")
        -- dpkg 再次配置时资源可能已合并；只允许明确不存在的源目录跳过移动。
        assert(mode or code == 2, message)
        if mode then assert(file.move(legacy_home, device_home, "mo")) end
    end
    refresh_environment(active_home)
    sys.lchownmod_r(active_home, 501, 501, "0755")
    print(json.encode({ phase = "installed", target = active_home }))
elseif operation == "sync-seed" then
    assert(seed, "packaged runtime directory is unavailable")
    if not device_exists and lfs.symlinkattributes(root_legacy, "mode") == "link" then
        assert(os.remove(root_legacy))
    end
    refresh_environment(active_home)
    assert(file.copy(seed, active_home, "mo"))
    sys.lchownmod_r(active_home, 501, 501, "0755")
    print(json.encode({ phase = "installed", target = active_home }))
elseif operation == "migrate-edition" then
    -- 专属目录由两个版本共用；旧脚本只处理旧目录，保留原越狱调用条件。
    if device_exists or (not bundled and (jailbreak_root == "/" or
        lfs.symlinkattributes(root_legacy, "mode") == "link")) then return end
    XXT_HOME_PATH = active_home
    XXT_BIN_PATH = active_home .. "/bin"
    XXT_SCRIPTS_PATH = active_home .. "/lua/scripts"
    XXT_CONF_FILE_NAME = active_home .. "/1ferver.conf"
    local entry = bundled and "xxt-migrate-jb2ts.lua" or "xxt-migrate-ts2jb.lua"
    return assert(loadfile((bundled and seed or active_home) .. "/bin/" .. entry))()
elseif operation == "refresh-environment" then
    refresh_environment(active_home)
elseif operation == "refresh-package-links" then
    if not bundled and jailbreak_root ~= "/" then
        link_to(jailbreak_root .. "/Library/MobileSubstrate/DynamicLibraries",
            jailbreak_root .. "/usr/lib/TweakInject")
    end
elseif operation == "refresh-libffi-link" then
    if not bundled and sys.cfversion() < 1600 and
        not lfs.symlinkattributes(jbroot("/usr/lib/libffi.dylib"), "mode") then
        link_to(jbroot("/usr/lib/libffi.dylib"), assert(sys.realpath(jbroot("/usr/bin/1ferver/libffi.dylib"))))
    end
elseif operation == "switch-device" or operation == "switch-legacy" or operation == "merge-old-data" then
    assert(device_home, "the original device serial number is unavailable")
    local to_device = operation ~= "switch-legacy"
    local source, target = to_device and legacy_home or device_home, to_device and device_home or legacy_home
    local old_logical, new_logical = to_device and legacy_logical or device_logical, to_device and device_logical or legacy_logical
    local context = operation_context and assert(json.decode(operation_context)) or {}
    local shared_lock = XXT_RUNTIME_SHARED_LOCK(true)
    assert(shared_lock, "cannot acquire runtime write lock")
    local succeeded, result = xpcall(function()
        -- 重试时源目录可能已移动完；目标存在即可继续配置和服务收尾。
        if lfs.symlinkattributes(source, "mode") == "directory" then
            if lfs.symlinkattributes(target, "mode") == "link" then assert(os.remove(target)) end
            assert(file.move(source, target, "mo"))
        else
            assert(lfs.symlinkattributes(target, "mode") == "directory", "source directory is unavailable")
        end
        rewrite_configuration(target, source, old_logical, new_logical, context.target_ports)
        refresh_environment(target)
        sys.lchownmod_r(target, 501, 501, "0755")
    end, debug.traceback)
    XXT_RUNTIME_SHARED_UNLOCK(shared_lock)
    if not succeeded then error(result, 0) end
elseif operation == "record-app-transition-failure" then
    -- 失败状态由独立 worker 的操作记录统一提供。
    return
elseif operation == "status" then
    print(json.encode({ phase = "idle", target = active_home }))
else
    error("unknown runtime directory operation: " .. tostring(operation), 0)
end
