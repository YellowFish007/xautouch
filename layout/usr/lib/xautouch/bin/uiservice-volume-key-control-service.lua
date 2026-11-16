--[[

	安全模式下的音量键控制

	桌面插件无法运行需要使用这个守护程序来启停脚本

	本文件仅作为参考，请不要修改本文件
	本文件会在重装、更新时被原版覆盖

--]]

-- local pid_file = jbroot "/tmp/.xxtouch-uiservice-volume-key-control-service.singleton"

-- function service_pid(pid_file)
-- 	local pid = sys.getpid()
-- 	if not lockfile(pid_file) then
-- 		pid = 0
-- 		local f = io.open(pid_file, 'r')
-- 		if f then
-- 			pid = tonumber(f:read('a')) or 0
-- 			f:close()
-- 		end
-- 	end
-- 	return pid
-- end

-- local pid = service_pid(pid_file)

-- if pid == 0 then
-- 	sys.log("An unknown process locked the file `"..pid_file.."`")
-- 	os.exit(0)
-- elseif pid ~= sys.getpid() then
-- 	sys.kill(pid, 9)
-- 	os.exit(0)
-- end

watchdog_exit_handle = dispatch_source_register_callback("proc", sys.getppid(), DISPATCH_PROC_EXIT, function()
	root_start(XXT_EXE_PATH, "dofile", XXT_BIN_PATH .. "/launch.lua")
	watchdog_exit_handle:release()
	os.exit(0)
end)

local localization = require("localization")
local LLANG = localization.localizer(require("localization_catalogs").volume_key)

local function daemon_request_headers()
	return json.encode { ["Accept-Language"] = localization.current() }
end

local objc = require('objc')
local ffi = require('ffi')

ffi.cdef [[
	typedef void(*IOHIDEventSystemClientEventCallback)(void* target, void* refcon, id queue, id event);
	id IOHIDEventSystemClientCreate(void *);
	void IOHIDEventSystemClientScheduleWithRunLoop(id client, id runloop, id mode);
	void IOHIDEventSystemClientRegisterEventCallback(id client, IOHIDEventSystemClientEventCallback callback, void* target, void* refcon);
	void CFRunLoopRun();
	id CFRunLoopGetCurrent();
	id kCFRunLoopDefaultMode;
	int IOHIDEventGetType(id event);
	int IOHIDEventGetIntegerValue(id event, int field);
	typedef void (*CFNotificationCallback)(id center, void *observer, id name, const void *object, id userInfo);
	id CFNotificationCenterGetDarwinNotifyCenter();
	void CFNotificationCenterAddObserver(id center, const void *observer, CFNotificationCallback callBack, id name, const void *object, long suspensionBehavior);
	void CFNotificationCenterRemoveObserver(id center, const void *observer, id name, const void *object);
]]

local IOHIDEventGetIntegerValue = IOHIDEventGetIntegerValue
local CFRunLoopRun = ffi.C.CFRunLoopRun
local CFRunLoopGetCurrent = ffi.C.CFRunLoopGetCurrent
local CFNotificationCenterGetDarwinNotifyCenter = ffi.C.CFNotificationCenterGetDarwinNotifyCenter
local CFNotificationCenterAddObserver = ffi.C.CFNotificationCenterAddObserver

local kCFRunLoopDefaultMode = ffi.C.kCFRunLoopDefaultMode
local kIOHIDEventTypeDigitizer = 11
local kIOHIDEventTypeKeyboard = 3
local kIOHIDEventFieldKeyboardUsagePage = 196608
local kIOHIDEventFieldKeyboardUsage = 196609
local kIOHIDEventFieldKeyboardDown = 196610
local NULL = ffi.nullptr
local CFNotificationSuspensionBehaviorDeliverImmediately = 4
local mach_absolute_ms = mach_absolute_ms or sys.mtime

function script_is_running()
	local c, _, r = xxtouch.post('/is_running', daemon_request_headers())
	if c == 200 then
		r = json.decode(r) or { code = 0 }
		if r.code == 3 then
			local d = r.data or { is_script_paused = false }
			return true, d.is_script_paused
		elseif r.code == 9 then
			return false, true -- recording
		end
	else
		return false, false
	end
end

function script_start()
	local c, _, r = xxtouch.post("/launch_script_file", daemon_request_headers())
	if c == 200 then
		r = json.decode(r) or { code = -99, message = string.format(LLANG("Unknown error #%d"), -99) }
		if r.code ~= 0 then
			return false, r.message
		else
			return true
		end
	else
		return false, LLANG("❌ Failed to communicate with daemon\nService has not started yet, please wait...")
	end
end

function script_pause()
	local c, _, r = xxtouch.post('/pause_script', daemon_request_headers())
	if c == 200 then
		return (json.decode(r) or { code = -1 }).code == 0
	else
		return false
	end
end

