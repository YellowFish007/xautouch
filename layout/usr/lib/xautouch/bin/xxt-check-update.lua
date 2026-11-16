--[[

    检查更新脚本

    本文件仅作为参考，请不要修改本文件
    本文件会在重装、更新时被原版覆盖

--]]

local function is_xxt_app_front()
    return app.front_bid() == "com.xxtouch.XXTExplorer" or app.front_bid() == "app.xxtouch.XXTExplorer"
end

if not is_xxt_app_front() then
    return
end

if not lockfile(jbroot("/tmp/.xxtouch-check-update.lua.singleton")) then
    return
end

local localization = require("localization")
local LLANG = (function()
    local _localizations = {
        en = {
            ["XXTouch"] = "XXTouch",
            ["Not Now"] = "Not Now",
            ["Download Update"] = "Download Update",
            ["Skip This Version"] = "Skip This Version",
            ["Use Sileo Update"] = "Use Sileo Update",
            ["Use Cydia Update"] = "Use Cydia Update",
            ["Use Zebra Update"] = "Use Zebra Update",
            ["New Version"] = "New Version",
            ["Update?"] = "Update?",
            ["Use Sileo Update?"] = "Use Sileo Update?",
            ["Use Cydia Update?"] = "Use Cydia Update?",
            ["Use Zebra Update?"] = "Use Zebra Update?",
        },
        ["zh-Hans"] = {
            ["XXTouch"] = "X.X.T.",
            ["Not Now"] = "暂不更新",
            ["Download Update"] = "下载更新",
            ["Skip This Version"] = "跳过此版本",
            ["Use Sileo Update"] = "使用 Sileo 更新",
            ["Use Cydia Update"] = "使用 Cydia 更新",
            ["Use Zebra Update"] = "使用 Zebra 更新",
            ["New Version"] = "发现新版本",
            ["Update?"] = "是否下载更新？",
            ["Use Sileo Update?"] = "是否使用 Sileo 更新？",
            ["Use Cydia Update?"] = "是否使用 Cydia 更新？",
            ["Use Zebra Update?"] = "是否使用 Zebra 更新？",
        },
        ["zh-Hant"] = {
            ["XXTouch"] = "X.X.T.", ["Not Now"] = "暫不更新", ["Download Update"] = "下載更新",
            ["Skip This Version"] = "略過此版本", ["Use Sileo Update"] = "使用 Sileo 更新",
            ["Use Cydia Update"] = "使用 Cydia 更新", ["Use Zebra Update"] = "使用 Zebra 更新",
            ["New Version"] = "發現新版本", ["Update?"] = "是否下載更新？",
            ["Use Sileo Update?"] = "是否使用 Sileo 更新？", ["Use Cydia Update?"] = "是否使用 Cydia 更新？",
            ["Use Zebra Update?"] = "是否使用 Zebra 更新？",
        },
        vi = {
            ["XXTouch"] = "XXTouch", ["Not Now"] = "Để sau", ["Download Update"] = "Tải bản cập nhật", ["Skip This Version"] = "Bỏ qua phiên bản này",
            ["Use Sileo Update"] = "Cập nhật bằng Sileo", ["Use Cydia Update"] = "Cập nhật bằng Cydia",
            ["Use Zebra Update"] = "Cập nhật bằng Zebra", ["New Version"] = "Có phiên bản mới", ["Update?"] = "Tải bản cập nhật?",
            ["Use Sileo Update?"] = "Cập nhật bằng Sileo?", ["Use Cydia Update?"] = "Cập nhật bằng Cydia?",
            ["Use Zebra Update?"] = "Cập nhật bằng Zebra?",
        },
        ja = {
            ["XXTouch"] = "XXTouch", ["Not Now"] = "後で", ["Download Update"] = "アップデートをダウンロード", ["Skip This Version"] = "このバージョンをスキップ",
            ["Use Sileo Update"] = "Sileo で更新", ["Use Cydia Update"] = "Cydia で更新", ["Use Zebra Update"] = "Zebra で更新",
            ["New Version"] = "新しいバージョン", ["Update?"] = "アップデートをダウンロードしますか？",
            ["Use Sileo Update?"] = "Sileo で更新しますか？", ["Use Cydia Update?"] = "Cydia で更新しますか？",
            ["Use Zebra Update?"] = "Zebra で更新しますか？",
        },
        ko = {
            ["XXTouch"] = "XXTouch", ["Not Now"] = "나중에", ["Download Update"] = "업데이트 다운로드", ["Skip This Version"] = "이 버전 건너뛰기",
            ["Use Sileo Update"] = "Sileo로 업데이트", ["Use Cydia Update"] = "Cydia로 업데이트", ["Use Zebra Update"] = "Zebra로 업데이트",
            ["New Version"] = "새 버전", ["Update?"] = "업데이트를 다운로드할까요?",
            ["Use Sileo Update?"] = "Sileo로 업데이트할까요?", ["Use Cydia Update?"] = "Cydia로 업데이트할까요?",
            ["Use Zebra Update?"] = "Zebra로 업데이트할까요?",
        },
        es = {
            ["XXTouch"] = "XXTouch", ["Not Now"] = "Ahora no", ["Download Update"] = "Descargar actualización", ["Skip This Version"] = "Omitir esta versión",
            ["Use Sileo Update"] = "Actualizar con Sileo", ["Use Cydia Update"] = "Actualizar con Cydia", ["Use Zebra Update"] = "Actualizar con Zebra",
            ["New Version"] = "Nueva versión", ["Update?"] = "¿Descargar la actualización?",
            ["Use Sileo Update?"] = "¿Actualizar con Sileo?", ["Use Cydia Update?"] = "¿Actualizar con Cydia?", ["Use Zebra Update?"] = "¿Actualizar con Zebra?",
        },
        ["pt-BR"] = {
            ["XXTouch"] = "XXTouch", ["Not Now"] = "Agora não", ["Download Update"] = "Baixar atualização", ["Skip This Version"] = "Ignorar esta versão",
            ["Use Sileo Update"] = "Atualizar com o Sileo", ["Use Cydia Update"] = "Atualizar com o Cydia", ["Use Zebra Update"] = "Atualizar com o Zebra",
            ["New Version"] = "Nova versão", ["Update?"] = "Baixar a atualização?",
            ["Use Sileo Update?"] = "Atualizar com o Sileo?", ["Use Cydia Update?"] = "Atualizar com o Cydia?", ["Use Zebra Update?"] = "Atualizar com o Zebra?",
        },
        ru = {
            ["XXTouch"] = "XXTouch", ["Not Now"] = "Не сейчас", ["Download Update"] = "Скачать обновление", ["Skip This Version"] = "Пропустить эту версию",
            ["Use Sileo Update"] = "Обновить через Sileo", ["Use Cydia Update"] = "Обновить через Cydia", ["Use Zebra Update"] = "Обновить через Zebra",
            ["New Version"] = "Новая версия", ["Update?"] = "Скачать обновление?",
            ["Use Sileo Update?"] = "Обновить через Sileo?", ["Use Cydia Update?"] = "Обновить через Cydia?", ["Use Zebra Update?"] = "Обновить через Zebra?",
        },
        fr = {
            ["XXTouch"] = "XXTouch", ["Not Now"] = "Pas maintenant", ["Download Update"] = "Télécharger la mise à jour", ["Skip This Version"] = "Ignorer cette version",
            ["Use Sileo Update"] = "Mettre à jour avec Sileo", ["Use Cydia Update"] = "Mettre à jour avec Cydia", ["Use Zebra Update"] = "Mettre à jour avec Zebra",
            ["New Version"] = "Nouvelle version", ["Update?"] = "Télécharger la mise à jour ?",
            ["Use Sileo Update?"] = "Mettre à jour avec Sileo ?", ["Use Cydia Update?"] = "Mettre à jour avec Cydia ?", ["Use Zebra Update?"] = "Mettre à jour avec Zebra ?",
        },
        de = {
            ["XXTouch"] = "XXTouch", ["Not Now"] = "Nicht jetzt", ["Download Update"] = "Update laden", ["Skip This Version"] = "Diese Version überspringen",
            ["Use Sileo Update"] = "Mit Sileo aktualisieren", ["Use Cydia Update"] = "Mit Cydia aktualisieren", ["Use Zebra Update"] = "Mit Zebra aktualisieren",
            ["New Version"] = "Neue Version", ["Update?"] = "Update herunterladen?",
            ["Use Sileo Update?"] = "Mit Sileo aktualisieren?", ["Use Cydia Update?"] = "Mit Cydia aktualisieren?", ["Use Zebra Update?"] = "Mit Zebra aktualisieren?",
        },
    }
    return localization.localizer(_localizations)
end)()

