--[[

    巨魔版从越狱版迁移文件的脚本，异步询问用户是否需要迁移，防止大文件迁移慢

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
			["Skip Migration"] = "Skip Migration",
			["Migrate Now"] = "Migrate Now",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] =
			"Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background.",
		},
		["zh-Hans"] = {
			["XXTouch"] = "X.X.T.",
			["Skip Migration"] = "暂不迁移",
			["Migrate Now"] = "即刻迁移",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] =
			"检测到有越狱版 X.X.T. 文档，是否需要迁移到巨魔版？\n\n迁移会在后台进行",
		},
		["zh-Hant"] = {
			["XXTouch"] = "X.X.T.", ["Skip Migration"] = "暫不移轉", ["Migrate Now"] = "立即移轉",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] = "偵測到越獄版 X.X.T. 文件，是否移轉至 TrollStore 版？\n\n移轉會在背景進行。",
		},
		vi = {
			["XXTouch"] = "XXTouch", ["Skip Migration"] = "Chưa di chuyển", ["Migrate Now"] = "Di chuyển ngay",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] = "Đã phát hiện dữ liệu XXTouch bản jailbreak. Bạn có muốn di chuyển sang bản TrollStore không?\n\nQuá trình sẽ chạy trong nền.",
		},
		ja = {
			["XXTouch"] = "XXTouch", ["Skip Migration"] = "移行しない", ["Migrate Now"] = "今すぐ移行",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] = "脱獄版 XXTouch のデータが見つかりました。TrollStore 版へ移行しますか？\n\n移行はバックグラウンドで実行されます。",
		},
		ko = {
			["XXTouch"] = "XXTouch", ["Skip Migration"] = "나중에 이동", ["Migrate Now"] = "지금 이동",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] = "탈옥 버전 XXTouch 데이터가 발견되었습니다. TrollStore 버전으로 이동할까요?\n\n이동 작업은 백그라운드에서 진행됩니다.",
		},
		es = {
			["XXTouch"] = "XXTouch", ["Skip Migration"] = "Migrar más tarde", ["Migrate Now"] = "Migrar ahora",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] = "Se han detectado documentos de la edición jailbreak de XXTouch. ¿Deseas migrarlos a la edición TrollStore?\n\nLa migración se realizará en segundo plano.",
		},
		["pt-BR"] = {
			["XXTouch"] = "XXTouch", ["Skip Migration"] = "Migrar depois", ["Migrate Now"] = "Migrar agora",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] = "Foram detectados documentos da edição jailbreak do XXTouch. Deseja migrá-los para a edição TrollStore?\n\nA migração será realizada em segundo plano.",
		},
		ru = {
			["XXTouch"] = "XXTouch", ["Skip Migration"] = "Перенести позже", ["Migrate Now"] = "Перенести сейчас",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] = "Обнаружены документы jailbreak-версии XXTouch. Перенести их в версию TrollStore?\n\nПеренос будет выполняться в фоновом режиме.",
		},
		fr = {
			["XXTouch"] = "XXTouch", ["Skip Migration"] = "Migrer plus tard", ["Migrate Now"] = "Migrer maintenant",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] = "Des documents de l’édition jailbreak de XXTouch ont été détectés. Voulez-vous les migrer vers l’édition TrollStore ?\n\nLa migration sera effectuée en arrière-plan.",
		},
		de = {
			["XXTouch"] = "XXTouch", ["Skip Migration"] = "Später migrieren", ["Migrate Now"] = "Jetzt migrieren",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] = "Dokumente der Jailbreak-Version von XXTouch wurden erkannt. Sollen sie zur TrollStore-Version migriert werden?\n\nDie Migration wird im Hintergrund ausgeführt.",
		},
	}
	return localization.localizer(_localizations)
end)()

local lfs = require('lfs')

local path_op = file.path

local ok, buildin_files = pcall(dofile, XXT_BIN_PATH .. '/module-xxt-buildin-list.lua')

local function is_dir_empty_of_files(path) -- 符号链接也不当作是文件
	for file in lfs.dir(path) do
		if file ~= "." and file ~= ".." then
			local f = path .. "/" .. file
			local mode = lfs.symlinkattributes(f, 'mode')
			if mode == "file" then
				return false
			elseif mode == "directory" then
				if not is_dir_empty_of_files(f) then
					return false
				end
			end
		end
	end
	return true
end

local function remove_dir_if_no_files(path) -- 如果目录是符号链接，直接删除
	if lfs.symlinkattributes(path, 'mode') == 'link' then
		os.remove(path)
	elseif lfs.symlinkattributes(path, 'mode') == 'directory' and is_dir_empty_of_files(path) then
		file.remove(path)
	end
end

local function migrate_to_xxt_home(bak_prefix, jb_home_path)
	if jb_home_path then
		for _, buildin_file in ipairs(buildin_files or {}) do
			local jb_full_path = path_op.add_component(jb_home_path, buildin_file)
			os.remove(jb_full_path)
		end
		for _, jb_full_path in ipairs(file.list(jb_home_path, true) or {}) do
			if lfs.symlinkattributes(jb_full_path, 'mode') ~= 'file' then
				goto continue
			end
			local relative_path = jb_full_path:sub(#jb_home_path + 2)
			local target_full_path = path_op.add_component(XXT_HOME_PATH, relative_path)
			if file.exists(target_full_path) then
				goto continue
			end
			sys.mkdir_p(path_op.remove_last_component(target_full_path))
			file.move(jb_full_path, target_full_path)
			::continue::
		end
		remove_dir_if_no_files(jb_home_path)
		file.move(jb_home_path, XXT_SCRIPTS_PATH .. '/' .. bak_prefix .. '1ferver-' .. os.date('%Y%m%d%H%M%S'))
	end
end

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

if find_jbpath('/Applications/XXTExplorer.app') then
	return
end

-- 迁移 rootless 版脚本
local paths = file.find {
	'/private/preboot/',
	{ "^[A-F0-9]+$" },
	{ "^.+$" },
	'/procursus/var/mobile/Media/1ferver'
}

local rootless_xxt_home = paths[1]

-- 迁移 roothide 版脚本
local paths = file.find {
	'/private/var/containers/Bundle/Application/',
	{ "^%.jbroot%-[A-F0-9]+$" },
	'/var/mobile/Media/1ferver'
}

local roothide_xxt_home = paths[1]

-- if rootless_xxt_home or roothide_xxt_home then
-- 	local c = sys.alert(LLANG('Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background.'), 30, LLANG('XXTouch'), LLANG('Skip Migration'), LLANG('Migrate Now'))
-- 	if c ~= 1 then
-- 		return
-- 	end
-- else
-- 	return
-- end

migrate_to_xxt_home('rootless-', rootless_xxt_home)
migrate_to_xxt_home('roothide-', roothide_xxt_home)
