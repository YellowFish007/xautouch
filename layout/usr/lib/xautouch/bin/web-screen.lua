local json = require('cjson.safe')
local ev = require('ev')
local websocket = require('websocket')
local LLANG = require("localization").localizer({
    en = {
        connected = "Remote control connected", disconnected = "Remote control disconnected", timeout = "Remote control timed out", error = "Remote control connection error: %s",
        integer_required = "%s must be an integer", integer_range = "%s must be between %d and %d",
        mouse_not_connected = "Hardware mouse is not connected", mouse_event_failed = "Failed to send hardware mouse event",
        keyboard_connect_failed = "Failed to connect hardware keyboard", keyboard_disconnect_failed = "Failed to disconnect hardware keyboard",
        assistive_touch_state_failed = "Failed to read AssistiveTouch state", assistive_touch_restore_failed = "; failed to restore AssistiveTouch: %s",
        mouse_connect_failed = "Failed to connect hardware mouse", mouse_disconnect_failed = "Failed to disconnect hardware mouse",
    },
    ["zh-Hans"] = {
        connected = "已经建立远程控制连接", disconnected = "已断开远程控制连接", timeout = "远程控制连接已超时", error = "远程控制连接异常：%s",
        integer_required = "%s 必须是整数", integer_range = "%s 必须在 %d 到 %d 之间",
        mouse_not_connected = "硬件鼠标未连接", mouse_event_failed = "无法发送硬件鼠标事件",
        keyboard_connect_failed = "无法连接硬件键盘", keyboard_disconnect_failed = "无法断开硬件键盘",
        assistive_touch_state_failed = "无法读取辅助触控状态", assistive_touch_restore_failed = "；恢复辅助触控失败：%s",
        mouse_connect_failed = "无法连接硬件鼠标", mouse_disconnect_failed = "无法断开硬件鼠标",
    },
    ["zh-Hant"] = {
        connected = "已建立遠端控制連線", disconnected = "已中斷遠端控制連線", timeout = "遠端控制連線已逾時", error = "遠端控制連線異常：%s",
        integer_required = "%s 必須是整數", integer_range = "%s 必須介於 %d 到 %d 之間",
        mouse_not_connected = "硬體滑鼠尚未連線", mouse_event_failed = "無法傳送硬體滑鼠事件",
        keyboard_connect_failed = "無法連接硬體鍵盤", keyboard_disconnect_failed = "無法中斷硬體鍵盤連線",
        assistive_touch_state_failed = "無法讀取輔助觸控狀態", assistive_touch_restore_failed = "；還原輔助觸控失敗：%s",
        mouse_connect_failed = "無法連接硬體滑鼠", mouse_disconnect_failed = "無法中斷硬體滑鼠連線",
    },
    vi = {
        connected = "Đã kết nối điều khiển từ xa", disconnected = "Đã ngắt kết nối điều khiển từ xa", timeout = "Kết nối điều khiển từ xa đã hết thời gian", error = "Lỗi kết nối điều khiển từ xa: %s",
        integer_required = "%s phải là số nguyên", integer_range = "%s phải nằm trong khoảng từ %d đến %d",
        mouse_not_connected = "Chuột phần cứng chưa được kết nối", mouse_event_failed = "Không thể gửi sự kiện chuột phần cứng",
        keyboard_connect_failed = "Không thể kết nối bàn phím phần cứng", keyboard_disconnect_failed = "Không thể ngắt kết nối bàn phím phần cứng",
        assistive_touch_state_failed = "Không thể đọc trạng thái AssistiveTouch", assistive_touch_restore_failed = "; không thể khôi phục AssistiveTouch: %s",
        mouse_connect_failed = "Không thể kết nối chuột phần cứng", mouse_disconnect_failed = "Không thể ngắt kết nối chuột phần cứng",
    },
    ja = {
        connected = "リモートコントロールに接続しました", disconnected = "リモートコントロールから切断しました", timeout = "リモートコントロールがタイムアウトしました", error = "リモートコントロール接続エラー：%s",
        integer_required = "%s は整数でなければなりません", integer_range = "%s は %d から %d の範囲で指定してください",
        mouse_not_connected = "ハードウェアマウスが接続されていません", mouse_event_failed = "ハードウェアマウスイベントを送信できません",
        keyboard_connect_failed = "ハードウェアキーボードに接続できません", keyboard_disconnect_failed = "ハードウェアキーボードを切断できません",
        assistive_touch_state_failed = "AssistiveTouch の状態を読み取れません", assistive_touch_restore_failed = "；AssistiveTouch の復元に失敗しました：%s",
        mouse_connect_failed = "ハードウェアマウスに接続できません", mouse_disconnect_failed = "ハードウェアマウスを切断できません",
    },
    ko = {
        connected = "원격 제어에 연결되었습니다", disconnected = "원격 제어 연결이 해제되었습니다", timeout = "원격 제어 연결 시간이 초과되었습니다", error = "원격 제어 연결 오류: %s",
        integer_required = "%s은(는) 정수여야 합니다", integer_range = "%s은(는) %d에서 %d 사이여야 합니다",
        mouse_not_connected = "하드웨어 마우스가 연결되지 않았습니다", mouse_event_failed = "하드웨어 마우스 이벤트를 보낼 수 없습니다",
        keyboard_connect_failed = "하드웨어 키보드에 연결할 수 없습니다", keyboard_disconnect_failed = "하드웨어 키보드 연결을 해제할 수 없습니다",
        assistive_touch_state_failed = "AssistiveTouch 상태를 읽을 수 없습니다", assistive_touch_restore_failed = "; AssistiveTouch 복원 실패: %s",
        mouse_connect_failed = "하드웨어 마우스에 연결할 수 없습니다", mouse_disconnect_failed = "하드웨어 마우스 연결을 해제할 수 없습니다",
    },
    es = {
        connected = "Control remoto conectado", disconnected = "Control remoto desconectado", timeout = "Se agotó el tiempo del control remoto", error = "Error de conexión del control remoto: %s",
        integer_required = "%s debe ser un número entero", integer_range = "%s debe estar entre %d y %d",
        mouse_not_connected = "El ratón físico no está conectado", mouse_event_failed = "No se pudo enviar el evento del ratón físico",
        keyboard_connect_failed = "No se pudo conectar el teclado físico", keyboard_disconnect_failed = "No se pudo desconectar el teclado físico",
        assistive_touch_state_failed = "No se pudo leer el estado de AssistiveTouch", assistive_touch_restore_failed = "; no se pudo restaurar AssistiveTouch: %s",
        mouse_connect_failed = "No se pudo conectar el ratón físico", mouse_disconnect_failed = "No se pudo desconectar el ratón físico",
    },
    ["pt-BR"] = {
        connected = "Controle remoto conectado", disconnected = "Controle remoto desconectado", timeout = "O controle remoto expirou", error = "Erro de conexão do controle remoto: %s",
        integer_required = "%s deve ser um número inteiro", integer_range = "%s deve estar entre %d e %d",
        mouse_not_connected = "O mouse físico não está conectado", mouse_event_failed = "Falha ao enviar o evento do mouse físico",
        keyboard_connect_failed = "Falha ao conectar o teclado físico", keyboard_disconnect_failed = "Falha ao desconectar o teclado físico",
        assistive_touch_state_failed = "Falha ao ler o estado do AssistiveTouch", assistive_touch_restore_failed = "; falha ao restaurar o AssistiveTouch: %s",
        mouse_connect_failed = "Falha ao conectar o mouse físico", mouse_disconnect_failed = "Falha ao desconectar o mouse físico",
    },
    ru = {
        connected = "Удалённое управление подключено", disconnected = "Удалённое управление отключено", timeout = "Время ожидания удалённого управления истекло", error = "Ошибка подключения удалённого управления: %s",
        integer_required = "%s должно быть целым числом", integer_range = "%s должно быть в диапазоне от %d до %d",
        mouse_not_connected = "Аппаратная мышь не подключена", mouse_event_failed = "Не удалось отправить событие аппаратной мыши",
        keyboard_connect_failed = "Не удалось подключить аппаратную клавиатуру", keyboard_disconnect_failed = "Не удалось отключить аппаратную клавиатуру",
        assistive_touch_state_failed = "Не удалось прочитать состояние AssistiveTouch", assistive_touch_restore_failed = "; не удалось восстановить AssistiveTouch: %s",
        mouse_connect_failed = "Не удалось подключить аппаратную мышь", mouse_disconnect_failed = "Не удалось отключить аппаратную мышь",
    },
    fr = {
        connected = "Contrôle à distance connecté", disconnected = "Contrôle à distance déconnecté", timeout = "Délai du contrôle à distance dépassé", error = "Erreur de connexion du contrôle à distance : %s",
        integer_required = "%s doit être un entier", integer_range = "%s doit être compris entre %d et %d",
        mouse_not_connected = "La souris physique n’est pas connectée", mouse_event_failed = "Impossible d’envoyer l’événement de la souris physique",
        keyboard_connect_failed = "Impossible de connecter le clavier physique", keyboard_disconnect_failed = "Impossible de déconnecter le clavier physique",
        assistive_touch_state_failed = "Impossible de lire l’état d’AssistiveTouch", assistive_touch_restore_failed = " ; impossible de restaurer AssistiveTouch : %s",
        mouse_connect_failed = "Impossible de connecter la souris physique", mouse_disconnect_failed = "Impossible de déconnecter la souris physique",
    },
    de = {
        connected = "Fernsteuerung verbunden", disconnected = "Fernsteuerung getrennt", timeout = "Zeitüberschreitung der Fernsteuerung", error = "Verbindungsfehler der Fernsteuerung: %s",
        integer_required = "%s muss eine Ganzzahl sein", integer_range = "%s muss zwischen %d und %d liegen",
        mouse_not_connected = "Hardwaremaus ist nicht verbunden", mouse_event_failed = "Hardwaremaus-Ereignis konnte nicht gesendet werden",
        keyboard_connect_failed = "Hardwaretastatur konnte nicht verbunden werden", keyboard_disconnect_failed = "Hardwaretastatur konnte nicht getrennt werden",
        assistive_touch_state_failed = "AssistiveTouch-Status konnte nicht gelesen werden", assistive_touch_restore_failed = "; AssistiveTouch konnte nicht wiederhergestellt werden: %s",
        mouse_connect_failed = "Hardwaremaus konnte nicht verbunden werden", mouse_disconnect_failed = "Hardwaremaus konnte nicht getrennt werden",
    },
})

