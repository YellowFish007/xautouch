local lfs = require("lfs")
local json = require("cjson.safe")

local runtime_profile = rawget(_G, "XXT_RUNTIME_PROFILE")
local runtime_home = rawget(_G, "XXT_HOME_PATH") or
    (type(runtime_profile) == "table" and runtime_profile.home) or os.getenv("XXT_HOME_PATH")
assert(type(runtime_home) == "string" and runtime_home ~= "", "XXT runtime profile is unavailable")
local CONF_PATH = XXT_CONF_FILE_NAME or
    (type(runtime_profile) == "table" and runtime_profile.config) or runtime_home .. "/1ferver.conf"
local RULES_PATH = (XXT_CACHES_PATH or runtime_home .. "/caches") .. "/ui-elerthelper.rules"
local LOG_PATH = (XXT_LOG_PATH or runtime_home .. "/log") .. "/ui-elerthelper.log"
local LOG_LAST_PATH = LOG_PATH .. ".last"
local RELOAD_NOTIFY_NAME = "xxtouch.ui-elerthelper/reload"
local EXIT_NOTIFY_NAME = "xxtouch.ui-elerthelper/exit"
local SINGLETON_PATH = jbroot("/tmp/.xxtouch.ui-elerthelper.singleton")

local OBSERVE_TOKENS = { "system_overlay_changed", "dialog_changed" }
local BUILD_DELAY_MS = 180
local QUEUED_BUILD_DELAY_MS = 80
local DEFAULT_CLICK_WAIT_MS = 0
local DEFAULT_TEXT_FIELD_WAIT_MS = 300
local CLICK_COOLDOWN_MS = 250
local TEXT_FIELD_COOLDOWN_MS = 1200
local UNMATCHED_COOLDOWN_MS = 120
local FULL_SCAN_RETRY_DELAY_MS = 120
local MAX_HIT_ELEMENTS = 80
local OBSERVER_RETRY_INTERVAL_MS = 2000
local OBSERVER_RETRY_LOG_INTERVAL_MS = 30000
local LOG_MAX_BYTES = 2 * 1024 * 1024
local LOG_KEEP_BYTES = 1 * 1024 * 1024

local rules = {}
local rules_mtime = false
local bad_rules_mtime
local observer
local busy = false
-- 连续权限弹窗可能堆叠显示；后到事件代表当前顶层弹窗。
local pending_event
local event_generation = 0
local last_unknown_key = ""
local last_unknown_ms = 0
local last_observer_error = ""
local last_observer_log_ms = 0
local exiting = false
local reload_handle
local exit_handle

local function read_conf()
	local conf = json.decode(file.reads(CONF_PATH) or "")
	return type(conf) == "table" and conf or {}
end

local function service_enabled()
	return read_conf().ui_elerthelper == true
end

if not service_enabled() then
	notify_post(EXIT_NOTIFY_NAME)
	return
end

local lock_fd = lockfile(SINGLETON_PATH)
if not lock_fd then
	return
end

local ui_builtin = require("ui_element_builtin")

local function ensure_parent_dir(path)
	local dir = path:match("^(.*)/[^/]+$")
	if dir and dir ~= "" then
		sys.mkdir_p(dir)
	end
end

ensure_parent_dir(LOG_PATH)

