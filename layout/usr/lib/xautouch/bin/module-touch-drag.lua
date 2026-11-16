local json = require('cjson.safe')

local _WHEEL_DEFAULTS = {
    axis = 'y',
    natural = true,
    step_px = 48,
    coalesce_ms = 60,
    amp = 0.18,
    dur_base_ms = 50,
    release_delay_ms = 120,
    brake_enabled = false,
    brake_reverse_px = 5,
    amp_cap = 0.75,
    min_take_ratio = 0.35,
    abs_clamp_factor = 2.5,
    duration_factor = 0.00016,
    duration_min_ms = 50,
    duration_max_ms = 800,
}

local function _clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    elseif value > max_value then
        return max_value
    end
    return value
end

local function _round(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

local function _sign(value)
    if value > 0 then
        return 1
    elseif value < 0 then
        return -1
    end
    return 0
end

local function _clamp_point(x, y)
    local width, height = screen.size()
    local clamped_x = _clamp(_round(tonumber(x) or 0), 0, width - 1)
    local clamped_y = _clamp(_round(tonumber(y) or 0), 0, height - 1)
    return clamped_x, clamped_y
end

local function _simple_curve_interpolation(a, b, t)
    return a + ((b - a) * math.sin(math.sin(t * math.pi / 2) * t * math.pi / 2))
end

local function _point_distance(x0, y0, x1, y1)
    local dx = x1 - x0
    local dy = y1 - y0
    return math.sqrt((dx * dx) + (dy * dy))
end

local function _quadratic_bezier_point(t, x0, y0, cx, cy, x1, y1)
    local nt = 1 - t
    local x = (nt * nt * x0) + (2 * nt * t * cx) + (t * t * x1)
    local y = (nt * nt * y0) + (2 * nt * t * cy) + (t * t * y1)
    return x, y
end

local function _cubic_bezier_point(t, x0, y0, c1x, c1y, c2x, c2y, x1, y1)
    local nt = 1 - t
    local nt2 = nt * nt
    local nt3 = nt2 * nt
    local t2 = t * t
    local t3 = t2 * t
    local x = (nt3 * x0) + (3 * nt2 * t * c1x) + (3 * nt * t2 * c2x) + (t3 * x1)
    local y = (nt3 * y0) + (3 * nt2 * t * c1y) + (3 * nt * t2 * c2y) + (t3 * y1)
    return x, y
end

local function _estimate_curve_length(curve_type, x0, y0, cp1x, cp1y, cp2x, cp2y, x1, y1)
    local sample_count = 24
    local prev_x = x0
    local prev_y = y0
    local total = 0
    for i = 1, sample_count do
        local t = i / sample_count
        local x, y
        if curve_type == 'cubic' then
            x, y = _cubic_bezier_point(t, x0, y0, cp1x, cp1y, cp2x, cp2y, x1, y1)
        else
            x, y = _quadratic_bezier_point(t, x0, y0, cp1x, cp1y, x1, y1)
        end
        total = total + _point_distance(prev_x, prev_y, x, y)
        prev_x = x
        prev_y = y
    end
    return total
end

local function _state_key(finger)
    return string.format('xxtouch.touch-drag.state.%d', finger)
end

local function _worker_key(finger)
    return string.format('xxtouch.touch-drag.worker.%d', finger)
end

local function _wheel_state_key(finger)
    return string.format('xxtouch.touch-drag.wheel.state.%d', finger)
end

local function _wheel_worker_key(finger)
    return string.format('xxtouch.touch-drag.wheel.worker.%d', finger)
end

local function _decode_state(raw)
    if type(raw) ~= 'string' or raw == '' then
        return nil
    end
    local obj = json.decode(raw)
    return type(obj) == 'table' and obj or nil
end

local function _encode_state(obj)
    local raw = json.encode(obj)
    return type(raw) == 'string' and raw or nil
end

local function _load_json_state(key)
    return _decode_state(proc_get(key))
end

local function _store_json_state(key, state)
    local raw = _encode_state(state)
    if raw then
        proc_put(key, raw)
        return true
    end
    return false
end

local function _load_state(finger)
    return _load_json_state(_state_key(finger))
end

local function _store_state(finger, state)
    return _store_json_state(_state_key(finger), state)
end

local function _load_wheel_state(finger)
    return _load_json_state(_wheel_state_key(finger))
end

local function _store_wheel_state(finger, state)
    return _store_json_state(_wheel_state_key(finger), state)
end

local function _set_worker_running(finger, running)
    proc_put(_worker_key(finger), running and '1' or '')
end

local function _is_worker_running(finger)
    return proc_get(_worker_key(finger)) == '1'
end

local function _set_wheel_worker_running(finger, running)
    proc_put(_wheel_worker_key(finger), running and '1' or '')
end

local function _is_wheel_worker_running(finger)
    return proc_get(_wheel_worker_key(finger)) == '1'
end

local function _active_drag_target(finger)
    if not _is_worker_running(finger) then
        return nil
    end
    local state = _load_state(finger)
    if type(state) ~= 'table' then
        return nil
    end
    local x1 = tonumber(state.x1)
    local y1 = tonumber(state.y1)
    if x1 == nil or y1 == nil then
        return nil
    end
    return _clamp_point(x1, y1)
end

local function _normalize_bool(value, fallback)
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

local function _normalize_wheel_options(options)
    local input = type(options) == 'table' and options or {}
    local axis = input.axis
    if axis == 'horizontal' then
        axis = 'x'
    elseif axis == 'vertical' then
        axis = 'y'
    end
    axis = axis == 'x' and 'x' or _WHEEL_DEFAULTS.axis

    local step_px = tonumber(input.step_px or input.stepPx) or _WHEEL_DEFAULTS.step_px
    step_px = _clamp(step_px, 5, 1000)

    local duration_scale_ms = tonumber(input.duration_scale_ms or input.durationScaleMs)
    local duration_factor = tonumber(input.duration_factor)
    if not duration_factor and duration_scale_ms then
        duration_factor = duration_scale_ms / 1000
    end
    if not duration_factor then
        duration_factor = _WHEEL_DEFAULTS.duration_factor
    end

    local max_step_px = tonumber(input.max_step_px or input.maxPx)
    if max_step_px and max_step_px <= 0 then
        max_step_px = nil
    end

    local normalized = {
        axis = axis,
        natural = _normalize_bool(input.natural, _WHEEL_DEFAULTS.natural),
        step_px = step_px,
        coalesce_ms = _clamp(tonumber(input.coalesce_ms or input.coalesceMs) or _WHEEL_DEFAULTS.coalesce_ms, 0, 200),
        amp = _clamp(tonumber(input.amp or input.amp_coeff) or _WHEEL_DEFAULTS.amp, 0, 5),
        dur_base_ms = _clamp(
            tonumber(input.dur_base_ms or input.durBaseMs or input.duration_base_ms or input.durationBaseMs) or
                _WHEEL_DEFAULTS.dur_base_ms,
            0,
            800
        ),
        release_delay_ms = _clamp(tonumber(input.release_delay_ms or input.releaseDelayMs) or
            _WHEEL_DEFAULTS.release_delay_ms, 0, 500),
        brake_enabled = _normalize_bool(input.brake_enabled or input.brakeEnabled, _WHEEL_DEFAULTS.brake_enabled),
        brake_reverse_px = _clamp(tonumber(input.brake_reverse_px or input.brakeReversePx) or
            _WHEEL_DEFAULTS.brake_reverse_px, 2, 20),
        amp_cap = math.max(0, tonumber(input.amp_cap or input.cap) or _WHEEL_DEFAULTS.amp_cap),
        min_take_ratio = math.max(0, tonumber(input.min_take_ratio or input.minRatio) or _WHEEL_DEFAULTS.min_take_ratio),
        max_step_px = max_step_px,
        abs_clamp_factor = math.max(0, tonumber(input.abs_clamp_factor or input.clampFactor) or
            _WHEEL_DEFAULTS.abs_clamp_factor),
        duration_factor = math.max(0, duration_factor),
        duration_min_ms = math.max(0, tonumber(input.duration_min_ms or input.durationMinMs) or
            _WHEEL_DEFAULTS.duration_min_ms),
        duration_max_ms = math.max(0, tonumber(input.duration_max_ms or input.durationMaxMs) or
            _WHEEL_DEFAULTS.duration_max_ms),
    }

    if normalized.duration_max_ms < normalized.duration_min_ms then
        normalized.duration_max_ms = normalized.duration_min_ms
    end

    return normalized
end

local function _normalize_wheel_delta(delta)
    local value = tonumber(delta)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

local function _compute_wheel_component(accum_delta, options)
    local opts = _normalize_wheel_options(options)
    local scale_factor = tonumber(screen.scale_factor()) or 1
    local base_px = ((tonumber(accum_delta) or 0) / 100) * opts.step_px * scale_factor
    if opts.natural then
        base_px = -base_px
    end

    local abs_base_px = math.abs(base_px)
    if abs_base_px <= 0 then
        return 0, 0, opts
    end

    local amp = 1 + math.min(opts.amp_cap, opts.amp * math.log(1 + abs_base_px / math.max(opts.step_px * scale_factor, 1)))
    local take_px = base_px * amp
    local min_take_px = math.max(1, opts.step_px * scale_factor * opts.min_take_ratio)
    local abs_take_px = math.abs(take_px)
    if abs_take_px < min_take_px then
        take_px = _sign(base_px) * min_take_px
        abs_take_px = math.abs(take_px)
    end

    local clamp_px = opts.step_px * scale_factor * opts.abs_clamp_factor
    if opts.max_step_px and opts.max_step_px > 0 then
        clamp_px = math.min(clamp_px, opts.max_step_px * scale_factor)
    end
    take_px = _sign(take_px) * math.min(math.abs(take_px), clamp_px)

    local duration_ms = opts.dur_base_ms + (opts.duration_factor * 1000) * math.sqrt(math.abs(take_px))
    duration_ms = _clamp(duration_ms, opts.duration_min_ms, opts.duration_max_ms)
    return take_px, duration_ms, opts
end

local function _resolve_wheel_deltas(delta, options)
    local opts = _normalize_wheel_options(options)
    local delta_x = nil
    local delta_y = nil

    if type(delta) == 'table' then
        delta_x = delta.delta_x or delta.deltaX or delta.x
        delta_y = delta.delta_y or delta.deltaY or delta.y
        if delta_x == nil and delta_y == nil and delta.delta ~= nil then
            if opts.axis == 'x' then
                delta_x = delta.delta
            else
                delta_y = delta.delta
            end
        end
    elseif delta ~= nil then
        if opts.axis == 'x' then
            delta_x = delta
        else
            delta_y = delta
        end
    end

    return _normalize_wheel_delta(delta_x) or 0, _normalize_wheel_delta(delta_y) or 0, opts
end

local function _compute_wheel_take(delta_x, delta_y, options)
    local take_x, duration_x, opts = _compute_wheel_component(delta_x, options)
    local take_y, duration_y = _compute_wheel_component(delta_y, options)
    return take_x, take_y, math.max(duration_x, duration_y), opts
end

local function _build_linear_plan(state, current_x, current_y, is_touching)
    local start_x = is_touching and current_x or state.x0
    local start_y = is_touching and current_y or state.y0
    local end_x, end_y = _clamp_point(state.x1, state.y1)
    local duration = math.max(0, tonumber(state.duration) or 50)
    local tick_ms = 16
    local steps = math.max(1, math.ceil(duration / tick_ms))
    local clamped_start_x, clamped_start_y = _clamp_point(start_x, start_y)
    return {
        seq = state.seq,
        mode = 'linear',
        start_x = clamped_start_x,
        start_y = clamped_start_y,
        end_x = end_x,
        end_y = end_y,
        steps = steps,
        step_delay_ms = (steps > 0) and (duration / steps) or 0,
        off_delay_ms = 0,
        index = 0,
    }
end

local function _build_curve_plan(state, current_x, current_y, is_touching)
    local start_x = is_touching and current_x or state.x0
    local start_y = is_touching and current_y or state.y0
    local clamped_start_x, clamped_start_y = _clamp_point(start_x, start_y)
    local end_x, end_y = _clamp_point(state.x1, state.y1)
    local steps
    local step_delay_ms
    local off_delay_ms = math.max(0, tonumber(state.off_delay) or 0)
    if state.step_len then
        local curve_length
        if state.curve_type == 'cubic' or state.curve_type == 'quadratic' then
            curve_length = _estimate_curve_length(state.curve_type, clamped_start_x, clamped_start_y, state.cp1x, state.cp1y,
                state.cp2x, state.cp2y, end_x, end_y)
        else
            curve_length = _point_distance(clamped_start_x, clamped_start_y, end_x, end_y)
        end
        steps = math.max(1, math.floor(curve_length / state.step_len))
        step_delay_ms = math.max(0, tonumber(state.step_delay) or 1)
    else
        local duration = math.max(0, tonumber(state.duration) or 50)
        local tick_ms = 16
        steps = math.max(1, math.ceil(duration / tick_ms))
        step_delay_ms = (steps > 0) and (duration / steps) or 0
        off_delay_ms = 0
    end
    return {
        seq = state.seq,
        mode = 'curve',
        curve_type = state.curve_type,
        start_x = clamped_start_x,
        start_y = clamped_start_y,
        end_x = end_x,
        end_y = end_y,
        cp1x = state.cp1x,
        cp1y = state.cp1y,
        cp2x = state.cp2x,
        cp2y = state.cp2y,
        steps = steps,
        step_delay_ms = step_delay_ms,
        off_delay_ms = off_delay_ms,
        index = 0,
    }
end

local function _build_plan(state, current_x, current_y, is_touching)
    if state.mode == 'curve' then
        return _build_curve_plan(state, current_x, current_y, is_touching)
    end
    return _build_linear_plan(state, current_x, current_y, is_touching)
end

local function _plan_point(plan, ratio)
    if plan.mode == 'curve' then
        if plan.curve_type == 'cubic' then
            return _cubic_bezier_point(ratio, plan.start_x, plan.start_y, plan.cp1x, plan.cp1y, plan.cp2x, plan.cp2y,
                plan.end_x, plan.end_y)
        elseif plan.curve_type == 'quadratic' then
            return _quadratic_bezier_point(ratio, plan.start_x, plan.start_y, plan.cp1x, plan.cp1y, plan.end_x, plan.end_y)
        end
        return _simple_curve_interpolation(plan.start_x, plan.end_x, ratio),
            _simple_curve_interpolation(plan.start_y, plan.end_y, ratio)
    end
    return plan.start_x + ((plan.end_x - plan.start_x) * ratio),
        plan.start_y + ((plan.end_y - plan.start_y) * ratio)
end

local function _wait_for_idle_or_update(finger, seq, wait_ms)
    local remaining = tonumber(wait_ms) or 0
    while remaining > 0 do
        local chunk = math.min(remaining, 16)
        sys.msleep(chunk)
        remaining = remaining - chunk
        local latest = _load_state(finger)
        if latest and latest.seq ~= seq then
            return false
        end
    end
    return true
end

local _submit_async_state

local function _stateful_linear_async(finger, x0, y0, x1, y1, duration)
    local start_x, start_y = _clamp_point(x0, y0)
    local end_x, end_y = _clamp_point(x1, y1)
    _submit_async_state(finger, {
        mode = 'linear',
        x0 = start_x,
        y0 = start_y,
        x1 = end_x,
        y1 = end_y,
        duration = math.max(0, tonumber(duration) or 50),
    })
end

local function _run_async_worker(finger)
    local last_seq = nil
    local ok, err = pcall(function()
        local current_x = nil
        local current_y = nil
        local is_touching = false
        local active_plan = nil

        while true do
            local state = _load_state(finger)
            if not state then
                break
            end

            if not active_plan or active_plan.seq ~= state.seq then
                active_plan = _build_plan(state, current_x, current_y, is_touching)
                last_seq = active_plan.seq
                if not is_touching then
                    touch.down(finger, active_plan.start_x, active_plan.start_y)
                    current_x = active_plan.start_x
                    current_y = active_plan.start_y
                    is_touching = true
                end
            end

            if active_plan.index < active_plan.steps then
                active_plan.index = active_plan.index + 1
                local ratio = active_plan.index / active_plan.steps
                local next_x, next_y = _plan_point(active_plan, ratio)
                current_x, current_y = _clamp_point(next_x, next_y)
                touch.move(finger, current_x, current_y)
                if active_plan.step_delay_ms > 0 then
                    sys.msleep(active_plan.step_delay_ms)
                end
            else
                local latest = _load_state(finger)
                if latest and latest.seq ~= active_plan.seq then
                    active_plan = nil
                else
                    if active_plan.off_delay_ms > 0 then
                        local stable = _wait_for_idle_or_update(finger, active_plan.seq, active_plan.off_delay_ms)
                        if not stable then
                            active_plan = nil
                            goto continue
                        end
                    end
                    current_x, current_y = _clamp_point(active_plan.end_x, active_plan.end_y)
                    touch.move(finger, current_x, current_y)
                    touch.up(finger)
                    is_touching = false
                    break
                end
            end

            ::continue::
        end

        if is_touching then
            pcall(touch.up, finger)
        end
    end)

    _set_worker_running(finger, false)
    local latest = _load_state(finger)
    if latest and latest.seq ~= last_seq and not _is_worker_running(finger) then
        _set_worker_running(finger, true)
        dispatch_async('concurrent', function()
            _run_async_worker(finger)
        end)
    end
    if not ok then
        sys.log(string.format('[module-touch-drag] async worker failed: %s', tostring(err)))
    end
end

_submit_async_state = function(finger, state)
    local previous = _load_state(finger)
    state.seq = ((previous and tonumber(previous.seq)) or 0) + 1
    if not _store_state(finger, state) then
        error('failed to store async drag state')
    end
    if not _is_worker_running(finger) then
        _set_worker_running(finger, true)
        dispatch_async('concurrent', function()
            _run_async_worker(finger)
        end)
    end
end

local function _wheel_drag(finger, start_x, start_y, end_x, end_y, duration_ms, options)
    local opts = _normalize_wheel_options(options)
    local clamped_start_x, clamped_start_y = _clamp_point(start_x, start_y)
    local clamped_end_x, clamped_end_y = _clamp_point(end_x, end_y)
    local dx = clamped_end_x - clamped_start_x
    local dy = clamped_end_y - clamped_start_y
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance < 0.01 then
        return
    end

    local steps = math.max(3, math.min(8, math.floor(distance / 24 + 0.5)))
    local interval_ms = math.max(8, math.floor((tonumber(duration_ms) or 0) / math.max(steps, 1)))
    local current_x = clamped_start_x
    local current_y = clamped_start_y

    touch.down(finger, clamped_start_x, clamped_start_y)
    for i = 1, steps do
        current_x, current_y = _clamp_point(
            clamped_start_x + dx * (i / steps),
            clamped_start_y + dy * (i / steps)
        )
        touch.move(finger, current_x, current_y)
        if interval_ms > 0 then
            sys.msleep(interval_ms)
        end
    end

    if opts.brake_enabled and distance >= 0.01 then
        local unit_x = dx / distance
        local unit_y = dy / distance
        for _ = 1, 5 do
            local next_x, next_y = _clamp_point(current_x + unit_x, current_y + unit_y)
            if math.abs(next_x - current_x) < 0.01 and math.abs(next_y - current_y) < 0.01 then
                break
            end
            current_x = next_x
            current_y = next_y
            touch.move(finger, current_x, current_y)
            sys.msleep(15)
        end
        for _ = 1, opts.brake_reverse_px do
            local next_x, next_y = _clamp_point(current_x - unit_x, current_y - unit_y)
            if math.abs(next_x - current_x) < 0.01 and math.abs(next_y - current_y) < 0.01 then
                break
            end
            current_x = next_x
            current_y = next_y
            touch.move(finger, current_x, current_y)
            sys.msleep(15)
        end
    end

    if opts.release_delay_ms > 0 then
        sys.msleep(opts.release_delay_ms)
    end
    touch.up(finger)
end

local function _run_wheel_async_worker(finger)
    local last_seq = nil
    local ok, err = pcall(function()
        while true do
            local state = _load_wheel_state(finger)
            if not state then
                break
            end

            local pending_delta_x = tonumber(state.pending_delta_x) or 0
            local pending_delta_y = tonumber(state.pending_delta_y) or 0
            if pending_delta_x == 0 and pending_delta_y == 0 then
                break
            end

            local options = _normalize_wheel_options(state.options)
            if options.coalesce_ms > 0 then
                sys.msleep(options.coalesce_ms)
            end

            state = _load_wheel_state(finger)
            if not state then
                break
            end

            pending_delta_x = tonumber(state.pending_delta_x) or 0
            pending_delta_y = tonumber(state.pending_delta_y) or 0
            if pending_delta_x == 0 and pending_delta_y == 0 then
                break
            end

            last_seq = tonumber(state.seq) or 0
            local take_x, take_y, duration_ms, normalized_options = _compute_wheel_take(
                pending_delta_x,
                pending_delta_y,
                state.options
            )
            local anchor_x, anchor_y = _clamp_point(state.anchor_x, state.anchor_y)

            state.pending_delta_x = 0
            state.pending_delta_y = 0
            state.anchor_x = nil
            state.anchor_y = nil
            state.options = normalized_options
            if not _store_wheel_state(finger, state) then
                error('failed to store async wheel state')
            end

            if take_x ~= 0 or take_y ~= 0 then
                local end_x, end_y = _clamp_point(anchor_x + take_x, anchor_y + take_y)
                if math.abs(end_x - anchor_x) >= 0.01 or math.abs(end_y - anchor_y) >= 0.01 then
                    _wheel_drag(finger, anchor_x, anchor_y, end_x, end_y, duration_ms, normalized_options)
                end
            end
        end
    end)

    _set_wheel_worker_running(finger, false)
    local latest = _load_wheel_state(finger)
    if latest and ((tonumber(latest.pending_delta_x) or 0) ~= 0 or (tonumber(latest.pending_delta_y) or 0) ~= 0) and
        not _is_wheel_worker_running(finger) then
        _set_wheel_worker_running(finger, true)
        dispatch_async('concurrent', function()
            _run_wheel_async_worker(finger)
        end)
    end
    if not ok then
        pcall(touch.up, finger)
        sys.log(string.format('[module-touch-drag] wheel worker failed: %s', tostring(err)))
    end
end

local function _submit_wheel_async_state(finger, anchor_x, anchor_y, delta, options)
    local normalized_delta_x, normalized_delta_y = _resolve_wheel_deltas(delta, options)
    if normalized_delta_x == 0 and normalized_delta_y == 0 then
        return
    end

    local clamped_x, clamped_y = _clamp_point(anchor_x, anchor_y)
    local state = _load_wheel_state(finger) or {}
    local previous_pending_x = tonumber(state.pending_delta_x) or 0
    local previous_pending_y = tonumber(state.pending_delta_y) or 0
    state.seq = (tonumber(state.seq) or 0) + 1
    state.options = _normalize_wheel_options(options)
    if previous_pending_x == 0 and previous_pending_y == 0 then
        state.anchor_x = clamped_x
        state.anchor_y = clamped_y
    elseif state.anchor_x == nil or state.anchor_y == nil then
        state.anchor_x = clamped_x
        state.anchor_y = clamped_y
    end
    state.pending_delta_x = previous_pending_x + normalized_delta_x
    state.pending_delta_y = previous_pending_y + normalized_delta_y
    if not _store_wheel_state(finger, state) then
        error('failed to store async wheel state')
    end
    if not _is_wheel_worker_running(finger) then
        _set_wheel_worker_running(finger, true)
        dispatch_async('concurrent', function()
            _run_wheel_async_worker(finger)
        end)
    end
end

local function drag_linear(finger, x0, y0, x1, y1, duration)
    local start_x, start_y = _clamp_point(x0, y0)
    local end_x, end_y = _clamp_point(x1, y1)
    local total_duration = math.max(0, tonumber(duration) or 50)
    local tick_ms = 16
    local steps = math.max(1, math.ceil(total_duration / tick_ms))
    local step_delay_ms = (steps > 0) and (total_duration / steps) or 0

    touch.down(finger, start_x, start_y)
    for i = 1, steps do
        local ratio = i / steps
        local xi, yi = _clamp_point(start_x + ((end_x - start_x) * ratio), start_y + ((end_y - start_y) * ratio))
        touch.move(finger, xi, yi)
        if step_delay_ms > 0 then
            sys.msleep(step_delay_ms)
        end
    end
    touch.move(finger, end_x, end_y)
    touch.up(finger)
end

local function drag_linear_async(finger, x0, y0, x1, y1, duration)
    local start_x, start_y = _clamp_point(x0, y0)
    local end_x, end_y = _clamp_point(x1, y1)
    local total_duration = math.max(0, tonumber(duration) or 50)
    dispatch_async('concurrent', function()
        local ok, err = pcall(drag_linear, finger, start_x, start_y, end_x, end_y, total_duration)
        if not ok then
            sys.log(string.format('[module-touch-drag] drag_linear_async failed: %s', tostring(err)))
        end
    end)
end

local function drag_curve(options)
    local finger = options.finger
    local x0, y0 = _clamp_point(options.x0, options.y0)
    local x1, y1 = _clamp_point(options.x1, options.y1)
    local curve_type = options.curve_type
    local cp1x = options.cp1x
    local cp1y = options.cp1y
    local cp2x = options.cp2x
    local cp2y = options.cp2y

    local steps
    local step_delay_ms
    local off_delay_ms = 0
    if options.step_len then
        local curve_length
        if curve_type == 'cubic' or curve_type == 'quadratic' then
            curve_length = _estimate_curve_length(curve_type, x0, y0, cp1x, cp1y, cp2x, cp2y, x1, y1)
        else
            curve_length = _point_distance(x0, y0, x1, y1)
        end
        steps = math.max(1, math.floor(curve_length / options.step_len))
        step_delay_ms = math.max(0, tonumber(options.step_delay) or 1)
        off_delay_ms = math.max(0, tonumber(options.off_delay) or 0)
    else
        local duration = math.max(0, tonumber(options.duration) or 50)
        local tick_ms = 16
        steps = math.max(1, math.ceil(duration / tick_ms))
        step_delay_ms = (steps > 0) and (duration / steps) or 0
    end

    touch.down(finger, x0, y0)
    for i = 1, steps do
        local ratio = i / steps
        local xi
        local yi
        if curve_type == 'cubic' then
            xi, yi = _cubic_bezier_point(ratio, x0, y0, cp1x, cp1y, cp2x, cp2y, x1, y1)
        elseif curve_type == 'quadratic' then
            xi, yi = _quadratic_bezier_point(ratio, x0, y0, cp1x, cp1y, x1, y1)
        else
            xi = _simple_curve_interpolation(x0, x1, ratio)
            yi = _simple_curve_interpolation(y0, y1, ratio)
        end
        local clamped_x, clamped_y = _clamp_point(xi, yi)
        touch.move(finger, clamped_x, clamped_y)
        if step_delay_ms > 0 then
            sys.msleep(step_delay_ms)
        end
    end
    touch.move(finger, x1, y1)
    if off_delay_ms > 0 then
        sys.msleep(off_delay_ms)
    end
    touch.up(finger)
end

local function drag_curve_async(options)
    local task = {
        finger = options.finger,
        x0 = options.x0,
        y0 = options.y0,
        x1 = options.x1,
        y1 = options.y1,
        duration = options.duration,
        step_len = options.step_len,
        step_delay = options.step_delay,
        off_delay = options.off_delay,
        curve_type = options.curve_type,
        cp1x = options.cp1x,
        cp1y = options.cp1y,
        cp2x = options.cp2x,
        cp2y = options.cp2y,
    }
    dispatch_async('concurrent', function()
        local ok, err = pcall(drag_curve, task)
        if not ok then
            sys.log(string.format('[module-touch-drag] drag_curve_async failed: %s', tostring(err)))
        end
    end)
end

local function wheel(finger, anchor_x, anchor_y, delta, options)
    local delta_x, delta_y = _resolve_wheel_deltas(delta, options)
    local take_x, take_y, duration_ms, normalized_options = _compute_wheel_take(delta_x, delta_y, options)
    if take_x == 0 and take_y == 0 then
        return
    end
    local start_x, start_y = _clamp_point(anchor_x, anchor_y)
    local end_x = start_x + take_x
    local end_y = start_y + take_y
    end_x, end_y = _clamp_point(end_x, end_y)
    if math.abs(end_x - start_x) < 0.01 and math.abs(end_y - start_y) < 0.01 then
        return
    end
    _wheel_drag(finger, start_x, start_y, end_x, end_y, duration_ms, normalized_options)
end

local function wheel_async(finger, anchor_x, anchor_y, delta, options)
    _submit_wheel_async_state(finger, anchor_x, anchor_y, delta, options)
end

return {
    drag_linear = drag_linear,
    drag_linear_async = drag_linear_async,
    drag_curve = drag_curve,
    drag_curve_async = drag_curve_async,
    wheel = wheel,
    wheel_async = wheel_async,
}
