<#
.SYNOPSIS
  pi-cli-on-aws Windows 安装器：安装 pi coding agent（默认 Amazon Bedrock + Kimi K3.1）、AWS MCP Server、
  运维 skills 与 AWS 写操作护栏。

.DESCRIPTION
  pi 的 bash 工具与本项目的安装逻辑都运行在 Git Bash 中：
    1. 查找 Git for Windows；没有则从 GitHub 下载官方安装包（内置 SHA256 校验），按当前用户静默安装（无需管理员）
    2. 检查 AWS CLI v2；没有则提示安装（官方 MSI，校验 Amazon 数字签名；需要管理员授权）
    3. 用 Git Bash 运行 install.sh：引导配置 AWS 凭证、安装私有 Node.js / pi / MCP 代理，写入 pi 配置
    4. 生成 pi.cmd 等命令并把 %USERPROFILE%\.local\bin 加入用户 PATH
  兼容 Windows PowerShell 5.1 与 PowerShell 7；支持 x64 与 ARM64。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -Region ap-southeast-1 -Thinking high
#>
[CmdletBinding()]
param(
  [string]$Region,
  [switch]$NoProbe,
  [string]$Model,
  [ValidateSet('off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')][string]$Thinking,
  [switch]$NoMcp,
  [switch]$NoSkills,
  [switch]$AllModels,
  # 指定 Git Bash（bin\bash.exe）路径；默认自动查找
  [string]$GitBash,
  # 缺少 AWS CLI 时不询问，直接安装（非交互环境使用）
  [switch]$InstallAwsCli
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Git for Windows 官方安装包（版本与 SHA256 固定；升级时同时更新，哈希取自 GitHub release 页面）
$GitBaseUrl = 'https://github.com/git-for-windows/git/releases/download/v2.56.1.windows.1'
$GitInstallers = @{
  X64   = @{ Name = 'Git-2.56.1-64-bit.exe'; Sha256 = 'c330c72e10b408cc39994bfefdb63542b0d93d21699325c3e0bd874af8a5a559' }
  Arm64 = @{ Name = 'Git-2.56.1-arm64.exe'; Sha256 = '6fe770b534a459d1158011e6ec0cd8390a3bcf44e542bee9e9a650310e111234' }
}
$AwsCliMsiUrl = 'https://awscli.amazonaws.com/AWSCLIV2.msi'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "WARN: $Message" -ForegroundColor Yellow }