function script_resume()
	local c, _, r = xxtouch.post('/resume_script', daemon_request_headers())
	if c == 200 then
		return (json.decode(r) or { code = -1 }).code == 0
	else
		return false
	end
end

function script_stop()
	local c, _, r = xxtouch.post('/stop_script', daemon_request_headers())
	if c == 200 then
		return (json.decode(r) or { code = -1 }).code == 0
	else
		return false
	end
end

function record_start()
	local c, _, r = xxtouch.post('/start_record', daemon_request_headers())
	if c == 200 then
		r = json.decode(r) or { code = -97, message = string.format(LLANG("Unknown error #%d"), -97) }
		if r.code ~= 0 then
			return false, r.message
		else
			return true
		end
	else
		return false
	end
end

function record_stop_save()
	local c, _, r = xxtouch.post('/stop_record_save', daemon_request_headers())
	if c == 200 then
		r = json.decode(r) or { code = -1 }
		if r.code == 0 then
			return r.data.filename
		else
			return nil
		end
	else
		return nil
	end
end

local alert_poped = false

local volume_down_down_ts = 0
local volume_up_down_ts = 0
local volume_up_down_event_uuid = nil
local volume_down_down_event_uuid = nil
local holding_event_uuids = {}

function run_or_stop()
	local is_running, is_paused_or_recording = script_is_running()
	if is_running then
		script_stop()
	else
		if is_paused_or_recording then
			local filename = record_stop_save()
			if filename then
				alert_poped = true
				sys.alert(string.format(LLANG("✅ Recording finished\nscript saved to `%s`"), filename), 0,
					LLANG("XXTouch"), LLANG("OK"))
				alert_poped = false
			end
		else
			local ok, err = script_start()
			if not ok then
				alert_poped = true
				sys.alert(err, 0, LLANG("XXTouch"), LLANG("OK"))
				alert_poped = false
			end
		end
	end
end

function pop_action_alert()
	local is_running, is_paused_or_recording = script_is_running()
	if is_running then
		if not is_paused_or_recording then
			script_pause()
			local choice = sys.alert(LLANG('⏩ Script is running...'), 0, LLANG("XXTouch"), LLANG("🚫 Cancel"),
				LLANG("⏸️ Pause"), LLANG("⏹️ Stop"))
			if choice == 0 then
				script_resume()
			elseif choice == 2 then
				script_stop()
			end
		else
			local choice = sys.alert(LLANG('⏸️ Script is pausing...'), 0, LLANG("XXTouch"), LLANG("🚫 Cancel"),
				LLANG("⏩ Resume"), LLANG("⏹️ Stop"))
			if choice == 1 then
				script_resume()
			elseif choice == 2 then
				script_stop()
			end
		end
	else
		local is_recording = is_paused_or_recording
		if is_recording then
			local filename = record_stop_save()
			if filename then
				sys.alert(string.format(LLANG("✅ Recording finished\nscript saved to `%s`"), filename), 0,
					LLANG("XXTouch"), LLANG("OK"))
			end
		else
			local choice = sys.alert(LLANG('Options'), 0, LLANG("XXTouch"), LLANG("🚫 Cancel"), LLANG("▶️ Launch"),
				LLANG("⏺️ Record"))
			if choice == 1 then
				local ok, err = script_start()
				if not ok then
					sys.alert(err, 0, LLANG("XXTouch"), LLANG("OK"))
				end
			elseif choice == 2 then
				local ok, err = record_start()
				if not ok then
					sys.alert(err, 0, LLANG("XXTouch"), LLANG("OK"))
				else
					sys.toast(LLANG("Start recording script"), { orien = device.front_orien(), allow_screenshot = true })
				end
			end
		end
	end
end

local script_control_pending = false
local function request_action_alert()
	if alert_poped or script_control_pending then
		return
	end
	script_control_pending = true
	alert_poped = true
	dispatch_async('concurrent', function()
		pcall(function()
			local c, _, r = xxtouch.post("/get_all_conf", daemon_request_headers())
			local conf = c == 200 and json.decode(r) or nil
			-- 转发到这里之前，用户可能已经关闭了快捷键。
			if c ~= 200 or (conf and conf.data and conf.data.device_control_toggle) then
				pop_action_alert()
			end
		end)
		dispatch_async('main', function()
			script_control_pending = false
			alert_poped = false
		end)
	end)
end

show_script_control_callback_handle = cpdistributed_messaging_center_register_callback(
	"xxtouch.volume-key-control-service", "show-script-control", function()
		request_action_alert()
		return { accepted = true }
	end)
cpdistributed_messaging_center_run_server_on_current_thread("xxtouch.volume-key-control-service")

