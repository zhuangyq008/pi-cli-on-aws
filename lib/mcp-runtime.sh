# shellcheck shell=bash
# AWS MCP Server 运行时辅助函数（由 bin/aws-mcp-proxy 与测试 source）。

# AWS MCP Server 提供 endpoint 的区域（https://docs.aws.amazon.com/agent-toolkit/latest/userguide/getting-started-aws-mcp-server.html）
AWS_MCP_ENDPOINT_REGIONS="us-east-1 us-west-2 ap-southeast-1 ap-southeast-2 ap-northeast-1 eu-central-1 eu-west-1 eu-west-2"

# aws_mcp_endpoint_region OPS_REGION：为运维区域选择最近的 AWS MCP Server endpoint 区域。
# endpoint 区域只决定连接哪个 MCP Server；AWS API 的默认操作区域由 --metadata AWS_REGION 决定。
aws_mcp_endpoint_region() {
  local region="${1:-}"
  case " $AWS_MCP_ENDPOINT_REGIONS " in *" $region "*) [ -n "$region" ] && { printf '%s' "$region"; return 0; } ;; esac
  case "$region" in
    us-west-*) printf 'us-west-2' ;;
    eu-west-*) printf 'eu-west-1' ;;
    eu-* | me-* | il-* | af-*) printf 'eu-central-1' ;;
    ap-northeast-*) printf 'ap-northeast-1' ;;
    ap-southeast-4 | ap-southeast-6) printf 'ap-southeast-2' ;;
    ap-*) printf 'ap-southeast-1' ;;
    *) printf 'us-east-1' ;;
  esac
}
