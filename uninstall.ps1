<#
.SYNOPSIS
  pi-cli-on-aws Windows 卸载：在 Git Bash 中运行 uninstall.sh（移除 pi、Node.js、MCP 代理、skills、护栏与 pi 配置中
  本工具写入的内容），再从用户 PATH 中移除 %USERPROFILE%\.local\bin。
  不会卸载 Git for Windows 与 AWS CLI（可在"设置 → 应用"中卸载），也不会删除 ~/.aws 中的凭证与 ~/.pi/agent 中的会话。
#>
[CmdletBinding()]
param([string]$GitBash)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Find-GitBash([string]$Hint) {
  $candidates = @($Hint, $env:PI_GIT_BASH)
  foreach ($root in @($env:ProgramFiles, $env:ProgramW6432, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
    if ($root) { $candidates += (Join-Path $root 'Git\bin\bash.exe') }
  }
  foreach ($path in $candidates) {
    if ($path -and ($path -notmatch '\\(System32|Sysnative)\\bash\.exe$') -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
  }
  return $null
}

function Remove-UserPath([string]$Dir) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  try {
    $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($raw -eq '') { return }
    $kept = @($raw -split ';' | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ine $Dir.TrimEnd('\') })
    if ($kept.Count -eq @($raw -split ';' | Where-Object { $_ -ne '' }).Count) { return }
    $key.SetValue('Path', ($kept -join ';'), $key.GetValueKind('Path'))
  } finally {
    $key.Close()
  }
  [Environment]::SetEnvironmentVariable('PI_CLI_ON_AWS_PATH_REFRESH', '1', 'User')
  [Environment]::SetEnvironmentVariable('PI_CLI_ON_AWS_PATH_REFRESH', $null, 'User')
  Write-Host "==> 已从用户 PATH 中移除 $Dir" -ForegroundColor Green
}

try {
  $home_ = if ($env:PI_BEDROCK_HOME) { $env:PI_BEDROCK_HOME } else { Join-Path $env:USERPROFILE '.local\share\pi-bedrock' }
  $script = Join-Path $PSScriptRoot 'uninstall.sh'
  if (-not (Test-Path -LiteralPath $script)) { $script = Join-Path $home_ 'uninstall.sh' }
  if (-not (Test-Path -LiteralPath $script)) { throw "未找到 uninstall.sh（$home_），可能已卸载" }
  $bash = Find-GitBash $GitBash
  if (-not $bash) { throw '未找到 Git for Windows 的 bin\bash.exe，请使用 -GitBash 指定' }
  # 从临时副本运行：bash 执行期间持有脚本文件，Windows 上无法删除仍被打开的文件所在的安装目录
  $runDir = Join-Path ([IO.Path]::GetTempPath()) ('pi-bedrock-uninstall-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $runDir | Out-Null
  Copy-Item -LiteralPath $script -Destination $runDir
  Copy-Item -LiteralPath (Join-Path (Split-Path $script) 'lib') -Destination $runDir -Recurse
  $env:PI_BEDROCK_HOME = $home_ -replace '\\', '/'
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $runScript = (Join-Path $runDir 'uninstall.sh') -replace '\\', '/'
    if ([Console]::IsOutputRedirected -or [Console]::IsErrorRedirected) {
      & $bash $runScript 2>&1 | ForEach-Object { [Console]::Out.WriteLine([string]$_) }
    } else {
      & $bash $runScript
    }
  } finally {
    $ErrorActionPreference = $previous
    Remove-Item -Recurse -Force -LiteralPath $runDir -ErrorAction SilentlyContinue
  }
  if ($LASTEXITCODE -ne 0) { throw "uninstall.sh 执行失败（退出码 $LASTEXITCODE）" }
  $binDir = if ($env:PI_BIN_DIR) { $env:PI_BIN_DIR -replace '/', '\' } else { Join-Path $env:USERPROFILE '.local\bin' }
  $leftover = @(Get-ChildItem -LiteralPath $binDir -Force -ErrorAction SilentlyContinue)
  if ($leftover.Count -eq 0) {
    Remove-UserPath $binDir
    Remove-Item -LiteralPath $binDir -Force -ErrorAction SilentlyContinue
  }
} catch {
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