event_callback_handle = hid_event_register_callback({
		event_types = {
			[kIOHIDEventTypeKeyboard] = true,
			[kIOHIDEventTypeDigitizer] = false,
		},
	},
	function(event)
		if alert_poped then
			return
		end
		local key_page = IOHIDEventGetIntegerValue(event, kIOHIDEventFieldKeyboardUsagePage)
		local key_code = IOHIDEventGetIntegerValue(event, kIOHIDEventFieldKeyboardUsage)
		local key_down = IOHIDEventGetIntegerValue(event, kIOHIDEventFieldKeyboardDown)
		if key_page ~= 12 or (key_code ~= 233 and key_code ~= 234) then
			return
		end
		local status = sb_ping_json()
		-- 旧插件只报告版本号，沿用它原有的分流规则，不能把缺少字段当成新插件退让。
		local legacy_springboard = status and status.volume_handler == "" and
			(sys.cfversion() < 1946 or sys.cfversion() >= 4000)
		if status and (status.volume_handler == "activator" or status.volume_handler == "springboard" or legacy_springboard) then
			-- 接管方变化时清掉已经排队的长按，避免旧监听补触发。
			volume_up_down_event_uuid = nil
			volume_down_down_event_uuid = nil
			holding_event_uuids = {}
			return
		end
		local is_volume_up_key = key_code == 233
		local is_volume_down_key = key_code == 234
		if key_down == 1 then
			local current_uuid = nil
			if is_volume_up_key then
				volume_up_down_ts = mach_absolute_ms()
				volume_up_down_event_uuid = utils.gen_uuid()
				current_uuid = volume_up_down_event_uuid
				holding_event_uuids[current_uuid] = true
			elseif is_volume_down_key then
				volume_down_down_ts = mach_absolute_ms()
				volume_down_down_event_uuid = utils.gen_uuid()
				current_uuid = volume_down_down_event_uuid
				holding_event_uuids[current_uuid] = true
			else
				return
			end
			dispatch_async('concurrent', function()
				local c, _, r = xxtouch.post("/get_all_conf", daemon_request_headers())
				if c ~= 200 then
					return
				end
				local conf = json.decode(r) or {}
				conf = conf.data or {}
				local hold_volume_up = conf.hold_volume_up or 2
				local hold_volume_down = conf.hold_volume_down or 2
				-- local click_volume_up = conf.click_volume_up or 2
				-- local click_volume_down = conf.click_volume_down or 2
				local device_control_toggle = conf.device_control_toggle or false
				if not device_control_toggle then
					return
				end
				dispatch_after(400, 'main', function()
					holding_event_uuids[current_uuid] = nil -- triggered
					if is_volume_up_key and volume_up_down_event_uuid == current_uuid then
						if hold_volume_up == 0 then
							request_action_alert()
						elseif hold_volume_up == 1 then
							dispatch_async('concurrent', function()
								run_or_stop()
							end)
						end
					elseif is_volume_down_key and volume_down_down_event_uuid == current_uuid then
						if hold_volume_down == 0 then
							request_action_alert()
						elseif hold_volume_down == 1 then
							dispatch_async('concurrent', function()
								run_or_stop()
							end)
						end
					end
				end)
			end)
		elseif key_down == 0 then
			local is_volume_up_hold_not_triggered = false
			local is_volume_down_hold_not_triggered = false
			local current_uuid = nil
			if is_volume_up_key then
				current_uuid = volume_up_down_event_uuid
				volume_up_down_event_uuid = nil -- holding stop
				if current_uuid then
					if holding_event_uuids[current_uuid] then
						is_volume_up_hold_not_triggered = true
						holding_event_uuids[current_uuid] = nil
					end
				end
			elseif is_volume_down_key then
				current_uuid = volume_down_down_event_uuid
				volume_down_down_event_uuid = nil -- holding stop
				if current_uuid then
					if holding_event_uuids[current_uuid] then
						is_volume_down_hold_not_triggered = true
						holding_event_uuids[current_uuid] = nil
					end
				end
			else
				return
			end
			dispatch_async('concurrent', function()
				local c, _, r = xxtouch.post("/get_all_conf", daemon_request_headers())
				if c ~= 200 then
					return
				end
				local conf = json.decode(r) or {}
				conf = conf.data or {}
				local click_volume_up = conf.click_volume_up or 2
				local click_volume_down = conf.click_volume_down or 2
				local device_control_toggle = conf.device_control_toggle or false
				if not device_control_toggle then
					return
				end
				if is_volume_up_key then
					if is_volume_up_hold_not_triggered then
						if click_volume_up == 0 then
							dispatch_async('main', request_action_alert)
						elseif click_volume_up == 1 then
							run_or_stop()
						end
					end
				elseif is_volume_down_key then
					if is_volume_down_hold_not_triggered then
						if click_volume_down == 0 then
							dispatch_async('main', request_action_alert)
						elseif click_volume_down == 1 then
							run_or_stop()
						end
					end
				end
			end)
		end
	end)

exit_callback_handle = notification_center_register_callback({
		center = "darwin",
		name = "xxtouch.uiservice-volume-key-control-service-exit",
	},
	function()
		exit_callback_handle:release()
		os.exit(0)
	end)

CFRunLoopRunWithAutoreleasePool()
