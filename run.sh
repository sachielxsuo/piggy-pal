#!/usr/bin/env bash
# PiggyPal 真机调试（debug 模式）一键脚本。
#
# 作用：自动抓当前局域网 IP，走 whistle 代理转发到本地后端（18080）。
# 前置：本机已启动后端(go run ./cmd/server) + whistle，且 whistle 配规则：
#       <deploy.env 里的 PIGGYPAL_DOMAIN> http://127.0.0.1:18080
# 用法：./run.sh            # 默认 debug 真机调试
#       ./run.sh -d <设备ID> # 指定设备
set -euo pipefail

# 抓局域网 IP（优先 en0/WiFi，失败试 en1）
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
if [ -z "$IP" ]; then
  echo "❌ 未获取到局域网 IP（请确认已连 WiFi）" >&2
  exit 1
fi

# whistle 代理端口（可用环境变量覆盖，默认 8017）
PROXY_PORT="${WHISTLE_PORT:-8017}"

cd "$(dirname "$0")/client"

# API 地址来自仓库根的 deploy.env（不入库，模板见 deploy.env.example）
if [ -f ../deploy.env ]; then
  while IFS='=' read -r key val; do
    case "$key" in ''|'#'*) continue ;; esac
    case "$key" in
      PIGGYPAL_SERVER|PIGGYPAL_USER|PIGGYPAL_DOMAIN|PIGGYPAL_REMOTE_DIR|PIGGYPAL_API_BASE)
        val=$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')
        eval "if [ -z \"\${$key:-}\" ]; then export $key=\"\$val\"; fi"
        ;;
    esac
  done < ../deploy.env
fi

# 从 server/.env 读取全站共享 token，注入客户端（服务端未配置时为空）
API_TOKEN=$(grep -E '^API_TOKEN=' ../server/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)
if [ -z "$API_TOKEN" ]; then
  echo "⚠️  未从 server/.env 读到 API_TOKEN；若服务端已开启校验，请求会返回 401" >&2
fi

echo "==> 真机调试：whistle 代理 $IP:$PROXY_PORT → 本地后端 18080"
# 清除代理环境变量：否则 flutter run 连 VM Service 的本地 WebSocket 会被代理干扰（Invalid WebSocket upgrade request）
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy \
  flutter run --dart-define=WHISTLE_PROXY="$IP:$PROXY_PORT" --dart-define=API_TOKEN="$API_TOKEN" \
    --dart-define=API_BASE_URL="${PIGGYPAL_API_BASE:-https://${PIGGYPAL_DOMAIN:-piggy.example.com}}" "$@"