local mainloop = ev.Loop.default
local lifetime = 15
local dev_w, dev_h = screen.size()

local down_keys = {}
local down_fingers = {}
local web_mouse
local web_mouse_enabled_assistive_touch = false

local web_keyboard_properties = {
    VendorID = 0x5858,
    ProductID = 0x0002,
    Product = 'XXTouch Remote Keyboard',
    Manufacturer = 'XXTouch',
    SerialNumber = 'xxtouch-web-screen',
    Transport = 'USB',
    HIDVirtualDevice = false,
}

local web_mouse_properties = {
    VendorID = 0x5858,
    ProductID = 0x0006,
    Product = 'XXTouch Remote Mouse',
    Manufacturer = 'XXTouch',
    SerialNumber = 'xxtouch-web-screen-mouse',
    Transport = 'USB',
    HIDVirtualDevice = false,
}

local keycodemap = {
    [48] = { 0x07, 39 }, [49] = { 0x07, 30 }, [50] = { 0x07, 31 }, [51] = { 0x07, 32 }, [52] = { 0x07, 33 },
    [53] = { 0x07, 34 }, [54] = { 0x07, 35 }, [55] = { 0x07, 36 }, [56] = { 0x07, 37 }, [57] = { 0x07, 38 },
    [65] = { 0x07, 4 }, [66] = { 0x07, 5 }, [67] = { 0x07, 6 }, [68] = { 0x07, 7 }, [69] = { 0x07, 8 },
    [70] = { 0x07, 9 }, [71] = { 0x07, 10 }, [72] = { 0x07, 11 }, [73] = { 0x07, 12 }, [74] = { 0x07, 13 },
    [75] = { 0x07, 14 }, [76] = { 0x07, 15 }, [77] = { 0x07, 16 }, [78] = { 0x07, 17 }, [79] = { 0x07, 18 },
    [80] = { 0x07, 19 }, [81] = { 0x07, 20 }, [82] = { 0x07, 21 }, [83] = { 0x07, 22 }, [84] = { 0x07, 23 },
    [85] = { 0x07, 24 }, [86] = { 0x07, 25 }, [87] = { 0x07, 26 }, [88] = { 0x07, 27 }, [89] = { 0x07, 28 },
    [90] = { 0x07, 29 }, [13] = { 0x07, 40 }, [27] = { 0x07, 41 }, [8] = { 0x07, 42 }, [9] = { 0x07, 43 },
    [32] = { 0x07, 44 }, [189] = { 0x07, 45 }, [187] = { 0x07, 46 }, [219] = { 0x07, 47 }, [221] = { 0x07, 48 },
    [220] = { 0x07, 49 }, [186] = { 0x07, 51 }, [222] = { 0x07, 52 }, [192] = { 0x07, 53 }, [188] = { 0x07, 54 },
    [190] = { 0x07, 55 }, [191] = { 0x07, 56 }, [20] = { 0x07, 57 }, [112] = { 0x07, 58 }, [113] = { 0x07, 59 },
    [114] = { 0x07, 60 }, [115] = { 0x07, 61 }, [116] = { 0x07, 62 }, [117] = { 0x07, 63 }, [118] = { 0x07, 64 },
    [119] = { 0x07, 65 }, [120] = { 0x07, 66 }, [121] = { 0x07, 67 }, [122] = { 0x07, 68 }, [123] = { 0x07, 69 },
    [145] = { 0x07, 71 }, [19] = { 0x07, 72 }, [45] = { 0x07, 73 }, [36] = { 0x07, 74 }, [33] = { 0x07, 75 },
    [46] = { 0x07, 76 }, [35] = { 0x07, 77 }, [34] = { 0x07, 78 }, [39] = { 0x07, 79 }, [37] = { 0x07, 80 },
    [40] = { 0x07, 81 }, [38] = { 0x07, 82 }, [17] = { 0x07, 224 }, [16] = { 0x07, 225 }, [18] = { 0x07, 226 },
    [91] = { 0x07, 227 }, [92] = { 0x07, 231 }, [144] = { 0x07, 83 }, [111] = { 0x07, 84 }, [106] = { 0x07, 85 },
    [109] = { 0x07, 86 }, [107] = { 0x07, 87 }, [96] = { 0x07, 98 }, [97] = { 0x07, 89 }, [98] = { 0x07, 90 },
    [99] = { 0x07, 91 }, [100] = { 0x07, 92 }, [101] = { 0x07, 93 }, [102] = { 0x07, 94 }, [103] = { 0x07, 95 },
    [104] = { 0x07, 96 }, [105] = { 0x07, 97 }, [110] = { 0x07, 99 },
}

