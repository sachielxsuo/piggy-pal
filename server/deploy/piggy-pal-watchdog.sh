#!/bin/sh
# PiggyPal 功能级巡检（每 10 分钟由 piggy-pal-watchdog.timer 触发）
#
# 为什么需要它：/healthz 只返回固定 ok，TTS 额度用尽、LLM 欠费、ASR 挂掉
# 这类「服务活着但功能坏了」的问题它一律发现不了（2026-10-27 佩奇静音就是这种）。
# 这里改为读服务日志 + 检查备份/磁盘，命中就推企业微信群机器人。
#
# 告警配置：/opt/piggy-pal/alert.env（600，不进 git）
#   WECOM_WEBHOOK=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxx
# 没配 webhook 时只写 $DATA_DIR/watchdog/alerts.log，不会报错。
#
# 用法：
#   ./piggy-pal-watchdog.sh              # 正常巡检
#   ./piggy-pal-watchdog.sh --test       # 立刻推一条测试消息，验证 webhook
#   DRY_RUN=1 ./piggy-pal-watchdog.sh    # 只打印，不推送
set -eu

DATA_DIR=${DATA_DIR:-/opt/piggy-pal/data}
LOG_FILE=${LOG_FILE:-/var/log/piggy-pal/server.log}
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:18080/healthz}
ALERT_ENV=${ALERT_ENV:-/opt/piggy-pal/alert.env}
STATE_DIR=${STATE_DIR:-$DATA_DIR/watchdog}
# 同一个问题 6 小时内只提醒一次，免得刷屏
SUPPRESS_SEC=${SUPPRESS_SEC:-21600}
# 只看最近这么久的日志
WINDOW_MIN=${WINDOW_MIN:-15}
DISK_LIMIT=${DISK_LIMIT:-85}
DRY_RUN=${DRY_RUN:-0}

# NAS 异地备份：/opt/piggy-pal/.nas-backup-enabled 存在表示已配置 NAS 拉取；
# 心跳文件由 rrsync-heartbeat 每次连接时写入，超过 NAS_MAX_HOURS 没更新就告警
NAS_ENABLED_FILE=${NAS_ENABLED_FILE:-/opt/piggy-pal/.nas-backup-enabled}
NAS_HEARTBEAT=${NAS_HEARTBEAT:-/var/lib/piggy-pal-nas/last-pull}
NAS_MAX_HOURS=${NAS_MAX_HOURS:-48}

# 发布 / 维护窗口：部署脚本会在切换版本前 touch 这个文件，巡检整轮跳过，
# 避免「停服换二进制」被当成故障推告警（2026-10-28 20:30 那次误报就是这么来的）。
# 超过 MAINT_MAX_MIN 还没删就按残留处理，继续巡检——不能因为一次误操作把告警永久静音。
MAINT_FILE=${MAINT_FILE:-$STATE_DIR/maintenance}
MAINT_MAX_MIN=${MAINT_MAX_MIN:-120}

WECOM_WEBHOOK=${WECOM_WEBHOOK:-}
if [ -r "$ALERT_ENV" ]; then
    # shellcheck disable=SC1090
    . "$ALERT_ENV" 2>/dev/null || true
fi

mkdir -p "$STATE_DIR"
umask 077

now=$(date +%s)

# 维护窗口：部署脚本正在换版本，任何检查结果都不代表线上真实状态。
# 只跳过、不告警；标记过期（默认 2 小时）说明部署脚本异常退出，恢复巡检。
if [ -f "$MAINT_FILE" ]; then
    # GNU stat（Linux）优先，BSD stat（macOS）兜底，方便本地验证
    mtime=$(stat -c %Y "$MAINT_FILE" 2>/dev/null || stat -f %m "$MAINT_FILE" 2>/dev/null || true)
    if [ -z "$mtime" ]; then
        # 读不到时间就按「维护中」处理，宁可少报也不要误报
        echo "· 维护中（标记时间不可读），跳过本轮巡检"
        exit 0
    fi
    age_min=$(( (now - mtime) / 60 ))
    if [ "$age_min" -lt "$MAINT_MAX_MIN" ]; then
        echo "· 维护中（${age_min} 分钟），跳过本轮巡检"
        exit 0
    fi
    echo "⚠️  维护标记已 ${age_min} 分钟未清理，按残留处理并恢复巡检"
    rm -f "$MAINT_FILE"
fi

# 把任意文本压成一行、去掉会破坏 JSON 的字符
sanitize() {
    tr -d '\r' | tr '\n\t' '  ' | sed "s/\"/'/g" | cut -c1-400
}

# send <去重键> <标题> <详情>
send() {
    key=$1
    title=$2
    detail=$3
    stamp_file="$STATE_DIR/last-$key"
    if [ -f "$stamp_file" ]; then
        last=$(cat "$stamp_file" 2>/dev/null || echo 0)
        if [ $((now - last)) -lt "$SUPPRESS_SEC" ]; then
            echo "· 已抑制（$(( (SUPPRESS_SEC - (now - last)) / 60 )) 分钟内重复）：$title"
            return 0
        fi
    fi

    echo "⚠️  $title — $detail"
    echo "$now" > "$stamp_file"

    # 本地留档，永远写
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$title" "$detail" >> "$STATE_DIR/alerts.log"

    if [ "$DRY_RUN" = "1" ]; then
        echo "  (dry-run，未推送)"
        return 0
    fi
    if [ -z "$WECOM_WEBHOOK" ]; then
        echo "  (未配置 WECOM_WEBHOOK，只写本地日志)"
        return 0
    fi

    content="**PiggyPal 巡检**\\n> $title\\n> $detail"
    payload=$(printf '{"msgtype":"markdown","markdown":{"content":"%s"}}' "$content")
    if curl -fsS --max-time 8 -H 'Content-Type: application/json' \
        -d "$payload" "$WECOM_WEBHOOK" >/dev/null 2>&1; then
        echo "  ✓ 已推送到企业微信"
    else
        echo "  ✗ 推送失败（网络或 webhook 无效）" >&2
    fi
}