local function join(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		parts[#parts + 1] = value == nil and "nil" or tostring(value)
	end
	return table.concat(parts, " ")
end

local function log_size()
	local ok, attr = pcall(lfs.attributes, LOG_PATH)
	if ok and type(attr) == "table" then
		return tonumber(attr.size) or 0
	end
	return 0
end

local function trim_first_partial_line(data)
	local newline = type(data) == "string" and data:find("\n", 1, true) or nil
	if newline then
		return data:sub(newline + 1)
	end
	return ""
end

local function split_tail_at_line(data, keep_bytes)
	if type(data) ~= "string" or data == "" then
		return "", ""
	end
	if #data <= keep_bytes then
		return "", data
	end

	local split_at = #data - keep_bytes
	local newline = data:find("\n", split_at + 1, true)
	if not newline and split_at > 1 then
		local reversed = data:sub(1, split_at):reverse()
		local reversed_newline = reversed:find("\n", 1, true)
		if reversed_newline then
			newline = split_at - reversed_newline + 1
		end
	end
	if not newline then
		return data, ""
	end
	return data:sub(1, newline), data:sub(newline + 1)
end

local function write_file(path, data)
	local f = io.open(path, "wb")
	if not f then
		return false
	end
	f:write(data or "")
	f:close()
	return true
end

local function rotate_log_if_needed(incoming_bytes)
	local size = log_size()
	if size <= 0 or size + (tonumber(incoming_bytes) or 0) <= LOG_MAX_BYTES then
		return
	end

	local f = io.open(LOG_PATH, "rb")
	if not f then
		return
	end
	local segment_start = math.max(0, size - LOG_MAX_BYTES)
	f:seek("set", segment_start)
	local data = f:read("*a") or ""
	f:close()

	if segment_start > 0 then
		data = trim_first_partial_line(data)
	end

	local last_data, current_data = split_tail_at_line(data, LOG_KEEP_BYTES)
	if last_data ~= "" then
		write_file(LOG_LAST_PATH, last_data)
	else
		os.remove(LOG_LAST_PATH)
	end
	write_file(LOG_PATH, current_data)
end

local function log(...)
	local line = string.format("%s %s\n", os.date("%Y-%m-%d %H:%M:%S"), join(...))
	rotate_log_if_needed(#line)
	local f = io.open(LOG_PATH, "a")
	if f then
		f:write(line)
		f:close()
	end
	print("[ui-elerthelper]", join(...))
end

local function exit_service(reason)
	if exiting then
		return
	end
	exiting = true
	log("stopping", reason or "requested")
	if observer then
		observer:close()
		observer = nil
	end
	if reload_handle then
		reload_handle:release()
		reload_handle = nil
	end
	if exit_handle then
		exit_handle:release()
		exit_handle = nil
	end
	if type(unlockfilefd) == "function" then
		pcall(unlockfilefd, lock_fd)
	end
	-- fcntl 锁绑定 inode，删除路径会让后续实例在新 inode 上重新加锁。
	os.exit(0)
end

local function string_value(value)
	if type(value) == "string" then
		return value
	elseif type(value) == "number" or type(value) == "boolean" then
		return tostring(value)
	end
	return ""
end

local function trim_text(value)
	return string_value(value):gsub("^%s+", ""):gsub("%s+$", "")
end

local function split_text_lines(value)
	local lines = {}
	for line in string_value(value):gmatch("[^\r\n]+") do
		lines[#lines + 1] = trim_text(line)
	end
	return lines
end

local function is_status_bar_text(text)
	text = trim_text(text)
	local lower = text:lower()
	return text == ""
		or text:match("^%d%d?:%d%d$") ~= nil
		or text:find("电池电量", 1, true) ~= nil
		or text:find("无线局域网信号", 1, true) ~= nil
		or text:find("蜂窝网络信号", 1, true) ~= nil
		or lower:find("cellular signal", 1, true) ~= nil
		or lower:find("wi-fi signal", 1, true) ~= nil
		or lower:find("battery level", 1, true) ~= nil
		or lower:find("battery power", 1, true) ~= nil
end

local function normalize_system_alert_text(alert)
	if type(alert) ~= "table" or alert.systemAlert ~= true then
		return alert
	end
	local title = trim_text(alert.title)
	local message = string_value(alert.message)
	if title ~= "" and not is_status_bar_text(title) and not message:find("电池电量", 1, true) and not message:find("无线局域网信号", 1, true) then
		return alert
	end

	local button_texts = {}
	for _, button in ipairs(alert.buttons or {}) do
		button_texts[trim_text(button.text)] = true
	end

	local filtered = {}
	local seen = {}
	for _, source in ipairs({ alert.title, alert.message }) do
		for _, line in ipairs(split_text_lines(source)) do
			if line ~= "" and not is_status_bar_text(line) and not button_texts[line] and not seen[line] then
				filtered[#filtered + 1] = line
				seen[line] = true
			end
		end
	end

	if #filtered > 0 then
		alert.title = filtered[1]
		local message_parts = {}
		for i = 2, #filtered do
			message_parts[#message_parts + 1] = filtered[i]
		end
		alert.message = table.concat(message_parts, "\n")
	end
	return alert
end

local function pattern_match(value, pattern)
	if type(pattern) ~= "string" then
		return true
	end
	return string_value(value):find(pattern) ~= nil
end

local function table_is_array(t)
	return type(t) == "table" and #t > 0
end

local function rect_of(ele)
	if type(ele) ~= "table" then
		return nil
	end
	local x = tonumber(ele.x)
	local y = tonumber(ele.y)
	local w = tonumber(ele.width)
	local h = tonumber(ele.height)
	if not x or not y or not w or not h or w <= 1 or h <= 1 then
		return nil
	end
	return { x = x, y = y, width = w, height = h }
end

local function center_of(ele, fallback_x, fallback_y)
	local p = type(ele) == "table" and ele.centerPoint or nil
	if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then
		return math.floor(p.x + 0.5), math.floor(p.y + 0.5)
	end
	local r = rect_of(ele)
	if r then
		return math.floor(r.x + r.width * 0.5 + 0.5),
			math.floor(r.y + r.height * 0.5 + 0.5)
	end
	return fallback_x, fallback_y
end

local function text_of(ele)
	if type(ele) ~= "table" then
		return ""
	end
	local text = string_value(ele.text)
	if text ~= "" then
		return text
	end
	text = string_value(ele.value)
	if text ~= "" then
		return text
	end
	return string_value(ele.hint)
end

local function current_front_bundle()
	local ok, bid = pcall(app.front_bid)
	if ok and type(bid) == "string" then
		return bid
	end
	return ""
end

local function traits_of(ele)
	return type(ele) == "table" and type(ele.traitsDescription) == "table" and ele.traitsDescription or {}
end

local function has_trait(ele, name)
	for _, trait in ipairs(traits_of(ele)) do
		if trait == name then
			return true
		end
	end
	return false
end

local function is_button(ele)
	return text_of(ele) ~= "" and has_trait(ele, "Button")
end

local function is_field(ele)
	if type(ele) ~= "table" then
		return false
	end
	return ele.hasTextEntry == true
		or has_trait(ele, "TextEntry")
		or has_trait(ele, "SearchField")
		or has_trait(ele, "SecureTextField")
		or has_trait(ele, "TextArea")
end

local function element_key(ele)
	local r = rect_of(ele)
	if not r then
		return nil
	end
	return table.concat({
		text_of(ele),
		math.floor(r.x + 0.5),
		math.floor(r.y + 0.5),
		math.floor(r.width + 0.5),
		math.floor(r.height + 0.5),
		string_value(ele.traits),
	}, "|")
end

local function event_anchor_key(event)
	local ele = type(event) == "table" and event.element or nil
	if type(ele) ~= "table" or text_of(ele) == "" or not rect_of(ele) then
		return nil
	end
	return element_key(ele)
end

local function should_replace_pending_event(current, incoming)
	if not current then
		return true
	end
	local current_token = tonumber(current.token) or 0
	local incoming_token = tonumber(incoming.token) or 0
	if current_token == 1018 and incoming_token == 1006 then
		local current_key = event_anchor_key(current)
		local incoming_key = event_anchor_key(incoming)
		if not incoming_key or incoming_key == current_key then
			return false
		end
	end
	return true
end

local function set_pending_event(event)
	event._ui_elerthelper_received_ms = event._ui_elerthelper_received_ms or sys.mtime()
	if not should_replace_pending_event(pending_event, event) then
		return event_generation
	end
	pending_event = event
	event_generation = event_generation + 1
	return event_generation
end

local function safe_release(value, seen)
	if type(value) ~= "table" then
		return
	end
	seen = seen or {}
	if seen[value] then
		return
	end
	seen[value] = true
	-- 先处理子表，避免父表释放时清理字段后丢失数字索引里的句柄。
	for _, item in pairs(value) do
		safe_release(item, seen)
	end
	if type(ui_builtin.release) == "function" then
		pcall(ui_builtin.release, value)
	end
end

local function sort_by_position(a, b)
	local ar = rect_of(a.element or a) or { x = 0, y = 0 }
	local br = rect_of(b.element or b) or { x = 0, y = 0 }
	if math.abs(ar.y - br.y) > 8 then
		return ar.y < br.y
	end
	return ar.x < br.x
end

local function hit_at(x, y, pid)
	local opts = { max_level = 1, include_handle = true }
	if pid and pid > 0 then
		opts.pid = pid
	end
	local ok, ele = pcall(ui_builtin.text_element_at_position, math.floor(x + 0.5), math.floor(y + 0.5), opts)
	if ok and type(ele) == "table" and rect_of(ele) then
		return ele
	end
	return nil
end

local function add_hit(elements, seen, x, y, pid)
	local ele = hit_at(x, y, pid)
	if not ele then
		return 0
	end
	local key = element_key(ele)
	if key and not seen[key] then
		seen[key] = true
		elements[#elements + 1] = ele
	else
		safe_release(ele)
	end
	return 1
end

local function anchor_still_visible(anchor, pid)
	local x, y = center_of(anchor)
	if not x or not y then
		return false
	end
	local hit = hit_at(x, y, pid)
	if not hit then
		return false
	end
	local visible = element_key(hit) == element_key(anchor)
	safe_release(hit)
	return visible
end

local function anchor_matches_front_app(anchor)
	local bundle = type(anchor) == "table" and string_value(anchor.bundleId) or ""
	local front_bundle = current_front_bundle()
	return bundle ~= "" and front_bundle ~= "" and bundle == front_bundle
end

local function scan_grid(elements, seen, x1, x2, y1, y2, xratios, ystep, pid)
	y1 = math.max(0, math.floor(y1 + 0.5))
	y2 = math.max(y1, math.floor(y2 + 0.5))
	ystep = math.max(8, math.floor(ystep + 0.5))
	for y = y1, y2, ystep do
		for _, ratio in ipairs(xratios) do
			if #elements >= MAX_HIT_ELEMENTS then
				return
			end
			local x = x1 + (x2 - x1) * ratio
			add_hit(elements, seen, x, y, pid)
		end
	end
end

local function scan_vertical_line(elements, seen, x, y1, y2, ystep, pid)
	y1 = math.max(0, math.floor(y1 + 0.5))
	y2 = math.max(y1, math.floor(y2 + 0.5))
	ystep = math.max(8, math.floor(ystep + 0.5))
	for y = y1, y2, ystep do
		if #elements >= MAX_HIT_ELEMENTS then
			return
		end
		add_hit(elements, seen, x, y, pid)
	end
end

local function add_unique_y(rows, y, sh)
	y = tonumber(y)
	if not y then
		return
	end
	y = math.min(sh - 1, math.max(0, math.floor(y + 0.5)))
	for _, existing in ipairs(rows) do
		if math.abs(existing - y) < 18 then
			return
		end
	end
	rows[#rows + 1] = y
end

local function scan_rows(elements, seen, x1, x2, rows, xratios, pid)
	table.sort(rows)
	for _, y in ipairs(rows) do
		for _, ratio in ipairs(xratios) do
			if #elements >= MAX_HIT_ELEMENTS then
				return
			end
			add_hit(elements, seen, x1 + (x2 - x1) * ratio, y, pid)
		end
	end
end

local function row_candidates_from_elements(elements, bounds, sh)
	local rows = {}
	local bottom
	for _, ele in ipairs(elements) do
		local r = rect_of(ele)
		if r and text_of(ele) ~= "" and r.height < sh * 0.96 then
			add_unique_y(rows, r.y + r.height * 0.5, sh)
			bottom = math.max(bottom or 0, r.y + r.height)
		end
	end
	if bottom then
		add_unique_y(rows, bottom + 28, sh)
		add_unique_y(rows, bottom + 72, sh)
		add_unique_y(rows, bottom + 116, sh)
	end
	if bounds then
		add_unique_y(rows, bounds.y1 + 44, sh)
		add_unique_y(rows, bounds.y2 - 44, sh)
		add_unique_y(rows, bounds.y2 - 88, sh)
	end
	return rows
end

local function estimate_dialog_bounds(anchor, elements, fallback_x1, fallback_x2)
	local anchor_rect = rect_of(anchor)
	if not anchor_rect then
		return nil
	end

	local sw, sh = screen.size()
	local anchor_center_y = anchor_rect.y + anchor_rect.height * 0.5
	local candidates = {}
	local band_x1 = fallback_x1 - 32
	local band_x2 = fallback_x2 + 32
	local max_width = (fallback_x2 - fallback_x1) + 96
	for _, ele in ipairs(elements) do
		local r = rect_of(ele)
		if r and text_of(ele) ~= "" then
			local cx = r.x + r.width * 0.5
			if cx >= band_x1 and cx <= band_x2 and r.width <= max_width and r.height < sh * 0.96 then
				candidates[#candidates + 1] = r
			end
		end
	end
	candidates[#candidates + 1] = anchor_rect

	table.sort(candidates, function(a, b)
		if math.abs(a.y - b.y) > 4 then
			return a.y < b.y
		end
		return a.x < b.x
	end)

	local best_index = 1
	local best_distance = math.huge
	for index, r in ipairs(candidates) do
		local top_distance = math.abs(anchor_center_y - r.y)
		local bottom_distance = math.abs(anchor_center_y - (r.y + r.height))
		local center_distance = math.abs(anchor_center_y - (r.y + r.height * 0.5))
		local distance = math.min(top_distance, bottom_distance, center_distance)
		if anchor_center_y >= r.y and anchor_center_y <= r.y + r.height then
			distance = 0
		end
		if distance < best_distance then
			best_index = index
			best_distance = distance
		end
	end

	local gap_limit = math.max(96, math.min(190, sh * 0.14))
	local first = best_index
	while first > 1 do
		local prev = candidates[first - 1]
		local current = candidates[first]
		local gap = current.y - (prev.y + prev.height)
		if gap > gap_limit then
			break
		end
		first = first - 1
	end

	local last = best_index
	while last < #candidates do
		local current = candidates[last]
		local next_rect = candidates[last + 1]
		local gap = next_rect.y - (current.y + current.height)
		if gap > gap_limit then
			break
		end
		last = last + 1
	end

	local min_x = fallback_x1
	local max_x = fallback_x2
	local min_y = anchor_rect.y
	local max_y = anchor_rect.y + anchor_rect.height
	for index = first, last do
		local r = candidates[index]
		min_x = math.min(min_x, r.x)
		max_x = math.max(max_x, r.x + r.width)
		min_y = math.min(min_y, r.y)
		max_y = math.max(max_y, r.y + r.height)
	end

	return {
		x1 = math.max(0, min_x - 24),
		x2 = math.min(sw - 1, max_x + 24),
		y1 = math.max(0, min_y - 36),
		y2 = math.min(sh - 1, max_y + 44),
	}
end

local function filter_elements_in_bounds(elements, bounds)
	if not bounds then
		return elements
	end
	local filtered = {}
	for _, ele in ipairs(elements) do
		local r = rect_of(ele)
		local cx = r and (r.x + r.width * 0.5) or nil
		local cy = r and (r.y + r.height * 0.5) or nil
		if cx and cy and cx >= bounds.x1 and cx <= bounds.x2 and cy >= bounds.y1 and cy <= bounds.y2 then
			filtered[#filtered + 1] = ele
		else
			safe_release(ele)
		end
	end
	return filtered
end

local function scan_near_anchor(anchor, pid, mode)
	local r = rect_of(anchor)
	if not r then
		return {}
	end

	local sw, sh = screen.size()
	local cx = r.x + r.width * 0.5
	local width = math.min(math.max(r.width + 140, sw * 0.72), sw - 20)
	local x1 = math.max(0, cx - width * 0.5)
	local x2 = math.min(sw - 1, cx + width * 0.5)

	local elements = {}
	local seen = {}

	if mode == "fast" then
		scan_vertical_line(elements, seen, cx, 0, sh - 1, 48, pid)
		local bounds = estimate_dialog_bounds(anchor, elements, x1, x2)
		local rows = row_candidates_from_elements(elements, bounds, sh)
		scan_rows(elements, seen, x1, x2, rows, { 0.18, 0.34, 0.50, 0.66, 0.82 }, pid)
		bounds = estimate_dialog_bounds(anchor, elements, x1, x2)
		if bounds then
			elements = filter_elements_in_bounds(elements, bounds)
		end
		return elements
	end

	scan_grid(elements, seen, x1, x2, 0, sh - 1, { 0.12, 0.25, 0.38, 0.50, 0.62, 0.75, 0.88 }, 42, pid)
	local bounds = estimate_dialog_bounds(anchor, elements, x1, x2)
	if bounds then
		scan_grid(elements, seen, bounds.x1, bounds.x2, bounds.y1, bounds.y2, { 0.10, 0.22, 0.34, 0.46, 0.58, 0.70, 0.82, 0.90 }, 28, pid)
		elements = filter_elements_in_bounds(elements, bounds)
	end

	return elements
end

local function bundle_from(elements, fallback, use_front_fallback)
	if type(fallback) == "string" and fallback ~= "" then
		return fallback
	end
	for _, ele in ipairs(elements) do
		if type(ele.bundleId) == "string" and ele.bundleId ~= "" then
			return ele.bundleId
		end
	end
	if use_front_fallback ~= false then
		return current_front_bundle()
	end
	return ""
end

local function springboard_state()
	if type(ui_builtin.springboard_state) ~= "function" then
		return nil
	end
	local ok, state = pcall(ui_builtin.springboard_state)
	if ok and type(state) == "table" then
		return state
	end
	return nil
end

local function field_info(ele)
	return {
		text = text_of(ele),
		placeholder = string_value(ele.hint) ~= "" and string_value(ele.hint) or text_of(ele),
		value = string_value(ele.value),
		element = ele,
	}
end

local function button_info(ele)
	local x, y = center_of(ele)
	return {
		text = text_of(ele),
		x = x,
		y = y,
		element = ele,
	}
end

local function build_alert(event, opts)
	local anchor = type(event.element) == "table" and event.element or nil
	if not anchor or text_of(anchor) == "" or not rect_of(anchor) then
		return nil
	end
	opts = type(opts) == "table" and opts or {}

	local pid = tonumber(event.element_pid) or 0
	local elements = scan_near_anchor(anchor, pid, opts.scan_mode)
	local anchor_key = element_key(anchor)
	local has_anchor = false
	for _, ele in ipairs(elements) do
		if anchor_key and element_key(ele) == anchor_key then
			has_anchor = true
			break
		end
	end
	if not has_anchor and opts.allow_front_app_anchor and anchor_matches_front_app(anchor) then
		elements[#elements + 1] = anchor
		has_anchor = true
	elseif not has_anchor and (opts.allow_stale_anchor ~= false or anchor_still_visible(anchor, pid)) then
		elements[#elements + 1] = anchor
		has_anchor = true
	end
	table.sort(elements, sort_by_position)

	local buttons = {}
	local fields = {}
	local texts = {}
	for _, ele in ipairs(elements) do
		local text = text_of(ele)
		if text ~= "" then
			if is_button(ele) then
				buttons[#buttons + 1] = button_info(ele)
			elseif is_field(ele) then
				fields[#fields + 1] = field_info(ele)
			else
				texts[#texts + 1] = ele
			end
		end
	end
	table.sort(buttons, sort_by_position)
	table.sort(fields, sort_by_position)
	table.sort(texts, sort_by_position)

	local title = text_of(texts[1]) ~= "" and text_of(texts[1]) or text_of(anchor)
	local message_parts = {}
	for i = 2, #texts do
		local text = text_of(texts[i])
		if text ~= "" and text ~= title then
			message_parts[#message_parts + 1] = text
		end
	end

	local alert = {
		pid = pid,
		bundle = bundle_from(elements, anchor.bundleId),
		hostBundle = bundle_from(elements, anchor.bundleId, false),
		frontBundle = current_front_bundle(),
		title = title,
		message = table.concat(message_parts, "\n"),
		buttons = buttons,
		textFields = fields,
		anchor = anchor,
		_elements = elements,
		_event = event,
		_received_ms = tonumber(event._ui_elerthelper_received_ms) or sys.mtime(),
	}
	local sb_state = springboard_state()
	if sb_state then
		alert.systemAlert = sb_state.systemAlert
		alert.systemAppFrontmost = sb_state.systemAppFrontmost
		alert.focusedAppPID = sb_state.focusedAppPID
		alert.topEventPidOverride = sb_state.topEventPidOverride
	end
	if type(event.token) == "number" then
		alert.eventToken = event.token
	end
	if type(event.token_name) == "string" then
		alert.eventTokenName = event.token_name
	end

	normalize_system_alert_text(alert)
	return alert
end

local function build_current_alert()
	local sb_state = springboard_state() or {}
	local pid = tonumber(sb_state.focusedAppPID) or 0
	local sw, sh = screen.size()
	local elements = {}
	local seen = {}
	scan_grid(elements, seen, 0, sw - 1, 0, sh - 1, { 0.18, 0.34, 0.50, 0.66, 0.82 }, 48, pid)
	table.sort(elements, sort_by_position)

	local buttons = {}
	local fields = {}
	local texts = {}
	for _, ele in ipairs(elements) do
		local text = text_of(ele)
		if text ~= "" then
			if is_button(ele) then
				buttons[#buttons + 1] = button_info(ele)
			elseif is_field(ele) then
				fields[#fields + 1] = field_info(ele)
			else
				texts[#texts + 1] = ele
			end
		end
	end
	table.sort(buttons, sort_by_position)
	table.sort(fields, sort_by_position)
	table.sort(texts, sort_by_position)

	if #buttons == 0 or #buttons > 6 or (#texts == 0 and #fields == 0) then
		safe_release(elements)
		return nil
	end

	local title = text_of(texts[1])
	local message_parts = {}
	for i = 2, #texts do
		local text = text_of(texts[i])
		if text ~= "" and text ~= title then
			message_parts[#message_parts + 1] = text
		end
	end

	local now = sys.mtime()
	local alert = {
		pid = pid,
		bundle = bundle_from(elements),
		hostBundle = bundle_from(elements, nil, false),
		frontBundle = current_front_bundle(),
		title = title,
		message = table.concat(message_parts, "\n"),
		buttons = buttons,
		textFields = fields,
		_elements = elements,
		_event = {
			token_name = "current",
			_ui_elerthelper_received_ms = now,
		},
		_received_ms = now,
		systemAlert = sb_state.systemAlert,
		systemAppFrontmost = sb_state.systemAppFrontmost,
		focusedAppPID = sb_state.focusedAppPID,
		topEventPidOverride = sb_state.topEventPidOverride,
		eventTokenName = "current",
	}
	normalize_system_alert_text(alert)
	return alert
end

local function alert_summary(alert)
	local button_texts = {}
	for _, button in ipairs(alert.buttons or {}) do
		button_texts[#button_texts + 1] = button.text
	end
	return string.format("pid=%s bundle=%s hostBundle=%s frontBundle=%s systemAlert=%s focusedPID=%s event=%s title=%q message=%q buttons=[%s] textFields=%d",
		tostring(alert.pid),
		tostring(alert.bundle),
		tostring(alert.hostBundle),
		tostring(alert.frontBundle),
		tostring(alert.systemAlert),
		tostring(alert.focusedAppPID),
		tostring(alert.eventTokenName or alert.eventToken),
		tostring(alert.title),
		tostring(alert.message),
		table.concat(button_texts, ","),
		#(alert.textFields or {}))
end

local function alert_elapsed_ms(alert)
	local started = tonumber(alert and alert._received_ms)
	if not started then
		return nil
	end
	return math.max(0, sys.mtime() - started)
end

local function match_buttons(condition, buttons)
	if condition == nil then
		return true
	end
	if type(condition) == "number" then
		return #buttons == condition
	end
	if type(condition) == "string" then
		for _, button in ipairs(buttons) do
			if pattern_match(button.text, condition) then
				return true
			end
		end
		return false
	end
	if type(condition) == "table" then
		if #condition ~= #buttons then
			return false
		end
		for i, pattern in ipairs(condition) do
			if not pattern_match(buttons[i] and buttons[i].text or "", tostring(pattern)) then
				return false
			end
		end
		return true
	end
	return false
end

local function match_fields(condition, fields)
	if condition == nil then
		return true
	end
	if type(condition) == "number" then
		return #fields == condition
	end
	if type(condition) == "string" then
		for _, field in ipairs(fields) do
			if pattern_match(field.placeholder, condition)
				or pattern_match(field.text, condition)
				or pattern_match(field.value, condition) then
				return true
			end
		end
		return false
	end
	if type(condition) == "table" then
		if #condition ~= #fields then
			return false
		end
		for i, pattern in ipairs(condition) do
			local field = fields[i]
			if not field
				or (
					not pattern_match(field.placeholder, tostring(pattern))
					and not pattern_match(field.text, tostring(pattern))
					and not pattern_match(field.value, tostring(pattern))
				) then
				return false
			end
		end
		return true
	end
	return false
end

local function match_rule(rule, alert)
	local conditions = type(rule.conditions) == "table" and rule.conditions or {}
	if type(conditions.pid) == "number" and alert.pid ~= conditions.pid then
		return false
	end
	if type(conditions.bundle) == "string" and (alert.bundle == "" or not pattern_match(alert.bundle, conditions.bundle)) then
		return false
	end
	if type(conditions.hostBundle) == "string" and (alert.hostBundle == "" or not pattern_match(alert.hostBundle, conditions.hostBundle)) then
		return false
	end
	if type(conditions.frontBundle) == "string" and (alert.frontBundle == "" or not pattern_match(alert.frontBundle, conditions.frontBundle)) then
		return false
	end
	if type(conditions.systemAlert) == "boolean" and alert.systemAlert ~= conditions.systemAlert then
		return false
	end
	if type(conditions.title) == "string" and not pattern_match(alert.title, conditions.title) then
		return false
	end
	if type(conditions.message) == "string" and not pattern_match(alert.message, conditions.message) then
		return false
	end
	if not match_buttons(conditions.buttons, alert.buttons or {}) then
		return false
	end
	if not match_fields(conditions.textFields, alert.textFields or {}) then
		return false
	end
	return true
end

local function find_button(alert, target)
	if type(target) == "number" then
		return alert.buttons[target]
	end
	if type(target) == "string" then
		for _, button in ipairs(alert.buttons or {}) do
			if button.text == target then
				return button
			end
		end
	end
	return nil
end

local function copy_current_matching_hit(ele, pid)
	local x, y = center_of(ele)
	if not x or not y then
		return nil, "target has no actionable point"
	end
	local hit = hit_at(x, y, pid)
	if not hit then
		return nil, "target is not hittable"
	end
	if element_key(hit) ~= element_key(ele) then
		safe_release(hit)
		return nil, "target is not hittable or changed"
	end
	return hit
end

local function click_current_element(ele, pid)
	if type(ele) ~= "table" then
		return false, "target unavailable", {}
	end
	local started_ms = sys.mtime()
	local target, err = copy_current_matching_hit(ele, pid)
	local hit_ms = sys.mtime() - started_ms
	if not target then
		return false, err, { hit_ms = hit_ms }
	end
	local click_started_ms = sys.mtime()
	local ok, ret_or_err = pcall(ui_builtin.click, target, { pid = pid, max_level = 1, async = true })
	local click_ms = sys.mtime() - click_started_ms
	safe_release(target)
	if ok and ret_or_err then
		return true, nil, { hit_ms = hit_ms, click_ms = click_ms }
	end
	return false, tostring(ret_or_err), { hit_ms = hit_ms, click_ms = click_ms }
end

local function set_field_text(field, value, pid)
	if type(field) ~= "table" or type(field.element) ~= "table" then
		return false, "field unavailable"
	end
	local focused, focus_err = click_current_element(field.element, pid)
	if focused then
		sys.msleep(250)
	else
		log("textFields", "focus skipped:", focus_err)
	end
	local text = tostring(value or "")
	local ok, ret_or_err = pcall(ui_builtin.set_text, field.element, text, { max_level = 1 })
	if ok and ret_or_err then
		return true
	end
	pcall(ui_builtin.clear_text, field.element, { max_level = 1 })
	local fallback_ok, fallback_ret_or_err = pcall(ui_builtin.input_text, field.element, text, { max_level = 1 })
	if fallback_ok and fallback_ret_or_err then
		return true
	end
	return false, tostring(fallback_ret_or_err or ret_or_err)
end

local function apply_set_text(alert, spec)
	if spec == nil then
		return true
	end
	local fields = alert.textFields or {}
	if type(spec) == "string" or type(spec) == "number" then
		local ok, err = set_field_text(fields[1], spec, alert.pid)
		if ok then
			log("textFields", "field=1", "text=" .. tostring(spec))
		end
		return ok, err
	end
	if type(spec) ~= "table" then
		return false, "textFields must be string, number or table"
	end

	if table_is_array(spec) then
		for i, value in ipairs(spec) do
			local ok, err = set_field_text(fields[i], value, alert.pid)
			if not ok then
				return false, err
			end
			log("textFields", "field=" .. tostring(i), "text=" .. tostring(value))
		end
	end

	for key, value in pairs(spec) do
		if type(key) ~= "number" then
			local matched
			for _, field in ipairs(fields) do
				if field.placeholder == key or field.text == key then
					matched = field
					break
				end
			end
			local ok, err = set_field_text(matched, value, alert.pid)
			if not ok then
				return false, err
			end
			log("textFields", "field=" .. tostring(key), "text=" .. tostring(value))
		end
	end
	return true
end

local function execute_action(rule, alert)
	local action = type(rule.actions) == "table" and rule.actions or {}
	local set_ok, set_err = apply_set_text(alert, action.textFields)
	if not set_ok then
		log("rule", rule.name or "?", "textFields failed:", set_err, "skip click")
		return
	end
	if action.textFields ~= nil then
		sys.msleep(300)
	end

	local button
	if action.clickButton ~= nil then
		button = find_button(alert, action.clickButton)
	elseif action.clickCancel then
		button = alert.buttons[1]
	elseif action.clickPreferred then
		button = alert.buttons[#alert.buttons]
	end
	if button then
		local ok, click_err, click_detail = click_current_element(button.element, alert.pid)
		click_detail = type(click_detail) == "table" and click_detail or {}
		log("rule", rule.name or "?", "click", button.text, "x=" .. tostring(button.x), "y=" .. tostring(button.y), "ok=" .. tostring(ok), click_err and ("err=" .. tostring(click_err)) or "", "hit_ms=" .. tostring(click_detail.hit_ms), "click_ms=" .. tostring(click_detail.click_ms), "elapsed_ms=" .. tostring(alert_elapsed_ms(alert)))
	elseif action.clickButton ~= nil or action.clickCancel or action.clickPreferred then
		log("rule", rule.name or "?", "button not found", tostring(action.clickButton or action.clickCancel or action.clickPreferred), "elapsed_ms=" .. tostring(alert_elapsed_ms(alert)))
	end

	if action.log == true then
		log("rule", rule.name or "?", alert_summary(alert))
	elseif type(action.log) == "function" then
		local ok, err = pcall(action.log, alert)
		if not ok then
			log("rule", rule.name or "?", "log failed:", err)
		end
	end
end

local handle_observer_event

local function finish_alert(alert, cooldown_ms)
	cooldown_ms = math.max(0, tonumber(cooldown_ms) or CLICK_COOLDOWN_MS)
	dispatch_after(cooldown_ms, "main", function()
		safe_release(type(alert) == "table" and alert._elements or nil)
		busy = false
		collectgarbage("step", 200)
		if pending_event then
			dispatch_after(QUEUED_BUILD_DELAY_MS, "main", function()
				handle_observer_event(true)
			end)
		end
	end)
end

local function max_ms(left, right)
	left = tonumber(left) or 0
	right = tonumber(right) or 0
	return left > right and left or right
end

local function run_matched_actions(matches, index, alert, cooldown_ms)
	local item = matches[index]
	if not item then
		finish_alert(alert, cooldown_ms)
		return
	end
	local rule = item.rule
	dispatch_after(item.wait_ms, "main", function()
		local done, err = pcall(execute_action, rule, alert)
		if not done then
			log("rule", rule.name or "?", "action error:", err)
		end
		run_matched_actions(matches, index + 1, alert, max_ms(cooldown_ms, item.cooldown_ms))
	end)
end

local function action_uses_text_fields(rule)
	local action = type(rule.actions) == "table" and rule.actions or {}
	return action.textFields ~= nil
end

local function action_wait_ms(rule)
	local action = type(rule.actions) == "table" and rule.actions or {}
	local wait_ms = tonumber(action.wait)
	if wait_ms == nil then
		wait_ms = action_uses_text_fields(rule) and DEFAULT_TEXT_FIELD_WAIT_MS or DEFAULT_CLICK_WAIT_MS
	end
	if wait_ms < 0 then
		wait_ms = 0
	end
	return math.floor(wait_ms)
end

local function action_cooldown_ms(rule)
	return action_uses_text_fields(rule) and TEXT_FIELD_COOLDOWN_MS or CLICK_COOLDOWN_MS
end

local function process_alert(alert, opts)
	opts = type(opts) == "table" and opts or {}
	local matches = {}
	for index, rule in ipairs(rules) do
		if type(rule) == "table" then
			rule.name = type(rule.name) == "string" and rule.name or tostring(index)
			local ok, ret = pcall(match_rule, rule, alert)
			if ok and ret then
				matches[#matches + 1] = {
					rule = rule,
					wait_ms = action_wait_ms(rule),
					cooldown_ms = action_cooldown_ms(rule),
				}
				log("matched", rule.name, alert_summary(alert), "elapsed_ms=" .. tostring(alert_elapsed_ms(alert)))
				if not rule.continue then
					break
				end
			elseif not ok then
				log("rule", rule.name or tostring(index), "match error:", ret)
			end
		end
	end

	if #matches == 0 then
		local buttons = type(alert.buttons) == "table" and alert.buttons or {}
		local fields = type(alert.textFields) == "table" and alert.textFields or {}
		local should_retry_full = #buttons == 0 and #fields == 0
		if opts.retry_full and opts.event and should_retry_full then
			safe_release(alert._elements)
			dispatch_after(FULL_SCAN_RETRY_DELAY_MS, "main", function()
				if opts.generation ~= event_generation and pending_event then
					finish_alert({ _event = opts.event }, 0)
					return
				end
				local ok, full_alert_or_err = pcall(build_alert, opts.event, {
					allow_stale_anchor = not opts.queued,
					scan_mode = "full",
				})
				if ok and full_alert_or_err then
					process_alert(full_alert_or_err)
				else
					log("build full failed:", full_alert_or_err)
					finish_alert({ _event = opts.event }, UNMATCHED_COOLDOWN_MS)
				end
			end)
			return
		end
		local key = alert_summary(alert)
		local now = sys.mtime()
		if key ~= last_unknown_key or now - last_unknown_ms > 3000 then
			last_unknown_key = key
			last_unknown_ms = now
			log("unmatched", key)
		end
		finish_alert(alert, UNMATCHED_COOLDOWN_MS)
		return
	end

	run_matched_actions(matches, 1, alert, 0)
end

local function load_rules()
	local attr = lfs.attributes(RULES_PATH)
	local mtime = type(attr) == "table" and attr.modification or nil
	if mtime == nil then
		if rules_mtime ~= false then
			rules = {}
			rules_mtime = false
			bad_rules_mtime = nil
			log("rules missing", RULES_PATH, "using empty rules")
		end
		return true
	end
	if mtime == rules_mtime then
		return true
	end
	if mtime == bad_rules_mtime then
		return false
	end

	local content = file.reads(RULES_PATH)
	if type(content) ~= "string" or content == "" then
		rules = {}
		rules_mtime = mtime
		bad_rules_mtime = nil
		log("rules empty", RULES_PATH)
		return true
	end

	local loaded, err = table.load_string(content)
	if type(loaded) ~= "table" then
		bad_rules_mtime = mtime
		log("rules load failed:", err or "cache must be table")
		return false
	end

	rules = loaded
	rules_mtime = mtime
	bad_rules_mtime = nil
	log("rules loaded", RULES_PATH, "count=" .. tostring(#rules))
	return true
end

local function schedule_rules_reload_check()
	dispatch_after(1000, "main", function()
		pcall(load_rules)
		schedule_rules_reload_check()
	end)
end

local function schedule_config_check()
	dispatch_after(1000, "main", function()
		if not service_enabled() then
			exit_service("disabled")
			return
		end
		schedule_config_check()
	end)
end

load_rules()
schedule_rules_reload_check()

reload_handle = notification_center_register_callback({
	center = "darwin",
	name = RELOAD_NOTIFY_NAME,
}, function()
	rules_mtime = nil
	bad_rules_mtime = nil
	load_rules()
end)

exit_handle = notification_center_register_callback({
	center = "darwin",
	name = EXIT_NOTIFY_NAME,
}, function()
	exit_service("notify")
end)

if not service_enabled() then
	exit_service("disabled")
end
schedule_config_check()

handle_observer_event = function(queued)
	if busy then
		return
	end
	local event = pending_event
	pending_event = nil
	local generation = event_generation
	if not event then
		return
	end
	local function build_top_when_ready()
		local elapsed_ms = math.max(0, sys.mtime() - (tonumber(event._ui_elerthelper_received_ms) or sys.mtime()))
		if elapsed_ms < BUILD_DELAY_MS then
			dispatch_after(BUILD_DELAY_MS - elapsed_ms, "main", build_top_when_ready)
			return
		end

		local anchor = type(event.element) == "table" and event.element or nil
		if not anchor or text_of(anchor) == "" or not rect_of(anchor) then
			finish_alert({ _event = event }, UNMATCHED_COOLDOWN_MS)
			return
		end

		local ok, alert_or_err = pcall(build_alert, event, {
			allow_stale_anchor = false,
			allow_front_app_anchor = true,
			scan_mode = "fast",
		})
		if ok and alert_or_err then
			process_alert(alert_or_err, {
				event = event,
				queued = queued,
				retry_full = true,
				generation = generation,
			})
		else
			log("build failed:", alert_or_err)
			finish_alert({ _event = event }, UNMATCHED_COOLDOWN_MS)
		end
	end

	busy = true
	build_top_when_ready()
end

local function probe_current_dialog()
	if busy then
		return
	end
	local ok, alert_or_err = pcall(build_current_alert)
	if ok and alert_or_err then
		busy = true
		process_alert(alert_or_err, {
			retry_full = false,
			generation = event_generation,
		})
	elseif not ok then
		log("current dialog probe failed:", alert_or_err)
	end
end

local function start_observer()
	local ok, obs, err = pcall(ui_builtin.observe, OBSERVE_TOKENS, function(event)
		set_pending_event(event)
		handle_observer_event(false)
	end, {
		info = "none",
		element_max_level = 1,
		element_handle = true,
	})
	if not ok then
		err = obs
		obs = nil
	end
	if obs then
		return obs
	end
	return nil, err or "unknown error"
end

local function log_observer_unavailable(err)
	err = tostring(err or "unknown error")
	local now = sys.mtime()
	if err ~= last_observer_error or now - last_observer_log_ms >= OBSERVER_RETRY_LOG_INTERVAL_MS then
		last_observer_error = err
		last_observer_log_ms = now
		log("observe unavailable:", err, "retry_ms=" .. tostring(OBSERVER_RETRY_INTERVAL_MS))
	end
end

local function mark_observer_ready(obs)
	observer = obs
	last_observer_error = ""
	last_observer_log_ms = 0
	log("observer ready", "mode=observer")
	dispatch_after(BUILD_DELAY_MS, "main", probe_current_dialog)
end

local function try_start_observer()
	if observer then
		return true
	end
	local obs, err = start_observer()
	if obs then
		mark_observer_ready(obs)
		return true
	end
	log_observer_unavailable(err)
	return false
end

local function schedule_observer_retry()
	dispatch_after(OBSERVER_RETRY_INTERVAL_MS, "main", function()
		if not try_start_observer() then
			schedule_observer_retry()
		end
	end)
end

if not try_start_observer() then
	schedule_observer_retry()
end

log("started", "ui_element_builtin=" .. tostring(ui_builtin._VERSION), "rules=" .. RULES_PATH, observer and "mode=observer" or "mode=waiting_observer")
CFRunLoopRunWithAutoreleasePool()
