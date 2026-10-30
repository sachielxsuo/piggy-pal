#!/usr/bin/env bash
# PiggyPal 后端启动脚本。
#
# 用法：
#   ./server.sh          # 前台启动（Ctrl+C 停止），监听 18080，读 server/.env
#   ./server.sh stop     # 停止占用 18080 端口的后台实例
set -euo pipefail

cd "$(dirname "$0")/server"

if [ "${1:-}" = "stop" ]; then
  if lsof -ti:18080 >/dev/null 2>&1; then
    lsof -ti:18080 | xargs kill
    echo "✅ 已停止后端（端口 18080）"
  else
    echo "后端未在运行"
  fi
  exit 0
fi

echo "==> 启动后端 :18080（Ctrl+C 停止），日志同时写终端 + logs/server.log"
mkdir -p logs
go run ./cmd/server 2>&1 | tee -a logs/server.log