if [ "${1:-}" = "--test" ]; then
    # 测试消息绕过去重
    rm -f "$STATE_DIR/last-selftest"
    WECOM_WEBHOOK="$WECOM_WEBHOOK" send selftest "巡检测试" "如果你收到这条，说明告警链路是通的 $(date '+%m-%d %H:%M')"
    exit 0
fi

echo "== PiggyPal 巡检 $(date '+%Y-%m-%d %H:%M:%S') =="

# 1) 进程 / 端口级别：探活不通
if ! curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
    send health "服务探活失败" "$HEALTH_URL 请求失败，进程或端口可能已挂"
else
    echo "· healthz ok"
fi

# 2) 功能级：最近窗口内的错误与额度问题
since=$(date -d "-$WINDOW_MIN min" '+%Y-%m-%dT%H:%M' 2>/dev/null || date -v-"${WINDOW_MIN}"M '+%Y-%m-%dT%H:%M')
recent=""
if [ -f "$LOG_FILE" ]; then
    recent=$(awk -v since="$since" '
        { i = index($0, "time="); if (i) { t = substr($0, i + 5, 16); if (t >= since) print } }
    ' "$LOG_FILE" | tail -n 500)
fi

if [ -n "$recent" ]; then
    quota_line=$(printf '%s\n' "$recent" | grep -E '额度已用尽|改用备用音色|PkgExhausted' | tail -n 1 || true)
    if [ -n "$quota_line" ]; then
        send tts_quota "TTS 额度异常，已切备用音色" "$(printf '%s' "$quota_line" | sanitize)"
    else
        echo "· TTS 额度正常"
    fi

    # TTS 单次文本超长：不是服务故障（那一段会静音，文字仍在），单独一条，
    # 避免混进「服务端报错」让人误以为服务挂了。兼容旧版本日志里的 TextTooLong 错误码。
    # 只数 level=ERROR 的那条：调用方还会打一条 WARN（也带着同一个错误码），别重复计数。
    too_long_n=$(printf '%s\n' "$recent" | grep 'level=ERROR' | grep -cE '文本超出长度限制|TextTooLong' || true)
    if [ "${too_long_n:-0}" -gt 0 ]; then
        too_long_line=$(printf '%s\n' "$recent" | grep 'level=ERROR' | grep -E '文本超出长度限制|TextTooLong' | tail -n 1 || true)
        send tts_too_long "TTS 文本超出长度限制（该段静音）" "窗口内 ${too_long_n} 次；最近一条：$(printf '%s' "$too_long_line" | sanitize)"
    else
        echo "· TTS 长度正常"
    fi

    err_line=$(printf '%s\n' "$recent" | grep 'level=ERROR' | grep -vE '额度已用尽|PkgExhausted|文本超出长度限制|TextTooLong' | tail -n 1 || true)
    if [ -n "$err_line" ]; then
        send server_error "服务端报错" "$(printf '%s' "$err_line" | sanitize)"
    else
        echo "· 窗口内无其它 ERROR"
    fi
else
    echo "· 日志窗口为空或文件不存在"
fi

# 3) 每日备份：04:00 之后当天必须有一份
hour=$(date +%H)
if [ "$hour" -ge 4 ]; then
    today=$(date +%Y%m%d)
    if ! ls "$DATA_DIR"/backups/app-"$today"-*.db.gz >/dev/null 2>&1; then
        send backup_missing "今天的数据库备份没生成" "$DATA_DIR/backups 里没有 app-$today-*.db.gz"
    else
        echo "· 今日备份已生成"
    fi
fi

# 4) 磁盘
use=$(df -P / | awk 'NR==2 { gsub("%", "", $5); print $5 }')
if [ "${use:-0}" -ge "$DISK_LIMIT" ]; then
    send disk "磁盘快满了" "根分区已用 ${use}%（阈值 ${DISK_LIMIT}%）"
else
    echo "· 磁盘 ${use}%"
fi

# 5) NAS 异地备份心跳：配了 NAS 拉取的话，48 小时内必须来过一次
if [ -f "$NAS_ENABLED_FILE" ]; then
    last_pull=0
    [ -f "$NAS_HEARTBEAT" ] && last_pull=$(cat "$NAS_HEARTBEAT" 2>/dev/null || echo 0)
    age_h=$(( (now - last_pull) / 3600 ))
    if [ "${last_pull:-0}" -le 0 ]; then
        send nas_stale "NAS 备份从未成功拉取过" "已配置 NAS 备份，但 $NAS_HEARTBEAT 不存在"
    elif [ "$age_h" -ge "$NAS_MAX_HOURS" ]; then
        send nas_stale "NAS 备份已 $age_h 小时没来拉取" "NAS 可能断电/离线，或任务计划失败（阈值 ${NAS_MAX_HOURS} 小时）"
    else
        echo "· NAS 备份 ${age_h} 小时前来过"
    fi
fi

echo "== 巡检结束 =="