local json = require('cjson.safe')

local last_check_update = file.reads(XXT_HOME_PATH .. '/caches/.last-check-update') or ""
last_check_update = json.decode(last_check_update)
last_check_update = type(last_check_update) == 'table' and last_check_update or {}
if (tonumber(last_check_update.time or 0) or 0) > (os.time() - 3600) then
    return
end

local c, h, r = http.get("https://xxtouch.app/api/latest-version", 15, {})
if c ~= 200 then
    return
end

local t = json.decode(r)
if type(t) ~= 'table' then
    return
end

t = t["app.xxtouch.ios"]
if type(t) ~= 'table' then
    return
end

if type(t.latest) ~= 'string' then
    return
end

if not is_xxt_app_front() then
    return
end

t.time = os.time()
file.writes(XXT_HOME_PATH .. '/caches/.last-check-update', json.encode(t))

if sys.xtversion():compare_version(t.latest) >= 0 then
    -- if sys.xtversion() == (t.latest) then
    return
end

if file.reads(XXT_HOME_PATH .. '/caches/.skiped-version') == t.latest then
    return
end

local description = t.description
local description_keys = {
    ["zh-Hans"] = { "description_zh_Hans", "description_zh_hans", "description_zh" },
    ["zh-Hant"] = { "description_zh_Hant", "description_zh_hant", "description_zh" },
    vi = { "description_vi" }, ja = { "description_ja" }, ko = { "description_ko" },
    es = { "description_es" }, ["pt-BR"] = { "description_pt_BR", "description_pt_br", "description_pt" },
    ru = { "description_ru" }, fr = { "description_fr" }, de = { "description_de" },
}
for _, key in ipairs(description_keys[localization.current()] or {}) do
    if type(t[key]) == "string" then description = t[key] break end
