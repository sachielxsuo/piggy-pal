#!/usr/bin/env bash
# PiggyPal 后端部署脚本（裸二进制 + systemd 方案）
# 本地交叉编译 → scp 上传 → 排空旧进程 → 原子换版本 → 就绪校验（失败自动回滚）
#
# 无损程度：
#   - 空载发布：停服窗口约 1–2 秒（老进程退出 → 新进程 bind）
#   - 正在对话时发布：会等这条请求跑完（最长 130 秒）再退出，不丢消息、不断流
#   - 发布期间 watchdog 跳过巡检，不会把「换版本」误报成故障
#
# 用法：
#   ./deploy/deploy.sh                 # 常规部署（要求服务器已有 /opt/piggy-pal/.env）
#   ./deploy/deploy.sh --with-env      # 服务器还没有 .env 时，顺手把本地 server/.env 传上去
#   PIGGYPAL_SERVER=1.2.3.4 ./deploy/deploy.sh
set -euo pipefail

# 始终以 server/ 为工作目录，避免在仓库根目录执行时找不到 go.mod
cd "$(dirname "$0")/.."

# 服务器地址 / 域名来自仓库根的 deploy.env（不入库，模板见 deploy.env.example）。
# 只填当前没设置的变量，所以命令行环境变量优先级更高。
if [[ -f ../deploy.env ]]; then
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

if [[ -z "${PIGGYPAL_SERVER:-}" || -z "${PIGGYPAL_DOMAIN:-}" ]]; then
  echo "❌ 缺少部署配置：PIGGYPAL_SERVER / PIGGYPAL_DOMAIN" >&2
  echo "   cp deploy.env.example deploy.env 后填上自己的服务器 IP 和域名" >&2
  echo "   或临时指定：PIGGYPAL_SERVER=1.2.3.4 PIGGYPAL_DOMAIN=piggy.example.com ./deploy/deploy.sh" >&2
  exit 1
fi

SERVER="$PIGGYPAL_SERVER"
TARGET="${PIGGYPAL_USER:-root}@${SERVER}"
REMOTE_DIR="${PIGGYPAL_REMOTE_DIR:-/opt/piggy-pal}"
DOMAIN="$PIGGYPAL_DOMAIN"
MARKER="$REMOTE_DIR/data/watchdog/maintenance"
WITH_ENV=0
for arg in "$@"; do
  case "$arg" in
    --with-env) WITH_ENV=1 ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done

if [[ ! -f .env && "$WITH_ENV" == 1 ]]; then
  echo "❌ 本地 server/.env 不存在，无法上传" >&2
  exit 1
fi

echo "==> 1/8 交叉编译 linux/amd64 单二进制"
# -trimpath：把源码路径改写成模块内的相对路径（piggy-pal/server/...）。
# 不加的话二进制里的文件路径、以及 slog 的 source= 字段会带上构建机的绝对
# 路径（比如 /Users/xxx/...），等于把开发机目录结构写进线上日志。
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags="-s -w" -o piggy-pal-server ./cmd/server

echo "==> 2/8 上传二进制 + 配置 + systemd unit（先放 /tmp，切换时再替换）"
ssh "$TARGET" "sudo mkdir -p $REMOTE_DIR"
# 运行中的可执行文件不能直接覆盖（ETXTBSY），先传临时文件，切换时再 mv
ssh "$TARGET" "rm -rf /tmp/piggy-pal-config /tmp/piggy-pal-server.new"
scp piggy-pal-server "$TARGET:/tmp/piggy-pal-server.new"
scp -r config "$TARGET:/tmp/piggy-pal-config"
scp deploy/piggy-pal.service "$TARGET:/tmp/piggy-pal.service"

echo "==> 3/8 检查 / 上传密钥文件"
if [[ "$WITH_ENV" == 1 ]]; then
  scp .env "$TARGET:$REMOTE_DIR/.env"
  ssh "$TARGET" "sudo chown root:root $REMOTE_DIR/.env && sudo chmod 600 $REMOTE_DIR/.env"
