#!/usr/bin/env bats
# 跨平台：macOS（Intel / Apple Silicon）与 Linux（x86_64 / arm64）、bash 3.2、无 GNU 工具时的回退
load helpers

setup() {
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/config.sh"
  source "$REPO_ROOT/lib/node.sh"
  source "$REPO_ROOT/lib/mcp.sh"
  printf 'abc' >"$SANDBOX/abc.txt"
}
teardown() { teardown_sandbox; }

fake_uname() { make_stub uname "case \"\$1\" in -s) echo $1 ;; -m) echo $2 ;; *) echo $1 ;; esac"; }
# 只包含指定工具的 PATH（模拟缺少 sha256sum / timeout 的 macOS）
limited_path() {
  local dir="$SANDBOX/limited" t
  mkdir -p "$dir"
  for t in "$@"; do ln -sf "$(type -P "$t")" "$dir/$t"; done
  printf '%s' "$dir"
}

@test "os_name / node_arch：四种平台组合" {
  [ "$(os_name Linux)" = linux ]
  [ "$(os_name Darwin)" = darwin ]
  run os_name FreeBSD
  [ "$status" -ne 0 ]
  [ "$(node_arch x86_64)" = x64 ]
  [ "$(node_arch arm64)" = arm64 ]
  [ "$(node_arch aarch64)" = arm64 ]
}

@test "Node 与 uv：四种平台组合都内置了 SHA256" {
  local p
  for p in linux-x64 linux-arm64 darwin-x64 darwin-arm64; do
    [ -n "$(_node_sha256 "$p.tar.xz")" ]
    [ -n "$(_node_sha256 "$p.tar.gz")" ]
  done
  for p in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-apple-darwin aarch64-apple-darwin; do
    [ -n "$(_uv_sha256 "$p")" ]
  done
}

@test "_uv_target：按系统与架构选择发行包" {
  export PATH="$STUB_BIN:$PATH"
  fake_uname Darwin arm64;   [ "$(_uv_target)" = aarch64-apple-darwin ]
  fake_uname Darwin x86_64;  [ "$(_uv_target)" = x86_64-apple-darwin ]
  fake_uname Linux aarch64;  [ "$(_uv_target)" = aarch64-unknown-linux-gnu ]
  fake_uname Linux x86_64;   [ "$(_uv_target)" = x86_64-unknown-linux-gnu ]
}

@test "install_private_node：Apple Silicon 下载 darwin-arm64 发行包" {
  fake_uname Darwin arm64
  make_stub curl 'while [ $# -gt 0 ]; do case "$1" in https://*) echo "$1" >>"$CURL_LOG" ;; esac; shift; done; exit 22'
  export PATH="$STUB_BIN:$PATH" CURL_LOG="$SANDBOX/curl.log"
  run install_private_node
  [ "$status" -ne 0 ]
  grep -Eq '/v24\.22\.2/node-v24\.22\.2-darwin-arm64\.tar\.(xz|gz)$' "$CURL_LOG"
}

@test "sha256_of：GNU sha256sum 与无 sha256sum 时的 openssl 回退结果一致" {
  local expected=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  [ "$(sha256_of "$SANDBOX/abc.txt")" = "$expected" ]
  [ "$(printf 'abc' | sha256_of -)" = "$expected" ]
  local p
  p="$(limited_path openssl awk)"
  [ "$(PATH="$p" sha256_of "$SANDBOX/abc.txt")" = "$expected" ]
  [ "$(printf 'abc' | PATH="$p" sha256_of -)" = "$expected" ]
  PATH="$p" verify_sha256 "$SANDBOX/abc.txt" "$expected"
}

@test "run_timeout：无 timeout 命令时用 perl alarm，超时返回 124" {
  local p
  p="$(limited_path perl sleep true bash)"
  PATH="$p" run_timeout 5 true
  run env PATH="$p" bash -c "source '$REPO_ROOT/lib/common.sh'; run_timeout 1 sleep 5"
  [ "$status" -eq 124 ]
}

@test "resolve_path：readlink 不支持 -f 时回退" {
  ln -s "$SANDBOX/abc.txt" "$SANDBOX/link"
  make_stub readlink 'if [ "$1" = -f ]; then echo "readlink: illegal option -- f" >&2; exit 1; fi; exec /usr/bin/readlink "$@"'
  [ "$(PATH="$STUB_BIN:$PATH" resolve_path "$SANDBOX/link")" = "$SANDBOX/abc.txt" ]
}

@test "apply_aws_profile_hint：仅在无凭证变量且存在 default profile 时设置 AWS_PROFILE" {
  unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
  apply_aws_profile_hint
  [ -z "${AWS_PROFILE:-}" ]
  mkdir -p "$HOME/.aws"
  printf '[default]\nregion = ap-northeast-1\n' >"$HOME/.aws/config"
  apply_aws_profile_hint
  [ "$AWS_PROFILE" = default ]
  unset AWS_PROFILE
  export AWS_CONTAINER_CREDENTIALS_FULL_URI=http://localhost:1338/x
  apply_aws_profile_hint
  [ -z "${AWS_PROFILE:-}" ]
}

@test "apply_default_region：未设置 AWS_REGION 时使用安装时记录的区域" {
  unset AWS_REGION AWS_DEFAULT_REGION
  export PI_DEFAULT_AWS_REGION=ap-northeast-1
  apply_default_region
  [ "$AWS_REGION" = ap-northeast-1 ]
  export AWS_REGION=us-west-2
  apply_default_region
  [ "$AWS_REGION" = us-west-2 ]
}

@test "rc_files：macOS 写入 ~/.zshrc（并在已存在时写入 ~/.bash_profile），Linux 仅 ~/.bashrc" {
  export PATH="$STUB_BIN:$PATH" SHELL=/bin/bash
  fake_uname Linux x86_64
  [ "$(rc_files)" = "$HOME/.bashrc" ]
  fake_uname Darwin arm64
  [ "$(rc_files | tr '\n' ' ')" = "$HOME/.bashrc $HOME/.zshrc " ]
  touch "$HOME/.bash_profile"
  [ "$(rc_files | tr '\n' ' ')" = "$HOME/.bashrc $HOME/.zshrc $HOME/.bash_profile " ]
}

@test "静态检查：变量后不能直接跟非 ASCII 字符（macOS bash 3.2 会把多字节首字节并入变量名）" {
  run perl -ne 'print "$ARGV:$.: $_" if /(?<!\\)\$[A-Za-z_]\w*[^\x00-\x7F]/; close ARGV if eof' \
    "$REPO_ROOT"/install.sh "$REPO_ROOT"/uninstall.sh "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/bin/pi \
    "$REPO_ROOT"/bin/pi-bedrock-doctor "$REPO_ROOT"/bin/aws-mcp-proxy "$REPO_ROOT"/tests/e2e/*.sh
  echo "$output"
  [ -z "$output" ]
}

@test "path_immutable：系统目录不可写为真，用户可写目录为假" {
  [ "$(id -u)" -eq 0 ] && skip "root 对所有路径可写"
  path_immutable /usr/bin
  ! path_immutable "$HOME"
  mkdir -p "$SANDBOX/opt/homebrew/bin"
  ! path_immutable "$SANDBOX/opt/homebrew/bin/node"
}

@test "extract_zip：目标目录不存在时自动创建" {
  python3 -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("uv.exe","x"); z.close()' "$SANDBOX/a.zip"
  SYSTEMROOT= extract_zip "$SANDBOX/a.zip" "$SANDBOX/new/dir"
  [ -f "$SANDBOX/new/dir/uv.exe" ]
}
