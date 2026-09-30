-- MacStarStacker かんたんインストーラ
--
-- DMG の中の MacStarStacker.app を「アプリケーション」フォルダへコピーし、初回起動の確認（Gatekeeper）が出ないよう
-- ダウンロードしたファイルに付く隔離属性（com.apple.quarantine）を外してから起動する。
-- MacStarStacker は Apple の Developer ID で署名・公証していないため、そのままでは初回起動が止められる。
--
-- build_app.sh が osacompile で「かんたんインストーラ.scpt」にして DMG に入れる。
-- installFolder を書き換えて osacompile すれば、別のフォルダへのインストールで試せる。

property appName : "MacStarStacker.app"
property bundleID : "com.local.macsequator"
property installFolder : "/Applications/"
property dialogTitle : "MacStarStacker かんたんインストーラ"

on run
	set sourceApp to my findSourceApp()
	if sourceApp is missing value then
		display dialog "「" & appName & "」が見つかりませんでした。" & return & return & ¬
			"ダウンロードした DMG を開き、その中の「かんたんインストーラ」を実行してください。" ¬
			buttons {"OK"} default button "OK" with title dialogTitle with icon stop
		return
	end if
	set destination to installFolder & appName

	set message to "MacStarStacker を「アプリケーション」フォルダにインストールします。" & return & return & ¬
		"1. 「アプリケーション」フォルダへのコピー" & return & ¬
		"2. 初回起動の確認（Gatekeeper）の解除" & return & ¬
		"3. 起動" & return & return & "を行います。"
	if my pathExists(destination) then
		set message to message & return & return & "すでにインストールされている MacStarStacker は、この DMG のものに置き換えます。"
	end if
	-- キャンセルを押すとここで終わる
	display dialog message buttons {"キャンセル", "インストール"} default button "インストール" ¬
		cancel button "キャンセル" with title dialogTitle with icon note

	my quitRunningApp()

	-- コピー（古いものを消してから）に失敗したら止める。隔離属性は付いていなくてもよい
	set commands to "(rm -rf " & quoted form of destination & " && ditto " & quoted form of sourceApp & " " & ¬
		quoted form of destination & ") || exit 1; xattr -dr com.apple.quarantine " & quoted form of destination & ¬
		" 2>/dev/null; exit 0"
	try
		do shell script commands
	on error
		-- 「アプリケーション」フォルダに書き込む権限が無いときは、管理者のパスワードを求めて行う
		try
			do shell script commands with administrator privileges
		on error errorMessage number errorNumber
			if errorNumber is -128 then return
			display dialog "インストールできませんでした。" & return & return & errorMessage ¬
				buttons {"OK"} default button "OK" with title dialogTitle with icon stop
			return
		end try
	end try

	do shell script "open " & quoted form of destination
	display dialog "インストールが終わり、MacStarStacker を起動しました。" & return & return & ¬
		"次からは「アプリケーション」フォルダや Launchpad から起動できます。DMG は取り出してかまいません。" ¬
		buttons {"OK"} default button "OK" with title dialogTitle with icon note giving up after 30
end run

-- DMG の中の MacStarStacker.app。このスクリプトと同じフォルダを探し、見つからなければ（スクリプトエディタから
-- 実行して自分の場所が分からないときなど）マウントされているボリュームの一番上を探す
on findSourceApp()
	try
		set myFolder to do shell script "dirname " & quoted form of POSIX path of (path to me)
		set candidate to myFolder & "/" & appName
		if my pathExists(candidate) then return candidate
	end try
	try
		set found to do shell script "for app in /Volumes/*/" & quoted form of appName & ¬
			"; do [ -d \"$app\" ] && echo \"$app\" && break; done; exit 0"
		if found is not "" then return found
	end try
	return missing value
end findSourceApp

on pathExists(p)
	try
		do shell script "test -e " & quoted form of p
		return true
	on error
		return false
	end try
end pathExists

-- 起動中の MacStarStacker を終了し、終わるまで少し待つ（置き換えられるように）
on quitRunningApp()
	try
		if application id bundleID is running then
			tell application id bundleID to quit
			repeat 20 times
				if not (application id bundleID is running) then exit repeat
				delay 0.5
			end repeat
		end if
	end try
end quitRunningApp