elif ! ssh "$TARGET" "test -f $REMOTE_DIR/.env"; then
  echo "❌ 服务器上没有 $REMOTE_DIR/.env" >&2
  echo "   首次部署请用：./deploy/deploy.sh --with-env" >&2
  echo "   或手动上传：scp server/.env root@$SERVER:$REMOTE_DIR/.env && ssh $SERVER 'chmod 600 $REMOTE_DIR/.env'" >&2
  exit 1
fi

echo "==> 4/8 在线备份数据库（不停服）"
# 用 sqlite3 .backup 热备：不需要停服，也不会拷到写了一半的页。
# 老脚本为了 cp 数据库先停服，然后把停服窗口拉到了 1 分多钟，这是 20:30 那次误报的直接原因。
ssh "$TARGET" "if [ -f $REMOTE_DIR/data/app.db ]; then sudo sqlite3 $REMOTE_DIR/data/app.db \".backup '$REMOTE_DIR/data/app.db.bak.\$(date +%Y%m%d%H%M%S)'\" && sudo find $REMOTE_DIR/data -maxdepth 1 -name 'app.db.bak.*' -mtime +7 -delete && echo '   已在线备份 app.db'; else echo '   首次部署，暂无数据库'; fi"

echo "==> 5/8 建低权限用户 + 装日志轮转 + 备份 / 巡检单元（不碰主服务）"
ssh "$TARGET" "id -u piggy-pal &>/dev/null || sudo useradd -r -s /usr/sbin/nologin piggy-pal"
# 日志目录：提前建好并授权给服务用户，systemd 才能以 append 方式写入
ssh "$TARGET" "sudo install -d -o piggy-pal -g piggy-pal /var/log/piggy-pal"
# 客户端上传日志单独目录，避免和 server.log 混在一起
ssh "$TARGET" "sudo install -d -o piggy-pal -g piggy-pal /var/log/piggy-pal/client"
# 自动更新安装包目录：release_apk.sh 会往里传，部署不会清理
ssh "$TARGET" "sudo install -d -o piggy-pal -g piggy-pal $REMOTE_DIR/data/releases"
scp deploy/piggy-pal.logrotate "$TARGET:/tmp/piggy-pal.logrotate"
ssh "$TARGET" "sudo mv /tmp/piggy-pal.logrotate /etc/logrotate.d/piggy-pal"

# 每日数据库备份：sqlite3 .backup 在线热备，gzip 后保留 14 天，凌晨 03:30 跑
ssh "$TARGET" "sudo install -d -o piggy-pal -g piggy-pal $REMOTE_DIR/data/backups"
scp deploy/piggy-pal-backup.sh "$TARGET:/tmp/piggy-pal-backup"
scp deploy/piggy-pal-backup.service "$TARGET:/tmp/piggy-pal-backup.service"
scp deploy/piggy-pal-backup.timer "$TARGET:/tmp/piggy-pal-backup.timer"
ssh "$TARGET" "sudo mv /tmp/piggy-pal-backup $REMOTE_DIR/piggy-pal-backup && sudo chown piggy-pal:piggy-pal $REMOTE_DIR/piggy-pal-backup && sudo chmod 755 $REMOTE_DIR/piggy-pal-backup"
ssh "$TARGET" "sudo mv /tmp/piggy-pal-backup.service /etc/systemd/system/piggy-pal-backup.service && sudo mv /tmp/piggy-pal-backup.timer /etc/systemd/system/piggy-pal-backup.timer && sudo systemctl daemon-reload && sudo systemctl enable --now piggy-pal-backup.timer"

