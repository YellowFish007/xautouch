--[[

	巨魔版卸载脚本

	本文件仅作为参考，请不要修改本文件
	本文件会在重装、更新时被原版覆盖

--]]

local localization = require("localization")
local interface_language = localization.current()
local LLANG = (function()
	local _localizations = {
		en = {
			["XXTouch"] = "XXTouch",
			["OK"] = "OK",
			["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] =
			"XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?\n\n(⚠️DELETION IS UNRECOVERABLE)",
			["Keep Them"] = "Keep Them",
			["Delete All"] = "Delete All",
			["You can be in `/var/mobile/Media/1ferver` to find them later."] =
			"You can be in `/var/mobile/Media/1ferver` to find them later.",
			["Cancel"] = "Cancel",
			["Delete"] = "Delete",
			["Type %s to confirm deletion\n(case-insensitive)"] = "Type %s to confirm deletion\n(case-insensitive)",
		},
		["zh-Hans"] = {
			["XXTouch"] = "X.X.T.",
			["OK"] = "好",
			["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] =
			"X.X.T. 已从设备卸载。\n\n是否需要完全删除 X.X.T. 的脚本和相关存档？\n\n（⚠️删除后不可恢复）",
			["Keep Them"] = "保留",
			["Delete All"] = "删除",
			["You can be in `/var/mobile/Media/1ferver` to find them later."] = "稍后你可以在 `/var/mobile/Media/1ferver` 找到它们",
			["Cancel"] = "取消",
			["Delete"] = "删除",
			["Type %s to confirm deletion\n(case-insensitive)"] = "输入 %s 以确认删除\n（不区分大小写）",
		},
		["zh-Hant"] = {
			["XXTouch"] = "X.X.T.", ["OK"] = "好",
			["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] = "X.X.T. 已從裝置解除安裝。\n\n是否要完整刪除 X.X.T. 的腳本及相關封存資料？\n\n（⚠️刪除後無法復原）",
			["Keep Them"] = "保留", ["Delete All"] = "全部刪除",
			["You can be in `/var/mobile/Media/1ferver` to find them later."] = "稍後可在 `/var/mobile/Media/1ferver` 找到這些檔案。",
			["Cancel"] = "取消", ["Delete"] = "刪除", ["Type %s to confirm deletion\n(case-insensitive)"] = "輸入 %s 以確認刪除\n（不區分大小寫）",
		},
		vi = {
			["XXTouch"] = "XXTouch", ["OK"] = "OK", ["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] = "XXTouch đã được gỡ cài đặt.\n\nBạn có muốn xóa hoàn toàn tập lệnh và dữ liệu liên quan không?\n\n(⚠️KHÔNG THỂ KHÔI PHỤC SAU KHI XÓA)",
			["Keep Them"] = "Giữ lại", ["Delete All"] = "Xóa tất cả", ["You can be in `/var/mobile/Media/1ferver` to find them later."] = "Bạn có thể tìm lại chúng trong `/var/mobile/Media/1ferver`.",
			["Cancel"] = "Hủy", ["Delete"] = "Xóa", ["Type %s to confirm deletion\n(case-insensitive)"] = "Nhập %s để xác nhận xóa\n(không phân biệt chữ hoa chữ thường)",
		},
		ja = {
			["XXTouch"] = "XXTouch", ["OK"] = "OK", ["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] = "XXTouch はアンインストールされました。\n\nスクリプトと関連データをすべて削除しますか？\n\n（⚠️削除後は復元できません）",
			["Keep Them"] = "残す", ["Delete All"] = "すべて削除", ["You can be in `/var/mobile/Media/1ferver` to find them later."] = "後で `/var/mobile/Media/1ferver` から確認できます。",
			["Cancel"] = "キャンセル", ["Delete"] = "削除", ["Type %s to confirm deletion\n(case-insensitive)"] = "削除を確認するには %s と入力してください\n（大文字と小文字は区別しません）",
		},
		ko = {
			["XXTouch"] = "XXTouch", ["OK"] = "확인", ["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] = "XXTouch가 제거되었습니다.\n\n스크립트와 관련 데이터를 완전히 삭제할까요?\n\n(⚠️삭제 후에는 복구할 수 없습니다)",
			["Keep Them"] = "보관", ["Delete All"] = "모두 삭제", ["You can be in `/var/mobile/Media/1ferver` to find them later."] = "나중에 `/var/mobile/Media/1ferver`에서 찾을 수 있습니다.",
			["Cancel"] = "취소", ["Delete"] = "삭제", ["Type %s to confirm deletion\n(case-insensitive)"] = "삭제를 확인하려면 %s을(를) 입력하세요\n(대소문자 구분 없음)",
		},
		es = {
			["XXTouch"] = "XXTouch", ["OK"] = "Aceptar", ["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] = "XXTouch se ha desinstalado.\n\n¿Deseas eliminar por completo los scripts y los archivos relacionados de XXTouch?\n\n(⚠️NO SE PUEDE RECUPERAR LO ELIMINADO)",
			["Keep Them"] = "Conservar", ["Delete All"] = "Eliminar todo", ["You can be in `/var/mobile/Media/1ferver` to find them later."] = "Podrás encontrarlos más tarde en `/var/mobile/Media/1ferver`.",
			["Cancel"] = "Cancelar", ["Delete"] = "Eliminar", ["Type %s to confirm deletion\n(case-insensitive)"] = "Escribe %s para confirmar la eliminación\n(no distingue entre mayúsculas y minúsculas)",
		},
		["pt-BR"] = {
			["XXTouch"] = "XXTouch", ["OK"] = "OK", ["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] = "O XXTouch foi desinstalado.\n\nDeseja excluir completamente os scripts e arquivos relacionados do XXTouch?\n\n(⚠️NÃO É POSSÍVEL RECUPERAR O CONTEÚDO EXCLUÍDO)",
			["Keep Them"] = "Manter", ["Delete All"] = "Excluir tudo", ["You can be in `/var/mobile/Media/1ferver` to find them later."] = "Você poderá encontrá-los depois em `/var/mobile/Media/1ferver`.",
			["Cancel"] = "Cancelar", ["Delete"] = "Excluir", ["Type %s to confirm deletion\n(case-insensitive)"] = "Digite %s para confirmar a exclusão\n(não diferencia maiúsculas de minúsculas)",
		},
		ru = {
			["XXTouch"] = "XXTouch", ["OK"] = "ОК", ["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] = "XXTouch удалён.\n\nПолностью удалить скрипты и связанные архивы XXTouch?\n\n(⚠️УДАЛЁННЫЕ ДАННЫЕ НЕВОЗМОЖНО ВОССТАНОВИТЬ)",
			["Keep Them"] = "Сохранить", ["Delete All"] = "Удалить всё", ["You can be in `/var/mobile/Media/1ferver` to find them later."] = "Позже их можно найти в `/var/mobile/Media/1ferver`.",
			["Cancel"] = "Отмена", ["Delete"] = "Удалить", ["Type %s to confirm deletion\n(case-insensitive)"] = "Введите %s для подтверждения удаления\n(без учёта регистра)",
		},
		fr = {
			["XXTouch"] = "XXTouch", ["OK"] = "OK", ["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] = "XXTouch a été désinstallé.\n\nVoulez-vous supprimer complètement les scripts et les archives associées de XXTouch ?\n\n(⚠️LA SUPPRESSION EST IRRÉVERSIBLE)",
			["Keep Them"] = "Conserver", ["Delete All"] = "Tout supprimer", ["You can be in `/var/mobile/Media/1ferver` to find them later."] = "Vous pourrez les retrouver plus tard dans `/var/mobile/Media/1ferver`.",
			["Cancel"] = "Annuler", ["Delete"] = "Supprimer", ["Type %s to confirm deletion\n(case-insensitive)"] = "Saisissez %s pour confirmer la suppression\n(sans distinction entre majuscules et minuscules)",
		},
		de = {
			["XXTouch"] = "XXTouch", ["OK"] = "OK", ["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] = "XXTouch wurde deinstalliert.\n\nSollen die Skripte und zugehörigen Archive von XXTouch vollständig gelöscht werden?\n\n(⚠️DAS LÖSCHEN KANN NICHT RÜCKGÄNGIG GEMACHT WERDEN)",
			["Keep Them"] = "Behalten", ["Delete All"] = "Alle löschen", ["You can be in `/var/mobile/Media/1ferver` to find them later."] = "Du kannst sie später unter `/var/mobile/Media/1ferver` finden.",
			["Cancel"] = "Abbrechen", ["Delete"] = "Löschen", ["Type %s to confirm deletion\n(case-insensitive)"] = "Gib %s ein, um das Löschen zu bestätigen\n(Groß-/Kleinschreibung wird nicht beachtet)",
		},
	}
	return function(str)
		return localization.text(_localizations, str, interface_language)
	end
end)()

function find_remove(pattern)
	local list = file.find(pattern)
	for _, path in ipairs(list or {}) do
		file.remove(path)
	end
end

function remove_app_caches(name)
	file.remove('/var/root/Library/WebKit/' .. name)
	file.remove('/var/root/Library/Caches/' .. name)
	file.remove('/var/root/Library/HTTPStorages/' .. name)
	file.remove('/var/root/Library/SplashBoard/Snapshots/' .. name)
	file.remove('/var/root/Library/Saved Application State/' .. name .. '.savedState')
	file.remove('/var/mobile/Library/Caches/' .. name)
	file.remove('/var/mobile/Library/WebKit/' .. name)
	file.remove('/var/mobile/Library/HTTPStorages/' .. name)
	file.remove('/var/mobile/Library/SplashBoard/Snapshots/' .. name)
	file.remove('/var/mobile/Library/Saved Application State/' .. name .. '.savedState')
end

function remove_app_preferences(name)
	file.remove('/var/root/Library/Preferences/' .. name .. '.plist')
	file.remove('/var/mobile/Library/Preferences/' .. name .. '.plist')
end

find_remove('/private/var/containers/Bundle/Application/.jbroot-*/Library/MobileSubstrate/DynamicLibraries/1feaks.*')
find_remove('/private/var/containers/Bundle/Application/.jbroot-*/usr/lib/TweakInject/1feaks.*')
find_remove { '/private/preboot/', { '^[A-F0-9]+$' }, { '^.+$' }, '/procursus/Library/MobileSubstrate/DynamicLibraries/', { '^1feaks.+$' } }
find_remove { '/private/preboot/', { '^[A-F0-9]+$' }, { '^.+$' }, '/procursus/usr/lib/TweakInject/', { '^1feaks.+$' } }

remove_app_caches('com.xxtouch.XXTExplorer')
remove_app_caches('app.xxtouch.XXTUIService')
remove_app_preferences('app.xxtouch.XXTUIService')

file.remove(XXT_USER_DEFAULTS_PATH)

local path_op = file.path

local ok, buildin_files = pcall(dofile, XXT_BIN_PATH .. '/module-xxt-buildin-list.lua')
if ok then
	for _, buildin_file in ipairs(buildin_files or {}) do
		local ts_full_path = path_op.add_component(XXT_HOME_PATH, buildin_file)
		os.remove(ts_full_path)
	end
end

find_remove { '/tmp/', { '^%.xxtouch.+$' } }
find_remove { '/tmp/', { '^%.1ferver.+$' } }

if sys.alert(LLANG("XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"), 0, LLANG("XXTouch"), LLANG("Keep Them"), LLANG("Delete All")) == 1 then
	math.randomseed(sys.rnd())
	local del, choice
	local ranstr
	repeat
		ranstr = string.random("QWERTYUIOPASDFGHJKLZXCVBNM", 3)
		del, choice = sys.input_box(LLANG('XXTouch'),
			string.format(LLANG('Type %s to confirm deletion\n(case-insensitive)'), ranstr), ranstr, '', '',
			LLANG('Cancel'), LLANG('Delete'), 0)
	until choice ~= 2 or (del:upper() == ranstr and choice == 2)
	if choice ~= 2 then
		return
	end
	remove_app_preferences('com.xxtouch.XXTExplorer')
	file.remove('/var/mobile/Library/uicfg')
	file.remove('/tmp/1ferver.backup')
	file.move(XXT_HOME_PATH, '/tmp/1ferver.backup')
	file.remove(XXT_HOME_PATH)
	sys.killall(9, 'cfprefsd')
else
	sys.killall(9, 'cfprefsd')
	local kept_message = LLANG("You can be in `/var/mobile/Media/1ferver` to find them later.")
	kept_message = kept_message:gsub('/var/mobile/Media/1ferver', XXT_HOME_PATH, 1)
	sys.alert(kept_message, 0, LLANG("XXTouch"), LLANG("OK"))
end
