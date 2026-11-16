--[[

	巨魔版从越狱版迁移文件的脚本

    本文件仅作为参考，请不要修改本文件
    本文件会在重装、更新时被原版覆盖

--]]

if not IS_TROLLSTORE_EDITION then
	return
end

local localization = require("localization")
local LLANG = (function()
	local _localizations = {
		en = {
			["XXTouch"] = "XXTouch",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition',
		},
		["zh-Hans"] = {
			["XXTouch"] = "X.X.T.",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️当前越狱版未卸载\n\n为避免冲突，建议先删除巨魔版，然后激活越狱并卸载越狱版，再安装巨魔版',
		},
		["zh-Hant"] = {
			["XXTouch"] = "X.X.T.",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️目前的越獄版尚未解除安裝\n\n為避免衝突，建議先刪除 TrollStore 版，再啟用越獄並解除安裝越獄版，最後重新安裝 TrollStore 版。',
		},
		vi = {
			["XXTouch"] = "XXTouch",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️Bản jailbreak hiện chưa được gỡ cài đặt\n\nĐể tránh xung đột, hãy xóa bản TrollStore trước, kích hoạt jailbreak và gỡ bản jailbreak, sau đó cài lại bản TrollStore.',
		},
		ja = {
			["XXTouch"] = "XXTouch",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️脱獄版がまだアンインストールされていません\n\n競合を避けるため、TrollStore 版を削除し、脱獄を有効にして脱獄版をアンインストールしてから TrollStore 版を再インストールしてください。',
		},
		ko = {
			["XXTouch"] = "XXTouch",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️현재 탈옥 버전이 제거되지 않았습니다\n\n충돌을 방지하려면 TrollStore 버전을 먼저 삭제하고, 탈옥을 활성화해 탈옥 버전을 제거한 다음 TrollStore 버전을 다시 설치하세요.',
		},
		es = {
			["XXTouch"] = "XXTouch",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️La edición jailbreak actual no se ha desinstalado\n\nPara evitar conflictos, elimina primero la edición TrollStore, activa el jailbreak, desinstala la edición jailbreak y vuelve a instalar la edición TrollStore.',
		},
		["pt-BR"] = {
			["XXTouch"] = "XXTouch",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️A edição jailbreak atual não foi desinstalada\n\nPara evitar conflitos, exclua primeiro a edição TrollStore, ative o jailbreak, desinstale a edição jailbreak e instale novamente a edição TrollStore.',
		},
		ru = {
			["XXTouch"] = "XXTouch",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️Текущая jailbreak-версия не удалена\n\nЧтобы избежать конфликтов, сначала удалите версию TrollStore, активируйте jailbreak, удалите jailbreak-версию, а затем снова установите версию TrollStore.',
		},
		fr = {
			["XXTouch"] = "XXTouch",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️L’édition jailbreak actuelle n’est pas désinstallée\n\nPour éviter les conflits, supprimez d’abord l’édition TrollStore, activez le jailbreak, désinstallez l’édition jailbreak, puis réinstallez l’édition TrollStore.',
		},
		de = {
			["XXTouch"] = "XXTouch",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️Die aktuelle Jailbreak-Version ist nicht deinstalliert\n\nUm Konflikte zu vermeiden, lösche zuerst die TrollStore-Version, aktiviere den Jailbreak, deinstalliere die Jailbreak-Version und installiere danach die TrollStore-Version erneut.',
		},
	}
	return localization.localizer(_localizations)
end)()

local lfs = require('lfs')

local path_op = file.path

local function find_jbpath(path)
	local jb_path = file.find {
		'/private/preboot/',
		{ "^[A-F0-9]+$" },
		{ "^.+$" },
		'/procursus',
		path
	}
	if jb_path[1] then
		return jb_path[1]
	end
	jb_path = file.find {
		'/private/var/containers/Bundle/Application/',
		{ "^%.jbroot%-[A-F0-9]+$" },
		"/",
		path
	}
	return jb_path[1]
end

local function migrate_files_to_xxt_home(files)
	local jb_home_patterns = {
		{
			'/private/preboot/',
			{ "^[A-F0-9]+$" },
			{ "^.+$" },
			'/procursus/var/mobile/Media/1ferver/',
		},
		{
			'/private/var/containers/Bundle/Application/',
			{ "^%.jbroot%-[A-F0-9]+$" },
			'/var/mobile/Media/1ferver/',
		},
	}
	for _, pattern in ipairs(jb_home_patterns) do
		local jb_home = file.find(pattern)
		if jb_home[1] then
			for _, fn in ipairs(files) do
				local src = path_op.add_component(jb_home[1], fn)
				local dst = path_op.add_component(XXT_HOME_PATH, fn)
				if not file.move(src, dst) then
					file.copy(src, dst)
				end
			end
		end
	end
end

migrate_files_to_xxt_home {
	path_op.last_component(XXT_CONF_FILE_NAME),
	'cert/cert.crt',
	'cert/pri.key',
	'log/sys.log',
}

if find_jbpath('/Applications/XXTExplorer.app') then
	start_daemon(XXT_EXE_PATH, 'eval',
		string.format([[sys.alert(%q, 30, %q)]],
			LLANG(
			"⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"),
			LLANG("XXTouch")))
	return
end

start_daemon(XXT_EXE_PATH, 'dofile', XXT_HOME_PATH .. '/bin/xxt-migrate-jb2ts-user.lua')
