#!/usr/bin/env bats
# Windows（Git Bash / MSYS2）分支：在 Linux 上用桩命令模拟 uname / cygpath，验证路径与文件布局逻辑
load helpers

setup() {
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/config.sh"
  source "$REPO_ROOT/lib/node.sh"
  source "$REPO_ROOT/lib/pi.sh"
  source "$REPO_ROOT/lib/mcp.sh"
  # 模拟 Git Bash：uname -s 为 MINGW64_NT，cygpath -m/-u/-w 做简单的盘符转换
  make_stub uname 'case "$1" in -s) echo MINGW64_NT-10.0-20348 ;; -m) echo x86_64 ;; *) echo MINGW64_NT-10.0-20348 ;; esac'
  make_stub cygpath '
mode="$1"; shift; [ "$1" = -s ] && shift
p="$1"
case "$mode" in
  -m) case "$p" in /c/*) echo "C:/${p#/c/}" ;; /) echo "C:/Git/" ;; *) echo "$p" ;; esac ;;
  -u) case "$p" in C:/*) echo "/c/${p#C:/}" ;; *) echo "$p" ;; esac ;;
  -w) echo "$p" | sed "s#/#\\\\#g" ;;
esac'
  export PATH="$STUB_BIN:$PATH"
}
teardown() { teardown_sandbox; }

@test "os_name：MINGW / MSYS 识别为 windows；默认安装路径为 C:/... 形式" {
  [ "$(os_name MINGW64_NT-10.0-20348)" = windows ]
  [ "$(os_name MSYS_NT-10.0)" = windows ]
  is_windows
  HOME=/c/Users/Me run _pi_base_home
  [ "$output" = C:/Users/Me ]
}

@test "is_valid_install_path：接受 /... 与 C:/...，拒绝空格、反斜杠、相对路径" {
  is_valid_install_path /home/me/.local
  is_valid_install_path C:/Users/Me/.local/share/pi-bedrock
  ! is_valid_install_path 'C:/Users/John Smith/.local'
  ! is_valid_install_path 'C:\Users\Me'
  ! is_valid_install_path relative/path
}

@test "node_arch：PI_HOST_ARCH 覆盖 uname -m（Windows on ARM 上的 x64 Git Bash）" {
  PI_HOST_ARCH=arm64 run node_arch
  [ "$output" = arm64 ]
  [ "$(node_arch)" = x64 ]
}

@test "Node / uv：Windows x64 与 ARM64 的 zip 内置 SHA256；uv target 为 pc-windows-msvc" {
  [ -n "$(_node_sha256 win-x64.zip)" ]
  [ -n "$(_node_sha256 win-arm64.zip)" ]
  [ "$(_uv_target)" = x86_64-pc-windows-msvc ]
  [ "$(PI_HOST_ARCH=arm64 _uv_target)" = aarch64-pc-windows-msvc ]
  [ -n "$(_uv_sha256 x86_64-pc-windows-msvc)" ]
  [ -n "$(_uv_sha256 aarch64-pc-windows-msvc)" ]
}

@test "Windows 文件布局：私有 Node 不用 current 符号链接；npm 全局包在 PREFIX/node_modules；venv 用 Scripts/" {
  [ "$(private_node_bin)" = "$PI_BEDROCK_HOME/node/node-v$PI_NODE_VERSION-win-x64" ]
  [ "$(pi_package_dir /p)" = "/p/node_modules/@earendil-works/pi-coding-agent" ]
  [ "$(_venv_bin /v)" = /v/Scripts ]
  [ "$(_venv_python /v)" = /v/Scripts/python.exe ]
}

@test "pi_entry：Windows 上取 package.json 的 bin.pi，拒绝可疑的相对路径" {
  local prefix="$SANDBOX/npm" dir
  dir="$(pi_package_dir "$prefix")"
  mkdir -p "$dir/dist/bundle"
  PI_BEDROCK_NODE_BIN="$(dirname "$(command -v node)")"
  printf '{"bin":{"pi":"dist/bundle/cli.js"}}' >"$dir/package.json"
  [ "$(pi_entry "$prefix")" = "$dir/dist/bundle/cli.js" ]
  printf '{"bin":{"pi":"../../evil.js"}}' >"$dir/package.json"
  ! pi_entry "$prefix"
}

@test "_path_entry：C:/... 转为 /c/...（Git Bash 的 PATH 以 : 分隔），其他路径不变" {
  [ "$(_path_entry C:/Users/Me/.local/bin)" = /c/Users/Me/.local/bin ]
  [ "$(_path_entry /usr/local/bin)" = /usr/local/bin ]
}

@test "aws_user_home：Windows 上为 USERPROFILE（AWS CLI 忽略 HOME）" {
  HOME=/c/home-elsewhere USERPROFILE=C:/Users/Me run aws_user_home
  [ "$output" = /c/Users/Me ]
}

@test "git_bash_path：PI_GIT_BASH 优先；否则为 Git 根目录下的 bin/bash.exe" {
  mkdir -p "$SANDBOX/git/bin" && touch "$SANDBOX/git/bin/bash.exe"
  PI_GIT_BASH="$SANDBOX/git/bin/bash.exe" run git_bash_path
  [ "$status" -eq 0 ]
  [[ "$output" == *'\git\bin\bash.exe' ]]
  PI_GIT_BASH="$SANDBOX/missing.exe" run git_bash_path
  [ "$status" -ne 0 ]
}

@test "shellCommandPrefix 恢复 MSYS 路径转换（包装器为 pi 进程关闭了它）" {
  run env MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 bash -c "$(shell_prefix_snippet)"$'\n''echo "[${MSYS2_ARG_CONV_EXCL:-}${MSYS_NO_PATHCONV:-}]"'
  [ "$output" = "[]" ]
}

@test "PowerShell 脚本为 UTF-8 with BOM（Windows PowerShell 5.1 按 ANSI 代码页读取无 BOM 文件，中文会破坏语法）" {
  local f
  for f in "$REPO_ROOT"/install.ps1 "$REPO_ROOT"/uninstall.ps1 "$REPO_ROOT"/tests/windows/*.ps1; do
    [ "$(head -c3 "$f" | od -An -tx1 | tr -d ' ')" = efbbbf ] || { echo "缺少 BOM: $f"; return 1; }
  done
}

@test ".cmd shim 只含 ASCII 与 CRLF 换行（cmd.exe 按 OEM 代码页解析批处理）" {
  source "$REPO_ROOT/lib/common.sh"
  _writable() { :; }
  git_bash_path() { printf 'C:\\Git\\bin\\bash.exe'; }
  mkdir -p "$PI_BIN_DIR"
  eval "$(sed -n '/^install_windows_shims()/,/^}/p' "$REPO_ROOT/install.sh")"
  install_windows_shims
  ! LC_ALL=C grep -q '[^ -~]' <(tr -d '\r\n' <"$PI_BIN_DIR/pi.cmd")
  [ "$(head -n1 "$PI_BIN_DIR/pi.cmd" | od -An -c | tr -d ' \n')" = '@echooff\r\n' ]
  grep -qF '"C:\Git\bin\bash.exe" "'"$PI_BIN_DIR"'/pi" %*' "$PI_BIN_DIR/pi.cmd"
  grep -q '%\*' "$PI_BIN_DIR/pi.cmd"
}

@test "_strip_cr：去掉 Windows 原生程序输出中的 \\r 并保留退出码" {
  make_stub crlf 'printf "us-east-1\r\n"; exit "${1:-0}"'
  [ "$(_strip_cr crlf)" = us-east-1 ]
  is_valid_region "$(_strip_cr crlf)"
  run _strip_cr crlf 3
  [ "$status" -eq 3 ]
  make_stub profiles 'printf "default\r\npi-bedrock\r\n"'
  [ "$(_strip_cr profiles | sed -n 2p)" = pi-bedrock ]
}

@test "download：Windows 上加 --ssl-revoke-best-effort（schannel 吊销服务器不可达时不失败），仍限定 HTTPS" {
  make_stub curl "echo \"\$*\" >'$SANDBOX/curl.args'"
  download https://example.com/x "$SANDBOX/x"
  grep -q -- "--ssl-revoke-best-effort" "$SANDBOX/curl.args"
  grep -q -- "--retry-all-errors" "$SANDBOX/curl.args"
  grep -q -- "--proto =https" "$SANDBOX/curl.args"
}

@test "静态检查：不用 import.meta.url 与 file://argv[1] 比较判断是否直接运行（Windows 上恒不相等，脚本静默不执行）" {
  run grep -rln 'file://\${process.argv\|pathToFileURL(process.argv' "$REPO_ROOT/lib" "$REPO_ROOT/bin" "$REPO_ROOT/extensions"
  [ -z "$output" ]
}