# 功能级巡检：每 10 分钟扫日志（TTS 额度 / ERROR）+ 备份是否生成 + 磁盘，异常推企业微信
# /healthz 只能证明进程活着，抓不到「服务活着但功能坏了」的问题（2026-10-27 佩奇静音那次就是）
scp deploy/piggy-pal-watchdog.sh "$TARGET:/tmp/piggy-pal-watchdog"
scp deploy/piggy-pal-watchdog.service "$TARGET:/tmp/piggy-pal-watchdog.service"
scp deploy/piggy-pal-watchdog.timer "$TARGET:/tmp/piggy-pal-watchdog.timer"
ssh "$TARGET" "sudo mv /tmp/piggy-pal-watchdog $REMOTE_DIR/piggy-pal-watchdog && sudo chown piggy-pal:piggy-pal $REMOTE_DIR/piggy-pal-watchdog && sudo chmod 755 $REMOTE_DIR/piggy-pal-watchdog"
ssh "$TARGET" "sudo install -d -o piggy-pal -g piggy-pal $REMOTE_DIR/data/watchdog"
# 告警配置：只在不存在时建模板，避免覆盖已填的 webhook
ssh "$TARGET" "if [ ! -f $REMOTE_DIR/alert.env ]; then printf '# 企业微信群机器人 webhook（群设置 → 群机器人 → 添加 → 复制 Webhook 地址）\nWECOM_WEBHOOK=\n' | sudo tee $REMOTE_DIR/alert.env >/dev/null && echo '   已生成 $REMOTE_DIR/alert.env 模板（待填 webhook）'; fi"
# 巡检以 piggy-pal 身份运行，只给它读权限
ssh "$TARGET" "sudo chown root:piggy-pal $REMOTE_DIR/alert.env && sudo chmod 640 $REMOTE_DIR/alert.env"
ssh "$TARGET" "sudo mv /tmp/piggy-pal-watchdog.service /etc/systemd/system/piggy-pal-watchdog.service && sudo mv /tmp/piggy-pal-watchdog.timer /etc/systemd/system/piggy-pal-watchdog.timer && sudo systemctl daemon-reload && sudo systemctl enable --now piggy-pal-watchdog.timer"

# NAS 异地备份的服务端配套：rrsync（把 SSH 锁死在只读备份目录）+ 心跳包装器
# 版本跟着服务器的 rsync 走（rsync 3.2.7 ←→ rrsync v3.2.7，新版 rrsync 会要求 --confine-root 而老 rsync 不认识）
scp deploy/rrsync-heartbeat.sh "$TARGET:/tmp/rrsync-heartbeat"
ssh "$TARGET" "if [ ! -x /usr/local/bin/rrsync ]; then sudo curl -fsSL -o /tmp/rrsync https://raw.githubusercontent.com/WayneD/rsync/v3.2.7/support/rrsync && sudo install -m 755 -o root -g root /tmp/rrsync /usr/local/bin/rrsync && sudo rm -f /tmp/rrsync && echo '   已安装 rrsync'; fi"
ssh "$TARGET" "sudo install -m 755 -o root -g root /tmp/rrsync-heartbeat /usr/local/bin/rrsync-heartbeat && sudo rm -f /tmp/rrsync-heartbeat"
ssh "$TARGET" "sudo install -d -m 750 -o backup -g piggy-pal /var/lib/piggy-pal-nas 2>/dev/null || true"

