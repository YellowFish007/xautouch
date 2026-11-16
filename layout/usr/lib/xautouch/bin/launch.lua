--[[

	新增额外的随服务启动项
		将扩展名为 `.lua` 脚本文件导入到设备的 `/var/mobile/Media/1ferver/daemons` 目录中
		然后于 App 打开 `更多--用户偏好设置--后台额外脚本服务`
		⚠️ 如果脚本文件的扩展名为 `.keepalive.lua` 则该脚本会自动维持运行状态，崩溃或退出会自动再次启动
	退出额外脚本服务
		可于 App 关闭 `更多--用户偏好设置--后台额外脚本服务` 开关

	⚠️ 使用该项功能需要确保你对该项功能的了解，否则带来的风险自行承担 ⚠️

	本文件仅作为参考，请不要修改本文件
	本文件会在重装、更新时被原版覆盖

--]]

sys.nohup()

local lock_fd = lockfile(jbroot("/tmp/.xxtouch.launch.lua.singleton"))
while not lock_fd do
	-- 配置可能在上一轮启动读入后才更新，等待交接而不是丢弃这次拉起。
	sys.msleep(100)
	lock_fd = lockfile(jbroot("/tmp/.xxtouch.launch.lua.singleton"))
end

local function _stop_watchdogd()
	-- 先让 watchdog 清理子服务，再兜底停止；不等待可能失去响应的同步消息。
	notify_post("xxtouch.watchdogd-service/exit")
	sys.msleep(100)
	launch_stop_lua_daemon(XXT_BIN_PATH .. "/watchdogd.lua")
end

_stop_watchdogd()

local function _watchdogd_ping()
	local reply = cpdistributed_messaging_center_send_message_and_receive_reply(
		'xxtouch.watchdogd-service',
		'xxtouch.watchdogd-service/ping',
		{ ping = sys.mtime() }
	)
	return type(reply) == "table"
end

local function _wait_watchdogd_ready(timeout_ms)
	local deadline = sys.mtime() + (timeout_ms or 5000)
	while sys.mtime() < deadline do
		if _watchdogd_ping() then
			return true
		end
		sys.msleep(200)
	end
	return false
end

-- launchd 返回成功也可能没有运行服务；用实际握手决定是否改用独立进程。
local force_direct = false
while true do
	if launch_start_lua_daemon(XXT_BIN_PATH .. "/watchdogd.lua", true, false, force_direct) and
		_wait_watchdogd_ready(8000) then
		break
	end
	_stop_watchdogd()
	force_direct = true
	sys.msleep(500)
end

unlockfilefd(lock_fd)