function Test-Interactive {
  return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

function Get-HostArch {
  $arch = $null
  try { $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { $arch = $null }
  if (-not $arch) { $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE } }
  switch -Regex ($arch) {
    '^(X64|AMD64)$' { return 'X64' }
    '^ARM64$' { return 'Arm64' }
    default { throw "不支持的 CPU 架构: $arch（支持 x64 / ARM64）" }
  }
}

function New-TempDir {
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('pi-bedrock-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $dir | Out-Null
  return $dir
}

# Program Files 目录：取自 HKLM 注册表（用户级环境变量可以覆盖 $env:ProgramFiles）
function Get-ProgramFilesDir {
  $key = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion'
  $dir = if ($key.PSObject.Properties.Name -contains 'ProgramW6432Dir') { $key.ProgramW6432Dir } else { $key.ProgramFilesDir }
  if (-not $dir) { throw '无法从注册表读取 Program Files 目录' }
  return $dir
}

function Test-UnderDir([string]$Path, [string]$Dir) {
  $p = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
  $d = [IO.Path]::GetFullPath($Dir).TrimEnd('\') + '\'
  return $p.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)
}

# 下载后以只读共享方式打开并持有，直到调用方关闭：校验与执行之间文件不能被替换（防 TOCTOU）
function Open-VerifiedDownload([string]$Url, [string]$OutFile, [string]$Sha256) {
  Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile
  $stream = [IO.File]::Open($OutFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  if ($Sha256) {
    $actual = (Get-FileHash -Algorithm SHA256 -InputStream $stream).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) { $stream.Dispose(); throw "SHA256 校验失败: $Url（期望 $Sha256，实际 $actual），已中止" }
  }
  return $stream
}

# 查找 Git for Windows 的 bin\bash.exe（排除 System32 下的 WSL bash）
function Find-GitBash([string]$Hint) {
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($Hint) { $candidates.Add($Hint) }
  foreach ($root in @($env:ProgramFiles, $env:ProgramW6432, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
    if ($root) { $candidates.Add((Join-Path $root 'Git\bin\bash.exe')) }
  }
  $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($git) { $candidates.Add((Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe')) }
  foreach ($path in $candidates) {
    if ($path -and ($path -notmatch '\\(System32|Sysnative)\\bash\.exe$') -and (Test-Path -LiteralPath $path -PathType Leaf)) {
      return (Resolve-Path -LiteralPath $path).Path
    }
  }
  return $null
}

$UserGitNote = 'Git for Windows 位于当前用户可写的目录：护栏会把它作为受保护位置，bash 中的 aws 命令需逐条确认（AWS MCP 只读调用不受影响）。如需自动执行只读 aws 命令，请把 Git for Windows 安装到 Program Files（以管理员身份重新运行 install.ps1）'

# 静默安装 Git for Windows（Inno Setup）：优先安装到 Program Files（仅管理员可写，护栏可信任其中的 bash / env）；
# 无管理员权限或用户拒绝 UAC 时，按当前用户安装到 %LOCALAPPDATA%\Programs\Git
function Install-GitForWindows([string]$Arch) {
  $spec = $GitInstallers[$Arch]
  $tmp = New-TempDir
  $lock = $null
  try {
    $exe = Join-Path $tmp $spec.Name
    Write-Step "下载 Git for Windows（$($spec.Name)，SHA256 校验）"
    $lock = Open-VerifiedDownload "$GitBaseUrl/$($spec.Name)" $exe $spec.Sha256
    $common = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCANCEL', '/SP-', '/NOICONS')
    $machineDir = Join-Path (Get-ProgramFilesDir) 'Git'
    $machineArgs = $common + @('/ALLUSERS', "/DIR=`"$machineDir`"")
    $proc = $null
    if (Test-Admin) {
      Write-Step "安装 Git for Windows 到 $machineDir（约 1-3 分钟）"
      $proc = Start-Process -FilePath $exe -ArgumentList $machineArgs -Wait -PassThru
    } elseif (Test-Interactive) {
      Write-Step "安装 Git for Windows 到 $machineDir 需要管理员授权，请在 UAC 窗口中确认（拒绝则按当前用户安装）"
      try {
        $proc = Start-Process -FilePath $exe -ArgumentList $machineArgs -Verb RunAs -Wait -PassThru
      } catch {
        Write-Warn "未获得管理员授权（$($_.Exception.Message)）"
      }
    }
    $dir = $machineDir
    if (-not $proc -or $proc.ExitCode -ne 0) {
      $dir = Join-Path $env:LOCALAPPDATA 'Programs\Git'
      Write-Step "按当前用户安装 Git for Windows 到 $dir（约 1-3 分钟）"
      $proc = Start-Process -FilePath $exe -ArgumentList ($common + @('/CURRENTUSER', "/DIR=`"$dir`"")) -Wait -PassThru
      if ($proc.ExitCode -ne 0) { throw "Git for Windows 安装失败（退出码 $($proc.ExitCode)）" }
    }
    $bash = Join-Path $dir 'bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash)) { throw "安装后未找到 $bash" }
    return $bash
  } finally {
    if ($lock) { $lock.Dispose() }
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
  }
}

# 优先使用官方 MSI 的安装位置（护栏只信任它），其次 PATH 中的 aws
function Find-AwsCli {
  $path = Join-Path (Get-ProgramFilesDir) 'Amazon\AWSCLIV2\aws.exe'
  if (Test-Path -LiteralPath $path) { return $path }
  $cmd = Get-Command aws.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return $cmd.Source }
  return $null
}

function Test-Admin {
  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# AWS CLI 安装包的签名者：Amazon Web Services, Inc.（EV 代码签名证书，由受信任的 CA 签发）
function Test-AmazonSignature([string]$Path) {
  $sig = Get-AuthenticodeSignature -FilePath $Path
  $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
  $ok = $sig.Status -eq 'Valid' -and $subject.StartsWith('CN="Amazon Web Services, Inc.", ') -and
    $subject.Contains(', O="Amazon Web Services, Inc.", ') -and $subject -match ', C=US(,|$)'
  if (-not $ok) { throw "AWS CLI 安装包签名校验失败（$($sig.Status)：$subject），已中止" }
}

# 安装 AWS CLI v2 官方 MSI：校验 Authenticode 签名，需要管理员（非管理员时弹出 UAC）
function Install-AwsCli {
  $tmp = New-TempDir
  $lock = $null
  try {
    $msi = Join-Path $tmp 'AWSCLIV2.msi'
    Write-Step "下载 AWS CLI v2（$AwsCliMsiUrl）"
    $lock = Open-VerifiedDownload $AwsCliMsiUrl $msi $null
    Test-AmazonSignature $msi
    $argList = @('/i', "`"$msi`"", '/qn', '/norestart')
    if (Test-Admin) {
      $proc = Start-Process -FilePath msiexec.exe -ArgumentList $argList -Wait -PassThru
    } else {
      Write-Step '安装 AWS CLI 需要管理员权限，请在弹出的 UAC 窗口中确认'
      $proc = Start-Process -FilePath msiexec.exe -ArgumentList $argList -Verb RunAs -Wait -PassThru
    }
    if ($proc.ExitCode -ne 0) { throw "AWS CLI 安装失败（msiexec 退出码 $($proc.ExitCode)）" }
  } finally {
    if ($lock) { $lock.Dispose() }
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
  }
  $aws = Find-AwsCli
  if (-not $aws) { throw '安装后未找到 aws.exe' }
  return $aws
}

function Confirm-Yes([string]$Question) {
  $answer = Read-Host "$Question [Y/n]"
  return ($answer -eq '' -or $answer -match '^[Yy]')
}

function Ensure-AwsCli {
  $aws = Find-AwsCli
  if (-not $aws) {
    Write-Warn '未找到 AWS CLI v2（用于登录 AWS、调用 Bedrock 与只读运维命令）'
    if ($InstallAwsCli -or ((Test-Interactive) -and (Confirm-Yes '是否现在安装 AWS CLI v2（官方 MSI）？'))) {
      $aws = Install-AwsCli
    } else {
      throw 'AWS CLI v2 为必需组件。请先安装（winget install -e --id Amazon.AWSCLI，或下载 https://awscli.amazonaws.com/AWSCLIV2.msi），或使用 -InstallAwsCli 重新运行'
    }
  }
  # 让本次安装（Git Bash）能找到 aws
  $awsDir = Split-Path $aws
  if (-not (($env:Path -split ';') -contains $awsDir)) { $env:Path = "$awsDir;$env:Path" }
  Write-Step "AWS CLI: $aws"
}

# 用户级 PATH（HKCU\Environment）：保持原有的 REG_EXPAND_SZ 类型与未展开的 %VAR%，并通知新开的终端
function Add-UserPath([string]$Dir) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  try {
    $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $entries = @($raw -split ';' | Where-Object { $_ -ne '' })
    if ($entries | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }) { return $false }
    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    if ($raw -ne '') { $kind = $key.GetValueKind('Path') }
    $key.SetValue('Path', ((@($Dir) + $entries) -join ';'), $kind)
  } finally {
    $key.Close()
  }
  # 设置并删除一个临时用户变量：.NET 会广播 WM_SETTINGCHANGE，新开的终端即可看到新的 PATH
  [Environment]::SetEnvironmentVariable('PI_CLI_ON_AWS_PATH_REFRESH', '1', 'User')
  [Environment]::SetEnvironmentVariable('PI_CLI_ON_AWS_PATH_REFRESH', $null, 'User')
  return $true
}

# 运行 Git Bash，退出码见 $LASTEXITCODE（不要把本函数的输出赋值给变量：那会让 bash 的 stdout 变成管道，失去 TTY）。
# Windows PowerShell 5.1 在输出被重定向时（如 SSM、CI）会把原生命令的 stderr 包装成错误记录，
# ErrorActionPreference=Stop 下会中断安装；此时把输出转为纯文本。交互终端下直接继承控制台。
function Invoke-Bash([string]$Bash, [string[]]$Arguments) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ([Console]::IsOutputRedirected -or [Console]::IsErrorRedirected) {
      & $Bash @Arguments 2>&1 | ForEach-Object { [Console]::Out.WriteLine([string]$_) }
    } else {
      & $Bash @Arguments
    }
  } finally {
    $ErrorActionPreference = $previous
  }
}

function ConvertTo-BashArgs {
  $list = New-Object System.Collections.Generic.List[string]
  if ($Region) { $list.Add('--region'); $list.Add($Region) }
  if ($NoProbe) { $list.Add('--no-probe') }
  if ($Model) { $list.Add('--model'); $list.Add($Model) }
  if ($Thinking) { $list.Add('--thinking'); $list.Add($Thinking) }
  if ($NoMcp) { $list.Add('--no-mcp') }
  if ($NoSkills) { $list.Add('--no-skills') }
  if ($AllModels) { $list.Add('--all-models') }
  foreach ($a in $list) { if ($a -notmatch '^[A-Za-z0-9._:/=-]+$') { throw "非法参数: $a" } }
  for ($i = 0; $i -lt $list.Count; $i += 1) {
    if ($list[$i] -notmatch '^--' -and $list[$i] -match '^-') { throw "参数值不能以 - 开头: $($list[$i])" }
  }
  return , $list.ToArray()
}

function Main {
  $arch = Get-HostArch
  Write-Step "Windows $([Environment]::OSVersion.Version) / $arch，用户 $env:USERNAME"
  $installSh = Join-Path $PSScriptRoot 'install.sh'
  if (-not (Test-Path -LiteralPath $installSh)) { throw "缺少 $installSh，请在完整的 pi-cli-on-aws 目录中运行" }
  $bashArgs = ConvertTo-BashArgs

  $bash = Find-GitBash $GitBash
  if ($bash) { Write-Step "使用 Git Bash: $bash" } else { $bash = Install-GitForWindows $arch }
  if (-not (Test-UnderDir $bash (Get-ProgramFilesDir))) { Write-Warn $UserGitNote }
  Ensure-AwsCli

  # 传给 install.sh：真实架构（Windows on ARM 上 x64 版 Git Bash 的 uname -m 为 x86_64）与 Git Bash 路径
  $env:PI_HOST_ARCH = if ($arch -eq 'Arm64') { 'arm64' } else { 'x86_64' }
  $env:PI_GIT_BASH = $bash
  $env:CHERE_INVOKING = '1'
  Write-Step '在 Git Bash 中运行 install.sh'
  Invoke-Bash $bash (@(($installSh -replace '\\', '/')) + $bashArgs)
  if ($LASTEXITCODE -ne 0) { throw "install.sh 执行失败（退出码 $LASTEXITCODE）" }

  $binDir = if ($env:PI_BIN_DIR) { $env:PI_BIN_DIR -replace '/', '\' } else { Join-Path $env:USERPROFILE '.local\bin' }
  if (Add-UserPath $binDir) { Write-Step "已把 $binDir 加入用户 PATH（新开的 PowerShell / 终端窗口生效）" }
  if (-not (($env:Path -split ';') -contains $binDir)) { $env:Path = "$binDir;$env:Path" }
  Write-Host ''
  Write-Host '在新的 PowerShell 窗口中运行: pi-bedrock-doctor（自检） / pi（开始使用）' -ForegroundColor Green
}

try {
  Main
} catch {
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
