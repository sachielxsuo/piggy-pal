#!/bin/sh
# NAS 备份心跳包装器
#
# 为什么需要它：NAS 主动来拉备份，VPS 上不会留下任何「拉取过」的痕迹，
# 所以 NAS 断电 / 任务计划失效时会静默停摆，watchdog 看不出来。
# 这里在 rrsync 之前先写一个时间戳，watchdog 检查它是否超过 48 小时没更新。
#
# 安装位置：/usr/local/bin/rrsync-heartbeat
# authorized_keys 里的写法：
#   command="/usr/local/bin/rrsync-heartbeat -ro /opt/piggy-pal/data/backups",...
#
# 时间戳目录 /var/lib/piggy-pal-nas 属主 backup:backup、权限 750，
# 监控脚本（piggy-pal 用户，同组）只读，NAS 只能写这一个文件。
set -u

HEARTBEAT_DIR=${HEARTBEAT_DIR:-/var/lib/piggy-pal-nas}
HEARTBEAT_FILE="$HEARTBEAT_DIR/last-pull"

# 写失败不影响拉取本身（比如目录被误删），只是心跳会缺一条
if [ -w "$HEARTBEAT_DIR" ]; then
    date +%s > "$HEARTBEAT_FILE" 2>/dev/null || true
fi

exec /usr/local/bin/rrsync "$@"