local toast_allow_screenshot = false
if sys.xtversion and type(sys.xtversion) == 'function' then
    local version = sys.xtversion()
    if version and version.compare_version then
        toast_allow_screenshot = version:compare_version("1.3.8-20250917173810") >= 0
    end
end

if toast_allow_screenshot then
    local orig_sys_toast = sys.toast
    sys.toast = function(msg)
        orig_sys_toast(msg, { allow_screenshot = true })
    end
end

local function wait_ms(ms, func)
    ev.Timer.new(func, ms / 1000, 0):start(mainloop)
end

local function after_run(ms, func, ...)
    local args = { ... }
    assert(type(ms) == 'number', 'after_run: ms must be a number')
    assert(type(func) == 'function', 'after_run: func must be a function')

    local func_chain = {
        { ms = ms, func = func, args = args }
    }
    local current_index = 1
    local last_results = args
    local chain = {}

    local runner
    runner = function()
        local current = func_chain[current_index]
        if type(current) == 'table' and type(current.func) == 'function' then
            local current_args = last_results
            if #current.args > 0 then
                current_args = current.args
                if #last_results > 0 then
                    table.move(last_results, 1, #last_results, #current_args + 1, current_args)
                end
            end
            last_results = { current.func(table.unpack(current_args)) }
        end
        current_index = current_index + 1
        local next_func = func_chain[current_index]
        if type(next_func) == 'table' and type(next_func.func) == 'function' then
            wait_ms(next_func.ms, runner)
        end
    end

    wait_ms(ms, runner)

    chain.after_run = function(next_ms, next_func, ...)
        local next_args = { ... }
        assert(type(next_ms) == 'number', 'after_run: ms must be a number')
        assert(type(next_func) == 'function', 'after_run: func must be a function')
        table.insert(func_chain, {
            ms = next_ms,
            func = next_func,
            args = next_args
        })
        return chain
    end

    return chain
end

local function clamp_number(value, min_v, max_v)
    if value < min_v then
        return min_v
    end
    if value > max_v then
        return max_v
    end
    return value
end

local function sanitize_bool(value, fallback)
    if type(value) == 'boolean' then
        return value
    end
    if type(value) == 'number' then
        return value ~= 0
    end
    if type(value) == 'string' then
        local lower = string.lower(value)
        if lower == '1' or lower == 'true' then
            return true
        end
        if lower == '0' or lower == 'false' then
            return false
        end
    end
    return fallback
end

local function sanitize_number(value, fallback, min_v, max_v)
    local num = tonumber(value)
    if not num or num ~= num or num == math.huge or num == -math.huge then
        num = fallback
    end
    if min_v ~= nil then
        num = math.max(min_v, num)
    end
    if max_v ~= nil then
        num = math.min(max_v, num)
    end
    return num
end

local function normalize_rotate_quarter(value)
    value = math.floor(tonumber(value) or 0) % 4
    if value < 0 then
        value = value + 4
    end
    return value
end

local function to_finger_id(fid)
    fid = math.floor(tonumber(fid or 28) or 28)
    if fid < 1 or fid > 30 then
        fid = 28
    end
    return fid
end

local function clamp_touch_x(value)
    return clamp_number(tonumber(value) or 0, 0, math.max(dev_w - 1, 0))
end

local function clamp_touch_y(value)
    return clamp_number(tonumber(value) or 0, 0, math.max(dev_h - 1, 0))
end

local function norm_to_abs_x(value)
    return clamp_number((tonumber(value) or 0) * dev_w, 0, math.max(dev_w - 1, 0))
end

local function norm_to_abs_y(value)
    return clamp_number((tonumber(value) or 0) * dev_h, 0, math.max(dev_h - 1, 0))
end

local function release_stored_key(store_key)
    local stored = down_keys[store_key]
    if not stored then
        return
    end
    down_keys[store_key] = nil
    if stored.kind == 'pair' then
        key.up(stored.a, stored.b)
    elseif stored.kind == 'single' then
        key.up(stored.key)
    end
end

local function press_named_key(code)
    if type(code) ~= 'string' or code == '' then
        return
    end
    key.press(code)
end

local function down_named_key(code)
    if type(code) ~= 'string' or code == '' then
        return
    end
    down_keys['named:' .. code] = {
        kind = 'single',
        key = code
    }
    key.down(code)
end

local function up_named_key(code)
    if type(code) ~= 'string' or code == '' then
        return
    end
    release_stored_key('named:' .. code)
end

local function press_legacy_key(keycode)
    local mapped = keycodemap[math.floor(tonumber(keycode or -1) or -1)]
    if mapped then
        key.press(mapped[1], mapped[2])
        return true
    end
    return false
end

local function down_legacy_key(keycode)
    local mapped = keycodemap[math.floor(tonumber(keycode or -1) or -1)]
    local store_key
    if not mapped then
        return false
    end
    store_key = 'legacy:' .. tostring(math.floor(tonumber(keycode) or -1))
    down_keys[store_key] = {
        kind = 'pair',
        a = mapped[1],
        b = mapped[2]
    }
    key.down(mapped[1], mapped[2])
    return true
end

local function up_legacy_key(keycode)
    local numeric = math.floor(tonumber(keycode or -1) or -1)
    local store_key = 'legacy:' .. tostring(numeric)
    if down_keys[store_key] then
        release_stored_key(store_key)
        return true
    end
    local mapped = keycodemap[numeric]
    if mapped then
        key.up(mapped[1], mapped[2])
        return true
    end
    return false
end

local function restore_web_mouse_assistive_touch()
    if not web_mouse_enabled_assistive_touch then
        return true
    end

    local ok, restore_error = pcall(device.assistive_touch_off)
    if not ok then
        return false, restore_error
    end
    web_mouse_enabled_assistive_touch = false
    return true
end

local function current_web_mouse()
    if not web_mouse then
        return nil
    end

    local ok, connected = pcall(function()
        return web_mouse:is_connected()
    end)
    if ok and connected then
        return web_mouse
    end

    local stale_mouse = web_mouse
    web_mouse = nil
    pcall(function()
        stale_mouse:disconnect()
    end)
    restore_web_mouse_assistive_touch()
    return nil
end

local function disconnect_web_mouse()
    local connected_mouse = web_mouse
    web_mouse = nil
    local disconnected = true
    local disconnect_error
    if connected_mouse then
        local ok
        ok, disconnected, disconnect_error = pcall(function()
            return connected_mouse:disconnect()
        end)
        if not ok then
            disconnect_error = disconnected
            disconnected = false
        elseif disconnected == false then
            disconnect_error = disconnect_error or
                'failed to disconnect hardware mouse'
        end
    end

    local restored, restore_error = restore_web_mouse_assistive_touch()
    if not disconnected then
        return false, disconnect_error
    end
    if not restored then
        return false, restore_error
    end
    return true
end

local function cleanup_exit(code)
    local key_ids = {}
    local finger_ids = {}
    local index
    for key_id, _ in pairs(down_keys) do
        table.insert(key_ids, key_id)
    end
    for fid, _ in pairs(down_fingers) do
        table.insert(finger_ids, fid)
    end
    for index = 1, #key_ids do
        release_stored_key(key_ids[index])
    end
    for index = 1, #finger_ids do
        down_fingers[finger_ids[index]] = nil
        touch.up(finger_ids[index])
    end
    disconnect_web_mouse()
    pcall(key.disconnect_global_keyboard)
    sys.msleep(150)
    os.exit(code or 0)
end

local WHEEL_FINGER = 29
local WHEEL_DELTA_UNIT = 100
local WHEEL_CAP = 0.75
local WHEEL_MIN_RATIO = 0.35
local WHEEL_CLAMP_FACTOR = 2.5
local WHEEL_DURK = 0.00016
local WHEEL_DURMIN_MS = 50
local WHEEL_DURMAX_MS = 800
local WHEEL_BRAKE_OVERSHOOT_PX = 5
local WHEEL_BRAKE_STEP_PX = 1
local WHEEL_BRAKE_INTERVAL_MS = 15

local wheel_state = {
    accum = 0,
    flush_scheduled = false,
    flush_token = 0,
    drag_token = 0,
    anchor_x = 0,
    anchor_y = 0,
    rotate_quarter = 0,
    natural = true,
    step_px = 48,
    coalesce_ms = 60,
    amp = 0.18,
    dur_base_ms = 50,
    release_delay_ms = 120,
    brake_enabled = false,
    brake_reverse_px = 5,
}

local function release_wheel_finger()
    if down_fingers[WHEEL_FINGER] then
        down_fingers[WHEEL_FINGER] = nil
        touch.up(WHEEL_FINGER)
    end
end

local function wheel_chain_move(chain, drag_token, delay_ms, px, py)
    return chain.after_run(delay_ms, function(next_x, next_y)
        if drag_token ~= wheel_state.drag_token or not down_fingers[WHEEL_FINGER] then
            return
        end
        touch.move(WHEEL_FINGER, next_x, next_y)
    end, px, py)
end

local function wheel_append_brake(chain, drag_token, end_x, end_y, dx, dy)
    if not wheel_state.brake_enabled then
        return chain, end_x, end_y
    end

    local distance = math.sqrt(dx * dx + dy * dy)
    if distance < 0.01 then
        return chain, end_x, end_y
    end

    local unit_x = dx / distance
    local unit_y = dy / distance
    local current_x = end_x
    local current_y = end_y
    local index

    for index = 1, WHEEL_BRAKE_OVERSHOOT_PX do
        local next_x = clamp_number(current_x + unit_x * WHEEL_BRAKE_STEP_PX, 0, math.max(dev_w - 1, 0))
        local next_y = clamp_number(current_y + unit_y * WHEEL_BRAKE_STEP_PX, 0, math.max(dev_h - 1, 0))
        if math.abs(next_x - current_x) < 0.01 and math.abs(next_y - current_y) < 0.01 then
            break
        end
        current_x = next_x
        current_y = next_y
        chain = wheel_chain_move(chain, drag_token, WHEEL_BRAKE_INTERVAL_MS, current_x, current_y)
    end

    for index = 1, wheel_state.brake_reverse_px do
        local next_x = clamp_number(current_x - unit_x * WHEEL_BRAKE_STEP_PX, 0, math.max(dev_w - 1, 0))
        local next_y = clamp_number(current_y - unit_y * WHEEL_BRAKE_STEP_PX, 0, math.max(dev_h - 1, 0))
        if math.abs(next_x - current_x) < 0.01 and math.abs(next_y - current_y) < 0.01 then
            break
        end
        current_x = next_x
        current_y = next_y
        chain = wheel_chain_move(chain, drag_token, WHEEL_BRAKE_INTERVAL_MS, current_x, current_y)
    end

    return chain, current_x, current_y
end

local function wheel_run_drag(start_x, start_y, end_x, end_y, duration_ms)
    wheel_state.drag_token = wheel_state.drag_token + 1
    local drag_token = wheel_state.drag_token
    local dx = end_x - start_x
    local dy = end_y - start_y
    local distance = math.sqrt(dx * dx + dy * dy)
    local steps = math.max(3, math.min(8, math.floor(distance / 24 + 0.5)))
    local interval_ms = math.max(8, math.floor(duration_ms / steps))
    local chain
    local release_x = end_x
    local release_y = end_y
    local index

    release_wheel_finger()

    down_fingers[WHEEL_FINGER] = true
    touch.down(WHEEL_FINGER, start_x, start_y)

    chain = after_run(interval_ms, function(px, py)
        if drag_token ~= wheel_state.drag_token or not down_fingers[WHEEL_FINGER] then
            return
        end
        touch.move(WHEEL_FINGER, px, py)
    end, start_x + dx / steps, start_y + dy / steps)

    for index = 2, steps do
        chain = wheel_chain_move(chain, drag_token, interval_ms, start_x + dx * (index / steps), start_y + dy * (index / steps))
    end

    chain, release_x, release_y = wheel_append_brake(chain, drag_token, end_x, end_y, dx, dy)
    chain.after_run(wheel_state.release_delay_ms, function(px, py)
        if drag_token ~= wheel_state.drag_token then
            return
        end
        down_fingers[WHEEL_FINGER] = nil
        touch.up(WHEEL_FINGER, px, py)
    end, release_x, release_y)
end

local function wheel_flush()
    local take_raw = wheel_state.accum
    local step_px
    local mag
    local amp_factor
    local take
    local min_take
    local abs_clamp
    local dx = 0
    local dy = 0
    local start_x
    local start_y
    local end_x
    local end_y
    local duration_ms

    wheel_state.accum = 0
    if math.abs(take_raw) < 0.01 then
        return
    end

    step_px = math.max(wheel_state.step_px, 1) * screen.scale_factor()
    mag = math.abs(take_raw)
    amp_factor = 1 + math.min(WHEEL_CAP, wheel_state.amp * math.log(1 + mag / step_px))
    take = take_raw * amp_factor
    min_take = WHEEL_MIN_RATIO * step_px
    if math.abs(take) < min_take then
        take = (take >= 0 and 1 or -1) * min_take
    end

    abs_clamp = step_px * WHEEL_CLAMP_FACTOR
    take = clamp_number(take, -abs_clamp, abs_clamp)

    if wheel_state.rotate_quarter == 0 then
        dy = take
    elseif wheel_state.rotate_quarter == 1 then
        dx = take
    elseif wheel_state.rotate_quarter == 2 then
        dy = -take
    else
        dx = -take
    end

    start_x = clamp_number(wheel_state.anchor_x, 0, math.max(dev_w - 1, 0))
    start_y = clamp_number(wheel_state.anchor_y, 0, math.max(dev_h - 1, 0))
    end_x = clamp_number(start_x + dx, 0, math.max(dev_w - 1, 0))
    end_y = clamp_number(start_y + dy, 0, math.max(dev_h - 1, 0))

    duration_ms = wheel_state.dur_base_ms + (WHEEL_DURK * 1000) * math.sqrt(math.abs(take))
    duration_ms = clamp_number(duration_ms, WHEEL_DURMIN_MS, WHEEL_DURMAX_MS)

    wheel_run_drag(start_x, start_y, end_x, end_y, duration_ms)
end

local function wheel_schedule_flush()
    local flush_token
    if wheel_state.flush_scheduled then
        return
    end
    wheel_state.flush_scheduled = true
    wheel_state.flush_token = wheel_state.flush_token + 1
    flush_token = wheel_state.flush_token
    wait_ms(wheel_state.coalesce_ms, function()
        if flush_token ~= wheel_state.flush_token then
            return
        end
        wheel_state.flush_scheduled = false
        wheel_flush()
    end)
end

local function wheel_apply_event(jobj)
    local anchor_x = tonumber(jobj.x)
    local anchor_y = tonumber(jobj.y)
    local delta_y = tonumber(jobj.deltaY)
    local enabled
    local natural
    local brake_enabled
    local step_px
    local coalesce_ms
    local amp
    local dur_base_ms
    local release_delay_ms
    local brake_reverse_px
    local delta_px

    if not anchor_x or not anchor_y or not delta_y or delta_y == 0 then
        return
    end

    enabled = sanitize_bool(jobj.enabled, true)
    natural = sanitize_bool(jobj.natural, true)
    brake_enabled = sanitize_bool(jobj.brakeEnabled, false)
    step_px = sanitize_number(jobj.stepPx, 48, 5, 1000)
    coalesce_ms = sanitize_number(jobj.coalesceMs, 60, 0, 200)
    amp = sanitize_number(jobj.amp, 0.18, 0, 5)
    dur_base_ms = sanitize_number(jobj.durBaseMs, 50, 0, 800)
    release_delay_ms = sanitize_number(jobj.releaseDelayMs, 120, 0, 500)
    brake_reverse_px = sanitize_number(jobj.brakeReversePx, 5, 2, 20)
    if not enabled or step_px <= 0 then
        return
    end

    if sanitize_bool(jobj.norm, false) then
        anchor_x = norm_to_abs_x(anchor_x)
        anchor_y = norm_to_abs_y(anchor_y)
    end

    delta_px = (delta_y / WHEEL_DELTA_UNIT) * step_px
    if natural then
        delta_px = -delta_px
    end
    if delta_px == 0 then
        return
    end

    wheel_state.anchor_x = clamp_number(anchor_x, 0, math.max(dev_w - 1, 0))
    wheel_state.anchor_y = clamp_number(anchor_y, 0, math.max(dev_h - 1, 0))
    wheel_state.rotate_quarter = normalize_rotate_quarter(jobj.rotateQuarter)
    wheel_state.natural = natural
    wheel_state.step_px = step_px
    wheel_state.coalesce_ms = coalesce_ms
    wheel_state.amp = amp
    wheel_state.dur_base_ms = dur_base_ms
    wheel_state.release_delay_ms = release_delay_ms
    wheel_state.brake_enabled = brake_enabled
    wheel_state.brake_reverse_px = brake_reverse_px
    wheel_state.accum = wheel_state.accum + delta_px

    wheel_schedule_flush()
end

local function cancel_touch_wheel()
    wheel_state.accum = 0
    wheel_state.flush_scheduled = false
    wheel_state.flush_token = wheel_state.flush_token + 1
    wheel_state.drag_token = wheel_state.drag_token + 1
    release_wheel_finger()
end

local function bounded_integer(value, field_name, minimum, maximum)
    if type(value) ~= 'number' or value ~= value or
        value == math.huge or value == -math.huge then
        return nil, string.format(LLANG('integer_required'), field_name)
    end

    local integer = math.tointeger(value)
    if not integer then
        return nil, string.format(LLANG('integer_required'), field_name)
    end
    if integer < minimum or integer > maximum then
        return nil, string.format(
            LLANG('integer_range'), field_name, minimum, maximum)
    end
    return integer
end

local mode_router = {}

local function send_hardware_keyboard_state(ws, action, ok, message)
    local payload = {
        mode = 'hardware-keyboard-state',
        action = action,
        ok = ok,
        connected = key.get_global_keyboard() ~= nil,
    }
    local encoded
    if message then
        payload.message = tostring(message)
    end
    encoded = json.encode(payload)
    if encoded then
        pcall(function()
            ws:send(encoded)
        end)
    end
end

local function send_hardware_mouse_state(ws, action, ok, message)
    local payload = {
        mode = 'hardware-mouse-state',
        action = action,
        ok = ok,
        connected = current_web_mouse() ~= nil,
    }
    local encoded
    if message then
        payload.message = tostring(message)
    end
    encoded = json.encode(payload)
    if encoded then
        pcall(function()
            ws:send(encoded)
        end)
    end
end

local function send_hardware_mouse_input(
    ws, action, method_name, ...)
    local connected_mouse = current_web_mouse()
    if not connected_mouse then
        send_hardware_mouse_state(
            ws, action, false, LLANG('mouse_not_connected'))
        return
    end

    local method = connected_mouse[method_name]
    local ok, sent, send_error = pcall(method, connected_mouse, ...)
    if not ok then
        send_hardware_mouse_state(ws, action, false, sent)
    elseif sent == false then
        send_hardware_mouse_state(
            ws, action, false,
            send_error or LLANG('mouse_event_failed'))
    end
end

mode_router['touch-down'] = function(_, jobj)
    local fid = to_finger_id(jobj.finger)
    down_fingers[fid] = true
    touch.down(fid, clamp_touch_x(jobj.x), clamp_touch_y(jobj.y))
end

mode_router['touch-move'] = function(_, jobj)
    local fid = to_finger_id(jobj.finger)
    down_fingers[fid] = true
    touch.move(fid, clamp_touch_x(jobj.x), clamp_touch_y(jobj.y))
end

mode_router['touch-up'] = function(_, jobj)
    local fid = to_finger_id(jobj.finger)
    down_fingers[fid] = nil
    if jobj.x and jobj.y then
        touch.up(fid, clamp_touch_x(jobj.x), clamp_touch_y(jobj.y))
    else
        touch.up(fid)
    end
end

mode_router['norm-touch-down'] = function(_, jobj)
    local fid = to_finger_id(jobj.finger)
    down_fingers[fid] = true
    touch.down(fid, norm_to_abs_x(jobj.x), norm_to_abs_y(jobj.y))
end

mode_router['norm-touch-move'] = function(_, jobj)
    local fid = to_finger_id(jobj.finger)
    down_fingers[fid] = true
    touch.move(fid, norm_to_abs_x(jobj.x), norm_to_abs_y(jobj.y))
end

mode_router['norm-touch-up'] = function(_, jobj)
    local fid = to_finger_id(jobj.finger)
    down_fingers[fid] = nil
    if jobj.x and jobj.y then
        touch.up(fid, norm_to_abs_x(jobj.x), norm_to_abs_y(jobj.y))
    else
        touch.up(fid)
    end
end

mode_router['wheel'] = function(_, jobj)
    if current_web_mouse() then
        return
    end
    wheel_apply_event(jobj)
end

mode_router['key-press'] = function(_, jobj)
    if jobj.code then
        press_named_key(jobj.code)
    end
end

mode_router['key-down'] = function(_, jobj)
    if jobj.code then
        down_named_key(jobj.code)
    end
end

mode_router['key-up'] = function(_, jobj)
    if jobj.code then
        up_named_key(jobj.code)
    end
end

mode_router['input'] = function(_, jobj)
    if jobj.key then
        press_legacy_key(jobj.key)
    end
end

mode_router['input_down'] = function(_, jobj)
    if jobj.key then
        down_legacy_key(jobj.key)
    end
end

mode_router['input_up'] = function(_, jobj)
    if jobj.key then
        up_legacy_key(jobj.key)
    end
end

mode_router['hardware-keyboard-status'] = function(ws)
    send_hardware_keyboard_state(ws, 'status', true)
end

mode_router['hardware-keyboard-connect'] = function(ws)
    local ok
    local keyboard
    local connect_error
    if key.get_global_keyboard() then
        send_hardware_keyboard_state(ws, 'connect', true)
        return
    end

    ok, keyboard, connect_error =
        pcall(key.connect_global_keyboard, web_keyboard_properties)
    if not ok then
        send_hardware_keyboard_state(ws, 'connect', false, keyboard)
    elseif not keyboard then
        send_hardware_keyboard_state(
            ws, 'connect', false,
            connect_error or LLANG('keyboard_connect_failed'))
    else
        send_hardware_keyboard_state(ws, 'connect', true)
    end
end

mode_router['hardware-keyboard-disconnect'] = function(ws)
    local ok
    local disconnected
    local disconnect_error
    ok, disconnected, disconnect_error =
        pcall(key.disconnect_global_keyboard)
    if not ok then
        send_hardware_keyboard_state(
            ws, 'disconnect', false, disconnected)
    elseif disconnected == false then
        send_hardware_keyboard_state(
            ws, 'disconnect', false,
            disconnect_error or LLANG('keyboard_disconnect_failed'))
    else
        send_hardware_keyboard_state(ws, 'disconnect', true)
    end
end

mode_router['hardware-mouse-status'] = function(ws)
    send_hardware_mouse_state(ws, 'status', true)
end

mode_router['hardware-mouse-connect'] = function(ws)
    local connected_mouse = current_web_mouse()
    if connected_mouse then
        cancel_touch_wheel()
        send_hardware_mouse_state(ws, 'connect', true)
        return
    end

    local state_ok, assistive_touch_was_on =
        pcall(device.is_assistive_touch_on)
    if not state_ok or type(assistive_touch_was_on) ~= 'boolean' then
        send_hardware_mouse_state(
            ws, 'connect', false,
            state_ok and LLANG('assistive_touch_state_failed') or assistive_touch_was_on)
        return
    end

    if not assistive_touch_was_on then
        local enabled, enable_error = pcall(device.assistive_touch_on)
        if not enabled then
            send_hardware_mouse_state(ws, 'connect', false, enable_error)
            return
        end
        web_mouse_enabled_assistive_touch = true
    end

    local ok, created_mouse, connect_error =
        pcall(mouse.connect, web_mouse_properties)
    if not ok then
        local restored, restore_error = restore_web_mouse_assistive_touch()
        local message = created_mouse
        if not restored then
            message = tostring(message) ..
                string.format(LLANG('assistive_touch_restore_failed'), tostring(restore_error))
        end
        send_hardware_mouse_state(ws, 'connect', false, message)
    elseif not created_mouse then
        local restored, restore_error = restore_web_mouse_assistive_touch()
        local message = connect_error or LLANG('mouse_connect_failed')
        if not restored then
            message = tostring(message) ..
                string.format(LLANG('assistive_touch_restore_failed'), tostring(restore_error))
        end
        send_hardware_mouse_state(
            ws, 'connect', false, message)
    else
        web_mouse = created_mouse
        cancel_touch_wheel()
        send_hardware_mouse_state(ws, 'connect', true)
    end
end

mode_router['hardware-mouse-disconnect'] = function(ws)
    local disconnected, disconnect_error = disconnect_web_mouse()
    local message
    if not disconnected then
        message = disconnect_error or LLANG('mouse_disconnect_failed')
    end
    send_hardware_mouse_state(
        ws, 'disconnect', disconnected, message)
end

mode_router['hardware-mouse-move'] = function(ws, jobj)
    local dx, input_error = bounded_integer(jobj.dx, 'dx', -2047, 2047)
    if not dx then
        send_hardware_mouse_state(ws, 'move', false, input_error)
        return
    end
    local dy
    dy, input_error = bounded_integer(jobj.dy, 'dy', -2047, 2047)
    if not dy then
        send_hardware_mouse_state(ws, 'move', false, input_error)
        return
    end
    send_hardware_mouse_input(ws, 'move', 'move', dx, dy)
end

mode_router['hardware-mouse-down'] = function(ws, jobj)
    local button, input_error =
        bounded_integer(jobj.button, 'button', 1, 2)
    if not button then
        send_hardware_mouse_state(ws, 'down', false, input_error)
        return
    end
    send_hardware_mouse_input(ws, 'down', 'down', button)
end

mode_router['hardware-mouse-up'] = function(ws, jobj)
    local button, input_error =
        bounded_integer(jobj.button, 'button', 1, 2)
    if not button then
        send_hardware_mouse_state(ws, 'up', false, input_error)
        return
    end
    send_hardware_mouse_input(ws, 'up', 'up', button)
end

mode_router['hardware-mouse-scroll'] = function(ws, jobj)
    local dx, input_error = bounded_integer(jobj.dx, 'dx', -127, 127)
    if not dx then
        send_hardware_mouse_state(ws, 'scroll', false, input_error)
        return
    end
    local dy
    dy, input_error = bounded_integer(jobj.dy, 'dy', -127, 127)
    if not dy then
        send_hardware_mouse_state(ws, 'scroll', false, input_error)
        return
    end
    send_hardware_mouse_input(ws, 'scroll', 'scroll', dx, dy)
end

mode_router['home'] = function()
    key.press(0x0C, 64)
end

mode_router['power'] = function()
    key.press(0x0C, 48)
end

mode_router['heart'] = function()
end

mode_router['quit'] = function()
    sys.toast(LLANG('disconnected'))
    cleanup_exit(0)
end

mode_router['down'] = mode_router['touch-down']
mode_router['move'] = mode_router['touch-move']
mode_router['up'] = mode_router['touch-up']

local server = websocket.server.ev.listen {
    protocols = {
        ['RC'] = function(ws)
            local closed = false
            local heartbeat_timer

            local function safe_exit(code, message)
                if closed then
                    return
                end
                closed = true
                if heartbeat_timer then
                    pcall(function()
                        heartbeat_timer:stop(mainloop)
                    end)
                    heartbeat_timer = nil
                end
                if message then
                    sys.toast(message)
                end
                cleanup_exit(code or 0)
            end

            sys.toast(LLANG('connected'))

            heartbeat_timer = ev.Timer.new(function()
                if lifetime <= 0 then
                    safe_exit(0, LLANG('timeout'))
                    return
                end
                lifetime = lifetime - 1
                pcall(function()
                    ws:send(json.encode({ mode = 'heart' }))
                end)
            end, 1, 1)
            heartbeat_timer:start(mainloop)

            ws:on_message(function(_, message, opcode)
                local jobj
                if closed or opcode ~= websocket.TEXT then
                    return
                end
                jobj = json.decode(message)
                if type(jobj) == 'table' and type(jobj.mode) == 'string' then
                    lifetime = 15
                    if type(mode_router[jobj.mode]) == 'function' then
                        mode_router[jobj.mode](ws, jobj)
                    end
                end
            end)

            ws:on_close(function()
                safe_exit(0, LLANG('disconnected'))
            end)

            ws:on_error(function(_, err)
                safe_exit(0, string.format(LLANG('error'), tostring(err)))
            end)
        end
    },
    port = 46968
}

mainloop:loop()
