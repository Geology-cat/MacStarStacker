import os
import subprocess
import glob

def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return p.stdout

def bundle_app(app_path):
    macos_dir = os.path.join(app_path, "Contents", "MacOS")
    frameworks_dir = os.path.join(app_path, "Contents", "Frameworks")
    os.makedirs(frameworks_dir, exist_ok=True)
    
    bin_name = os.listdir(macos_dir)[0]
    main_bin = os.path.join(macos_dir, bin_name)

    print(f"Bundling {main_bin}...")

    # 1. バイナリが参照している /usr/local/ または /opt/homebrew/ の dylib を探す
    processed_dylibs = set()
    to_process = [main_bin]

    while to_process:
        curr_target = to_process.pop(0)
        out = run(["otool", "-L", curr_target])
        for line in out.splitlines():
            line = line.strip()
            if not line or line.startswith(curr_target) or line.startswith("Archive :"):
                continue
            parts = line.split()
            if not parts:
                continue
            dylib_path = parts[0]
            
            # /usr/local/ または /opt/homebrew/ の OpenCV / ライブラリを対象にする
            if dylib_path.startswith("/usr/local/") or dylib_path.startswith("/opt/homebrew/"):
                if "libSystem" in dylib_path or "libc++" in dylib_path or "libobjc" in dylib_path:
                    continue
                
                dylib_name = os.path.basename(dylib_path)
                dest_dylib = os.path.join(frameworks_dir, dylib_name)
                
                # まだコピーしていなければコピー
                if dylib_path not in processed_dylibs:
                    processed_dylibs.add(dylib_path)
                    if os.path.exists(dylib_path) and not os.path.exists(dest_dylib):
                        # 実ファイルをコピー
                        run(["cp", "-L", dylib_path, dest_dylib])
                        os.chmod(dest_dylib, 0o755)
                        to_process.append(dest_dylib)
                
                # curr_target 内の参照を @executable_path/../Frameworks/ に変更
                if curr_target == main_bin:
                    new_ref = f"@executable_path/../Frameworks/{dylib_name}"
                else:
                    new_ref = f"@loader_path/{dylib_name}"
                
                run(["install_name_tool", "-change", dylib_path, new_ref, curr_target])

    # 2. Frameworks 内の全 dylib の id と依存関係を @loader_path に修正
    for dylib_file in glob.glob(os.path.join(frameworks_dir, "*.dylib")):
        dylib_name = os.path.basename(dylib_file)
        run(["install_name_tool", "-id", f"@loader_path/{dylib_name}", dylib_file])
        
        out = run(["otool", "-L", dylib_file])
        for line in out.splitlines():
            parts = line.strip().split()
            if not parts:
                continue
            dep_path = parts[0]
            if (dep_path.startswith("/usr/local/") or dep_path.startswith("/opt/homebrew/")) and "libSystem" not in dep_path and "libc++" not in dep_path:
                dep_name = os.path.basename(dep_path)
                run(["install_name_tool", "-change", dep_path, f"@loader_path/{dep_name}", dylib_file])

    # 3. main_bin の rpath に @executable_path/../Frameworks を追加
    run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", main_bin])
    
    print("Bundle fix complete!")

if __name__ == "__main__":
    app_path = "/Users/yamashitaujou/Desktop/アプリ作成/MacStarStacker/MacStarStacker.app"
    bundle_app(app_path)
