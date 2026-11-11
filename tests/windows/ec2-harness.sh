#!/usr/bin/env bash
# 在 AWS 账号中临时启动 Windows Server EC2，通过 SSM 远程执行 Windows 版安装与端到端测试。
#   up    创建临时 IAM 角色 / 实例配置文件并启动实例（无入站端口，仅 SSM）
#   run   上传当前代码到 S3（预签名 URL 下载），在实例上执行 tests/windows/e2e.ps1，输出写入 S3
#   down  终止实例并删除临时 IAM 资源与 S3 测试文件
# 需要：ec2 / iam / ssm / s3 权限。会产生少量费用（t3.large Windows 约 0.1 美元/小时）。
# 可选环境变量：AWS_REGION（默认 us-east-1）、PI_WIN_S3_PREFIX（默认 s3://agentcore-enginez-ue1-poc/pi-cli-on-aws/win-e2e）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
NAME=pi-cli-win-e2e
ROLE="${NAME}-role"
SG_NAME="${NAME}-sg"
S3_PREFIX="${PI_WIN_S3_PREFIX:-s3://agentcore-enginez-ue1-poc/pi-cli-on-aws/win-e2e}"
STATE="$REPO_ROOT/.test-tmp/win-e2e.state"
mkdir -p "$(dirname "$STATE")"

# 专用安全组：无入站；出站只放行 HTTPS（SSM、S3、Bedrock、nodejs.org、GitHub、PyPI）。
# 不复用 default 安全组：其出站规则可能被组织策略收紧
ensure_sg() {
  local vpc="$1" sg
  sg="$(aws ec2 describe-security-groups --region "$REGION" --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$vpc" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [ -z "$sg" ] || [ "$sg" = None ]; then
    sg="$(aws ec2 create-security-group --region "$REGION" --group-name "$SG_NAME" --vpc-id "$vpc" \
      --description "pi-cli-on-aws Windows E2E (egress 443 only)" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=purpose,Value=pi-cli-win-e2e}]" --query GroupId --output text)"
    aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$sg" \
      --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true
    aws ec2 authorize-security-group-egress --region "$REGION" --group-id "$sg" \
      --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null
  fi
  printf '%s' "$sg"
}

# 实例同时加入 default 安全组：VPC 内带私有 DNS 的接口终端节点（如 sts）通常只允许 default 安全组访问
# （若 default 安全组没有自引用入站规则，这些终端节点对任何实例都不可达，e2e.ps1 因此使用 us-west-2 作为凭证区域）
instance_sgs() {
  local vpc="$1" default
  default="$(aws ec2 describe-security-groups --region "$REGION" --filters Name=group-name,Values=default Name=vpc-id,Values="$vpc" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  printf '%s %s' "$(ensure_sg "$vpc")" "$default"
}

wait_ssm() {
  local iid="$1"
  echo "等待 SSM 在线（Windows 首次启动约 5-15 分钟）..."
  for _ in $(seq 1 80); do
    if [ "$(aws ssm describe-instance-information --region "$REGION" --filters Key=InstanceIds,Values="$iid" --query 'length(InstanceInformationList)' --output text)" = 1 ]; then
      echo "SSM 已在线: $iid"; return 0
    fi
    sleep 15
  done
  echo "等待 SSM 超时" >&2; return 1
}

bucket_arn() { local b="${S3_PREFIX#s3://}"; printf 'arn:aws:s3:::%s/*' "$b"; }

up() {
  local account trust policy ami subnet iid vpc sg
  account="$(aws sts get-caller-identity --query Account --output text)"
  trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  policy=$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
  "Resource":["arn:aws:bedrock:*:${account}:inference-profile/*","arn:aws:bedrock:*::foundation-model/*"]},
 {"Effect":"Allow","Action":["bedrock:ListInferenceProfiles","bedrock:ListFoundationModels","bedrock:GetFoundationModelAvailability","bedrock:GetInferenceProfile"],"Resource":"*"},
 {"Effect":"Allow","Action":["ec2:DescribeAvailabilityZones","cloudwatch:DescribeAlarms","cloudwatch:ListMetrics","cloudwatch:GetMetricData","cloudwatch:GetMetricStatistics"],"Resource":"*"},
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject"],"Resource":"$(bucket_arn)"}
]}
EOF
)
  if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$trust" --tags Key=purpose,Value=pi-cli-win-e2e >/dev/null
    aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
    echo "已创建 IAM 角色 $ROLE，等待传播..."
    sleep 15
  fi
  aws iam put-role-policy --role-name "$ROLE" --policy-name "${NAME}-test" --policy-document "$policy"
  ami="$(aws ssm get-parameter --region "$REGION" --name /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base --query Parameter.Value --output text)"
  subnet="$(aws ec2 describe-subnets --region "$REGION" --filters Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)"
  vpc="$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$subnet" --query 'Subnets[0].VpcId' --output text)"
  sg="$(instance_sgs "$vpc")"
  # shellcheck disable=SC2086 # $sg 为两个安全组 ID，需要分词
  iid="$(aws ec2 run-instances --region "$REGION" --image-id "$ami" --instance-type t3.large --subnet-id "$subnet" --security-group-ids $sg \
    --associate-public-ip-address --iam-instance-profile Name="$ROLE" \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=60,VolumeType=gp3,DeleteOnTermination=true}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=purpose,Value=pi-cli-win-e2e}]" \
    --query 'Instances[0].InstanceId' --output text)"
  echo "$iid" >"$STATE"
  echo "实例 $iid 启动中"
  wait_ssm "$iid"
}

