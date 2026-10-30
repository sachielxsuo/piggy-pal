#!/bin/sh
# PiggyPal 每日数据库备份
#
# - 用 sqlite3 的 .backup 做在线热备（不停服，也不会拷到写了一半的页）
# - gzip 压缩后放在 data/backups/，默认保留 14 天
# - 备份完跑一次 integrity_check，坏备份不留
#
# 由 piggy-pal-backup.timer 每天凌晨 03:30 触发（见同名 .service / .timer）。
set -eu

DATA_DIR="${DATA_DIR:-/opt/piggy-pal/data}"
DB="$DATA_DIR/app.db"
OUT_DIR="$DATA_DIR/backups"
KEEP_DAYS="${KEEP_DAYS:-14}"

if [ ! -f "$DB" ]; then
    echo "❌ 数据库不存在：$DB"
    exit 1
fi

# 备份里有宝宝档案和聊天记录，别让同机其他用户读到。
# 用 027 而不是 077：backup 用户（NAS 拉取用）靠 piggy-pal 组读，其他人仍然读不到
umask 027
mkdir -p "$OUT_DIR"

stamp=$(date +%Y%m%d-%H%M%S)
tmp="$OUT_DIR/app-$stamp.db"

# 在线备份：SQLite 自己处理锁和事务，不需要停服务
sqlite3 "$DB" ".backup '$tmp'"

check=$(sqlite3 "$tmp" 'PRAGMA integrity_check;')
if [ "$check" != "ok" ]; then
    echo "❌ 备份校验失败（$check），已丢弃：$tmp" >&2
    rm -f "$tmp"
    exit 1
fi

gzip -f "$tmp"
find "$OUT_DIR" -type f -name 'app-*.db.gz' -mtime +"$KEEP_DAYS" -delete

size=$(du -h "$OUT_DIR/app-$stamp.db.gz" | cut -f1)
echo "✅ 备份完成：app-$stamp.db.gz（$size，保留 $KEEP_DAYS 天）"