end

if IS_TROLLSTORE_EDITION then
    local troll_bid = 'com.opa334.TrollStore'
    local troll_path = app.bundle_path(troll_bid)
    if not troll_path then
        troll_bid = 'com.opa334.TrollStoreLite'
        troll_path = app.bundle_path(troll_bid)
    end
    t.url = "https://xxtouch.app/?action=click-download-tipa"
    file.writes(XXT_HOME_PATH .. '/caches/.last-check-update', json.encode(t))
    local choice = sys.alert(LLANG("New Version") .. " " .. t.latest .. "\n\n" .. description .. "\n\n" ..
    LLANG("Update?"), 30, LLANG("XXTouch"), LLANG("Not Now"), LLANG("Download Update"), LLANG("Skip This Version"))
    if choice == 2 then
        file.writes(XXT_HOME_PATH .. '/caches/.skiped-version', t.latest)
        return os.exit()
    elseif choice ~= 1 then
        return os.exit()
    end
    if (type(t['tipa-url']) ~= 'string') or (not troll_path) or file.exists(troll_path .. "/trollstorehelper") ~= 'file' then
        app.open_url("https://xxtouch.app/?action=click-download-tipa")
    else
        app.open_url(troll_bid, "apple-magnifier://install?url=" .. string.encode_uri_component(t['tipa-url']))
    end
    return os.exit()
end

if app.bundle_path("org.coolstar.SileoStore") then
    t.url = "sileo://source/https://xxtouch.app"
    file.writes(XXT_HOME_PATH .. '/caches/.last-check-update', json.encode(t))
    local choice = sys.alert(
    LLANG("New Version") .. " " .. t.latest .. "\n\n" .. description .. "\n\n" .. LLANG("Use Sileo Update?"), 30,
        LLANG("XXTouch"), LLANG("Not Now"), LLANG("Use Sileo Update"), LLANG("Skip This Version"))
    if choice == 2 then
        file.writes(XXT_HOME_PATH .. '/caches/.skiped-version', t.latest)
        return os.exit()
    elseif choice ~= 1 then
        return os.exit()
    end
    app.open_url("org.coolstar.SileoStore", t.url)
elseif app.bundle_path("com.saurik.Cydia") then
    t.url = "cydia://url/https://cydia.saurik.com/api/share#?source=https://xxtouch.app"
    file.writes(XXT_HOME_PATH .. '/caches/.last-check-update', json.encode(t))
    local choice = sys.alert(
    LLANG("New Version") .. " " .. t.latest .. "\n\n" .. description .. "\n\n" .. LLANG("Use Cydia Update?"), 30,
        LLANG("XXTouch"), LLANG("Not Now"), LLANG("Use Cydia Update"), LLANG("Skip This Version"))
    if choice == 2 then
        file.writes(XXT_HOME_PATH .. '/caches/.skiped-version', t.latest)
        return os.exit()
    elseif choice ~= 1 then
        return os.exit()
    end
    app.open_url("com.saurik.Cydia", t.url)
elseif app.bundle_path("xyz.willy.Zebra") then
    t.url = "zbra://sources/add/https://xxtouch.app"
    file.writes(XXT_HOME_PATH .. '/caches/.last-check-update', json.encode(t))
    local choice = sys.alert(
    LLANG("New Version") .. " " .. t.latest .. "\n\n" .. description .. "\n\n" .. LLANG("Use Zebra Update?"), 30,
        LLANG("XXTouch"), LLANG("Not Now"), LLANG("Use Zebra Update"), LLANG("Skip This Version"))
    if choice == 2 then
        file.writes(XXT_HOME_PATH .. '/caches/.skiped-version', t.latest)
        return os.exit()
    elseif choice ~= 1 then
        return os.exit()
    end
    app.open_url("xyz.willy.Zebra", t.url)
end