# 为已启动的实例换用专用安全组（例如实例创建时使用了出站受限的 default 安全组）
fix_sg() {
  local iid vpc
  iid="$(cat "$STATE")"
  vpc="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$iid" --query 'Reservations[0].Instances[0].VpcId' --output text)"
  # shellcheck disable=SC2046 # 两个安全组 ID 需要分词
  aws ec2 modify-instance-attribute --region "$REGION" --instance-id "$iid" --groups $(instance_sgs "$vpc")
  wait_ssm "$iid"
}

run() {
  local iid zip url cid status script
  iid="$(cat "$STATE")"
  zip="$REPO_ROOT/.test-tmp/pi-cli-on-aws.zip"
  rm -f "$zip"
  # 包含尚未提交的新文件（-o），但排除可能含敏感信息的文件
  (cd "$REPO_ROOT" && git ls-files -co --exclude-standard | grep -v '^node_modules/' |
    grep -Eiv '(^|/)(\.env(\.[^/]*)?|[^/]*\.(pem|key|p12|pfx|secret)|credentials)$' | zip -q "$zip" -@)
  # 先写入文件再检查（pipefail 下 grep -q 提前退出会让 unzip 收到 SIGPIPE）
  unzip -Z1 "$zip" >"$zip.list"
  if ! grep -qx lib/credentials.sh "$zip.list" || ! grep -qx install.ps1 "$zip.list"; then
    echo "打包内容不完整" >&2
    return 1
  fi
  aws s3 cp --only-show-errors "$zip" "$S3_PREFIX/src.zip"
  url="$(aws s3 presign "$S3_PREFIX/src.zip" --expires-in 3600)"
  script="${1:-tests/windows/e2e.ps1}"
  cid="$(aws ssm send-command --region "$REGION" --instance-ids "$iid" --document-name AWS-RunPowerShellScript \
    --timeout-seconds 3600 --output-s3-bucket-name "$(printf '%s' "${S3_PREFIX#s3://}" | cut -d/ -f1)" \
    --output-s3-key-prefix "$(printf '%s' "${S3_PREFIX#s3://}" | cut -d/ -f2-)/ssm" \
    --parameters "{\"executionTimeout\":[\"3600\"],\"commands\":[
      \"\$ErrorActionPreference='Stop'\",
      \"Remove-Item -Recurse -Force C:\\\\pi-src -ErrorAction SilentlyContinue\",
      \"Invoke-WebRequest -UseBasicParsing -Uri '$url' -OutFile C:\\\\pi-src.zip\",
      \"Expand-Archive C:\\\\pi-src.zip C:\\\\pi-src -Force\",
      \"powershell -NoProfile -ExecutionPolicy Bypass -File C:\\\\pi-src\\\\$(printf '%s' "$script" | sed 's#/#\\\\\\\\#g')\"
    ]}" --query Command.CommandId --output text)"
  echo "SSM 命令 $cid 执行中..."
  while :; do
    status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$iid" --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in Pending | InProgress | Delayed) sleep 20 ;; *) break ;; esac
  done
  echo "状态: $status"
  aws s3 cp --only-show-errors --recursive "$S3_PREFIX/ssm/$cid/" "$REPO_ROOT/.test-tmp/ssm-$cid/" || true
  find "$REPO_ROOT/.test-tmp/ssm-$cid" -name stdout -exec cat {} \; 2>/dev/null | tail -n 200
  find "$REPO_ROOT/.test-tmp/ssm-$cid" -name stderr -exec cat {} \; 2>/dev/null | tail -n 40
  [ "$status" = Success ] || return 1
  # PowerShell 解析错误等情况下 SSM 状态仍可能是 Success：E2E 脚本必须输出通过标记
  if [ "$script" = tests/windows/e2e.ps1 ]; then
    find "$REPO_ROOT/.test-tmp/ssm-$cid" -name stdout -exec cat {} \; 2>/dev/null | grep -q '^WINDOWS_E2E_FAILS=0' ||
      { echo "未找到 WINDOWS_E2E_FAILS=0，判定为失败" >&2; return 1; }
  fi
}

down() {
  local iid
  if [ -f "$STATE" ]; then
    iid="$(cat "$STATE")"
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$iid" >/dev/null && echo "已终止 $iid"
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$iid" || true
    rm -f "$STATE"
  fi
  aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$ROLE" 2>/dev/null || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name "${NAME}-test" 2>/dev/null || true
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "已删除 IAM 角色 $ROLE" || true
  aws s3 rm --only-show-errors --recursive "$S3_PREFIX/" || true
  local sg
  for sg in $(aws ec2 describe-security-groups --region "$REGION" --filters Name=group-name,Values="$SG_NAME" --query 'SecurityGroups[].GroupId' --output text 2>/dev/null); do
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" && echo "已删除安全组 $sg" || true
  done
}

case "${1:-}" in
  up) up ;;
  fix-sg) fix_sg ;;
  run) shift; run "$@" ;;
  down) down ;;
  *) echo "用法: $0 up|fix-sg|run [script]|down" >&2; exit 64 ;;
esac