echo "==> 6/8 切换版本：标记维护 → 停服排空 → 换二进制 / 配置 → 启动 → 就绪校验"
# 维护标记：watchdog 看到就整轮跳过，避免停服窗口被误报成故障
# 无论成功失败都在 EXIT 时清理；遗留超过 2 小时的标记会被 watchdog 自动忽略
ssh "$TARGET" "sudo touch $MARKER"
cleanup() { ssh "$TARGET" "sudo rm -f $MARKER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 停服会等进程排空在途请求（最多 130 秒），systemd 侧 TimeoutStopSec=150
stop_start=$(date +%s)
ssh "$TARGET" "sudo systemctl stop piggy-pal"
echo "   已排空并停止（耗时 $(( $(date +%s) - stop_start )) 秒）"

# 老版本留一份 .prev，新版本起不来时自动回滚
ssh "$TARGET" "set -e
  [ -f $REMOTE_DIR/piggy-pal-server ] && sudo cp -a $REMOTE_DIR/piggy-pal-server $REMOTE_DIR/piggy-pal-server.prev || true
  sudo rm -rf $REMOTE_DIR/config.prev
  [ -d $REMOTE_DIR/config ] && sudo cp -a $REMOTE_DIR/config $REMOTE_DIR/config.prev || true
  sudo mv /tmp/piggy-pal-server.new $REMOTE_DIR/piggy-pal-server
  sudo rm -rf $REMOTE_DIR/config && sudo mv /tmp/piggy-pal-config $REMOTE_DIR/config
  sudo mv /tmp/piggy-pal.service /etc/systemd/system/piggy-pal.service
  sudo systemctl daemon-reload
  sudo chown -R piggy-pal:piggy-pal $REMOTE_DIR
  sudo systemctl enable piggy-pal >/dev/null
  sudo systemctl start piggy-pal"

# 就绪探针：/readyz 会真的探一次数据库，比只看端口更有意义
if ! ssh "$TARGET" "for i in \$(seq 1 30); do curl -fsS --max-time 2 http://127.0.0.1:18080/readyz >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"; then
  echo "❌ 新版本 30 秒内未就绪，自动回滚" >&2
  ssh "$TARGET" "sudo systemctl stop piggy-pal || true
    [ -f $REMOTE_DIR/piggy-pal-server.prev ] && sudo mv $REMOTE_DIR/piggy-pal-server.prev $REMOTE_DIR/piggy-pal-server
    [ -d $REMOTE_DIR/config.prev ] && sudo rm -rf $REMOTE_DIR/config && sudo mv $REMOTE_DIR/config.prev $REMOTE_DIR/config
    sudo systemctl start piggy-pal" || true
  ssh "$TARGET" "for i in \$(seq 1 15); do curl -fsS --max-time 2 http://127.0.0.1:18080/healthz >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1" \
    && echo "   已回滚到上一个版本" \
    || echo "   ⚠️  回滚后仍未探活成功，请立即查看：ssh $TARGET 'sudo journalctl -u piggy-pal -n 80'" >&2
  exit 1
fi
echo "   新版本已就绪"

echo "==> 7/8 配置 Caddy HTTPS 反代"
# Caddyfile 里写的是占位域名 piggy.example.com，这里替换成 deploy.env 里的真实域名
CADDY_RENDERED="$(mktemp "${TMPDIR:-/tmp}/piggy-pal.Caddyfile.XXXXXX")"
sed "s/piggy\.example\.com/$DOMAIN/g" deploy/Caddyfile > "$CADDY_RENDERED"
scp "$CADDY_RENDERED" "$TARGET:/tmp/piggy-pal.Caddyfile"
if ssh "$TARGET" "command -v caddy >/dev/null 2>&1"; then
  # 覆盖前备份旧配置，避免误伤同机其他站点
  ssh "$TARGET" "if [ -f /etc/caddy/Caddyfile ]; then sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.\$(date +%s); fi; sudo cp /tmp/piggy-pal.Caddyfile /etc/caddy/Caddyfile && sudo systemctl enable --now caddy && sudo systemctl reload caddy"
  echo "    Caddy 已 reload，证书会自动签发"
else
  echo "    ⚠️  服务器还没装 Caddy，HTTPS 暂不可用。装好后这样配（域名已替换好）："
  echo "       scp \"$CADDY_RENDERED\" root@$SERVER:/etc/caddy/Caddyfile"
  echo "       ssh $SERVER 'sudo systemctl reload caddy'"
fi
rm -f "$CADDY_RENDERED"

echo "==> 8/8 清理维护标记"
cleanup
trap - EXIT

echo "✅ 部署完成"
echo "   本机直连：curl http://$SERVER:18080/healthz"
echo "   HTTPS：  curl https://$DOMAIN/healthz"
echo "   若 HTTPS 未通，先确认 ${DOMAIN} 的 A 记录已指向 ${SERVER}，且安全组放行 80/443"
echo "   回滚：ssh $TARGET 'sudo mv $REMOTE_DIR/piggy-pal-server.prev $REMOTE_DIR/piggy-pal-server && sudo systemctl restart piggy-pal'"
