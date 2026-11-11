<#
  Windows 端到端测试（由 tests/windows/ec2-harness.sh 通过 SSM 在临时 Windows Server EC2 上执行，身份为 SYSTEM）：
    1. 干净环境（无 Git、无 AWS CLI）下运行 install.ps1：安装 Git for Windows、AWS CLI、pi 等
    2. 凭证引导：禁用 IMDS 使安装器检测不到凭证，选择"Access Key / Secret Key"，填入实例角色的临时凭证（ASIA + Session Token）
    3. 检查 .cmd shim、用户 PATH、pi 配置、pi-bedrock-doctor 全部通过
    4. e2e-pi.sh：bash 工具凭证模型、严格只读 aws、凭证读取 / 写操作在非交互模式下被拒绝、AWS MCP 只读调用
    5. Windows 原生运行护栏的 Windows 路径单元测试
    6. uninstall.ps1 后检查清理结果
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Src = Split-Path (Split-Path $PSScriptRoot)
$script:Fails = 0
function Check([string]$Name, [bool]$Ok) {
  if ($Ok) { Write-Output "  [PASS] $Name" } else { Write-Output "  [FAIL] $Name"; $script:Fails++ }
}
function Step([string]$Name) { Write-Output ''; Write-Output "== $Name" }
function Invoke-Native([string]$File, [string[]]$Arguments, [string]$Log) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $File @Arguments 2>&1 | ForEach-Object { [string]$_ } | Tee-Object -FilePath $Log | Out-Null } finally { $ErrorActionPreference = $previous }
  return $LASTEXITCODE
}

# ---- 0. 实例角色的临时凭证（IMDSv2）------------------------------------------
$token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' }
$h = @{ 'X-aws-ec2-metadata-token' = $token }
$role = (Invoke-RestMethod -Uri 'http://169.254.169.254/latest/meta-data/iam/security-credentials/' -Headers $h).Trim()
$cred = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/iam/security-credentials/$role" -Headers $h
$doc = Invoke-RestMethod -Uri 'http://169.254.169.254/latest/dynamic/instance-identity/document' -Headers $h
$Account = $doc.accountId
Write-Output "account=$Account role=$role user=$env:USERNAME profile=$env:USERPROFILE"

# 干净的用户环境：清除上次运行的残留（含按当前用户安装的 Git，使安装器走"安装到 Program Files"的路径）
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $env:USERPROFILE '.aws'), (Join-Path $env:USERPROFILE '.pi'), (Join-Path $env:USERPROFILE '.local')
foreach ($d in @((Join-Path $env:LOCALAPPDATA 'Programs\Git'), (Join-Path $env:LOCALAPPDATA 'pi-probe\git'))) {
  $u = Join-Path $d 'unins000.exe'
  if (Test-Path $u) { Start-Process -FilePath $u -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait }
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $d
}

# ---- 1. install.ps1 + 凭证引导（AK/SK/Session Token）----------------------------
Step '1. install.ps1（Git for Windows / AWS CLI / pi / MCP / skills）+ 凭证引导'
$answers = Join-Path $env:TEMP 'pi-wizard-answers.txt'
# 选项 3（Access Key）→ Region → Access Key ID → Secret Access Key → Session Token
# Region 用 us-west-2：测试账号 default VPC 中 us-east-1 的 STS 接口终端节点（私有 DNS）不接受任何入站流量
$WizardRegion = 'us-west-2'
[IO.File]::WriteAllText($answers, "3`n$WizardRegion`n$($cred.AccessKeyId)`n$($cred.SecretAccessKey)`n$($cred.Token)`n")
$env:PI_BEDROCK_WIZARD_INPUT = $answers
$env:AWS_EC2_METADATA_DISABLED = 'true'
$installLog = Join-Path $env:TEMP 'pi-install.log'
$sw = [Diagnostics.Stopwatch]::StartNew()
$code = Invoke-Native 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Src 'install.ps1'), '-InstallAwsCli') $installLog
Remove-Item -Force $answers
Remove-Item Env:\PI_BEDROCK_WIZARD_INPUT
Write-Output "install.ps1 exit=$code（$([int]$sw.Elapsed.TotalSeconds) 秒）"
Get-Content $installLog | Select-Object -Last 40
Check 'install.ps1 成功' ($code -eq 0)

$bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
$binDir = Join-Path $env:USERPROFILE '.local\bin'
$piHome = Join-Path $env:USERPROFILE '.local\share\pi-bedrock'
$agentDir = Join-Path $env:USERPROFILE '.pi\agent'
Check 'Git for Windows 安装到 Program Files（管理员）' (Test-Path $bash)
Check '未提示"Git 位于当前用户可写目录"' (-not ((Get-Content -Raw $installLog).Contains('当前用户可写的目录')))
Check 'AWS CLI v2 已安装' (Test-Path (Join-Path $env:ProgramFiles 'Amazon\AWSCLIV2\aws.exe'))
Check '凭证引导写入 [pi-bedrock] profile' ((Get-Content -Raw (Join-Path $env:USERPROFILE '.aws\credentials')) -match '\[pi-bedrock\]')
Check 'env 文件记录 PI_AWS_PROFILE=pi-bedrock' ((Get-Content -Raw (Join-Path $piHome 'env')) -match 'PI_AWS_PROFILE=pi-bedrock')
Check '安装日志中没有 Secret Access Key' (-not ((Get-Content -Raw $installLog).Contains($cred.SecretAccessKey)))
foreach ($f in 'pi.cmd', 'pi-bedrock-doctor.cmd', 'pi-bedrock-login.cmd') { Check "生成 $f" (Test-Path (Join-Path $binDir $f)) }
$userPath = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
Check '用户 PATH 包含 %USERPROFILE%\.local\bin' (($userPath -split ';') -contains $binDir)
$settings = Get-Content -Raw (Join-Path $agentDir 'settings.json') | ConvertFrom-Json
Check 'settings.json 默认模型为 Kimi K3.1' ($settings.defaultModel -eq 'global.moonshotai.kimi-k3.1')
Check 'settings.json shellPath 指向 Git Bash' ($settings.shellPath -like '*\bin\bash.exe')
Check 'settings.json selfUpdateCommand 使用 node.exe + npm-cli.js' (($settings.selfUpdateCommand -join ' ') -like '*node.exe*npm-cli.js install -g*')
$mcp = (Get-Content -Raw (Join-Path $agentDir 'mcp.json') | ConvertFrom-Json).mcpServers.'aws-mcp'
Check 'mcp.json：command=bash.exe、args=[aws-mcp-proxy]' (($mcp.command -like '*bash.exe') -and ($mcp.args[0] -like '*/bin/aws-mcp-proxy'))
Check 'mcp-proxy-for-aws-cli.exe 已安装（venv\Scripts）' (Test-Path (Join-Path $piHome 'uv\venv\Scripts\mcp-proxy-for-aws-cli.exe'))

# ---- 2. 通过 .cmd shim 运行 ------------------------------------------------------
Step '2. pi.cmd / pi-bedrock-doctor.cmd'
$env:Path = "$binDir;$env:ProgramFiles\Git\cmd;$env:ProgramFiles\Amazon\AWSCLIV2;$env:Path"
$nul = Join-Path $env:TEMP 'pi-empty-stdin.txt'
[IO.File]::WriteAllText($nul, '')
$out = (& cmd.exe /d /c "`"$binDir\pi.cmd`" --version < `"$nul`"" 2>&1 | Out-String).Trim()
Check "pi.cmd --version = $out" ($out -match '^\d+\.\d+\.\d+')
$out = (& cmd.exe /d /c "`"$binDir\pi.cmd`" -p --no-session `"Reply with exactly: PI_WIN_SHIM_OK`" < `"$nul`"" 2>&1 | Out-String)
Check 'pi.cmd -p（参数含空格）调用 Bedrock 成功' ($out -match 'PI_WIN_SHIM_OK')
$doctorLog = Join-Path $env:TEMP 'pi-doctor.log'
$code = Invoke-Native 'cmd.exe' @('/d', '/c', "`"$binDir\pi-bedrock-doctor.cmd`" < `"$nul`"") $doctorLog
Get-Content $doctorLog
Check 'pi-bedrock-doctor 全部通过' ($code -eq 0)

# ---- 3. 护栏与 MCP（在 Git Bash 中运行）------------------------------------------
Step '3. bash 工具凭证模型 / 护栏 / AWS MCP'
$piLog = Join-Path $env:TEMP 'pi-e2e-pi.log'
$code = Invoke-Native $bash @(((Join-Path $PSScriptRoot 'e2e-pi.sh') -replace '\\', '/'), $Account, $cred.AccessKeyId, $doc.instanceId) $piLog
Get-Content $piLog
Check 'e2e-pi.sh 全部通过' ($code -eq 0)

# ---- 4. 护栏 Windows 路径单元测试（Windows 原生 node）-----------------------------
Step '4. 护栏 Windows 路径单元测试（原生 win32）'
$node = Get-ChildItem (Join-Path $piHome 'node') -Filter node.exe -Recurse | Select-Object -First 1
$testLog = Join-Path $env:TEMP 'pi-guard-test.log'
$code = Invoke-Native $node.FullName @('--experimental-strip-types', '--no-warnings', '--test', (Join-Path $Src 'tests\guard\windows.test.ts'), (Join-Path $Src 'tests\merge.test.mjs')) $testLog
Get-Content $testLog | Select-String -Pattern '^(not )?ok|^# (pass|fail)'
Check '护栏 / merge 单元测试在 Windows 上通过' ($code -eq 0)

# ---- 5. 卸载 ---------------------------------------------------------------------
Step '5. uninstall.ps1'
$uninstallLog = Join-Path $env:TEMP 'pi-uninstall.log'
$code = Invoke-Native 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $piHome 'uninstall.ps1')) $uninstallLog
Get-Content $uninstallLog | Select-Object -Last 15
Check 'uninstall.ps1 成功' ($code -eq 0)
Check '安装目录已删除' (-not (Test-Path $piHome))
Check '.cmd shim 已删除' (-not (Test-Path (Join-Path $binDir 'pi.cmd')))
$userPath = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
Check '用户 PATH 已移除 .local\bin' (-not (($userPath -split ';') -contains $binDir))
$settings = Get-Content -Raw (Join-Path $agentDir 'settings.json') | ConvertFrom-Json
Check 'settings.json 已回滚（defaultModel / shellPath）' ((-not ($settings.PSObject.Properties.Name -contains 'defaultModel')) -and (-not ($settings.PSObject.Properties.Name -contains 'shellPath')))
Check 'mcp.json 已移除 aws-mcp' (-not ((Get-Content -Raw (Join-Path $agentDir 'mcp.json')) -match 'aws-mcp'))
Check '~/.aws 凭证保留' (Test-Path (Join-Path $env:USERPROFILE '.aws\credentials'))

Write-Output ''
Write-Output "WINDOWS_E2E_FAILS=$script:Fails"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $env:USERPROFILE '.aws')
if ($script:Fails -gt 0) { exit 1 }
