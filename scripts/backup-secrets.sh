#!/usr/bin/env bash
# PiggyPal 密钥备份：把散落在本机的密钥打成一个包，放到 NAS。
#
# 打包内容（存在才打，缺了会提示）：
#   server/.env                   腾讯云 CAM、DeepSeek、API_TOKEN
#   deploy.env                    服务器 IP / 域名
#   client/android/key.properties  签名配置（含 keystore 路径和口令）
#   android/<keystore>            签名密钥库（路径从 key.properties 的 storeFile 读）
#
# 包内还会生成 MANIFEST.txt：文件清单 + SHA-256 + keystore 指纹，恢复时用来核对。
#
# ⚠️ 这个包**不加密**。里面是明文密钥，所以只放在自己家里、只有你能登录的地方：
#    NAS 的私有目录（700），别放 iCloud / 坚果云 / 微信 / 网盘共享链接，
#    更不要提交进 git。要外发就用别的工具另外加密。
#
# 用法：
#   ./scripts/backup-secrets.sh                     # 输出到 ~/piggypal-secrets
#   ./scripts/backup-secrets.sh --out /Volumes/xxx  # 指定目录（比如挂载的 NAS 共享文件夹）
#   ./scripts/backup-secrets.sh --restore 包.tar.gz --to /tmp/restore
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

OUT_DIR="${PIGGYPAL_SECRETS_DIR:-$HOME/piggypal-secrets}"
RESTORE_FILE=""
RESTORE_TO=""

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --out) OUT_DIR="${2:?--out 需要目录}"; shift 2 ;;
    --restore) RESTORE_FILE="${2:?--restore 需要备份包路径}"; shift 2 ;;
    --to) RESTORE_TO="${2:?--to 需要目录}"; shift 2 ;;
    *) echo "未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

# ---------- 恢复 ----------

if [ -n "$RESTORE_FILE" ]; then
  [ -f "$RESTORE_FILE" ] || { echo "❌ 找不到：$RESTORE_FILE" >&2; exit 1; }
  RESTORE_TO="${RESTORE_TO:-$PWD/restored-secrets}"

  mkdir -p "$RESTORE_TO"
  echo "==> 解包到 $RESTORE_TO"
  if ! tar xzf "$RESTORE_FILE" -C "$RESTORE_TO"; then
    echo "❌ 解包失败：文件损坏，或者不是这个脚本打出来的包" >&2
    exit 1
  fi

  echo "==> 包内内容"
  ( cd "$RESTORE_TO" && ls -l )
  if [ -f "$RESTORE_TO/MANIFEST.txt" ]; then
    echo
    cat "$RESTORE_TO/MANIFEST.txt"
  fi
  echo
  echo "✅ 已解到 $RESTORE_TO"
  echo "   放回项目里的对应位置（权限 600）后，按 docs/密钥与恢复.md 走一遍恢复演练。"
  exit 0
fi

# ---------- 备份 ----------

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/piggypal-secrets.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

missing=0
add() { # add <包内路径> <源文件> <说明>
  if [ -f "$2" ]; then
    mkdir -p "$STAGE/$(dirname "$1")"
    cp -p "$2" "$STAGE/$1"
    chmod 600 "$STAGE/$1"
    printf '  ✓ %-34s %s\n' "$1" "$3"
  else
    printf '  ✗ %-34s 缺失：%s\n' "$1" "$2"
    missing=$((missing + 1))
  fi
}

echo "==> 收集本机密钥"
add "server.env"              "$ROOT/server/.env"              "腾讯云 CAM / DeepSeek / API_TOKEN"
add "deploy.env"              "$ROOT/deploy.env"               "服务器地址与域名"
add "android/key.properties"  "$ROOT/client/android/key.properties" "签名配置"

# keystore 路径从 key.properties 的 storeFile 读，不写死任何本机路径
KEYSTORE=""
if [ -f "$ROOT/client/android/key.properties" ]; then
  KEYSTORE="$(sed -n 's/^[[:space:]]*storeFile[[:space:]]*=[[:space:]]*//p' \
    "$ROOT/client/android/key.properties" | head -1)"
fi
HAVE_KEYSTORE=0
if [ -n "$KEYSTORE" ] && [ -f "$KEYSTORE" ]; then
  add "android/$(basename "$KEYSTORE")" "$KEYSTORE" "签名密钥库（丢了无法覆盖升级）"
  HAVE_KEYSTORE=1
else
  printf '  ✗ %-34s 缺失：%s\n' "android/keystore" "${KEYSTORE:-key.properties 里没读到 storeFile}"
  missing=$((missing + 1))
fi

if [ "$missing" -gt 0 ]; then
  echo
  echo "⚠️  有 $missing 项没找到，确认是不是在别的机器上（或用 --help 看说明）"
fi
if [ "$HAVE_KEYSTORE" = 0 ]; then
  echo "⚠️  没有 keystore：这个包救不回签名，务必补上（丢了所有设备要卸载重装）" >&2
fi

# macOS 用 shasum，Linux 用 sha256sum
sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

# MANIFEST：恢复时用来核对，本身不含密钥内容
{
  echo "PiggyPal 密钥备份"
  echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "系统：$(uname -s) $(uname -m)"
  echo
  echo "文件（大小 / SHA-256）："
  ( cd "$STAGE" && find . -type f ! -name MANIFEST.txt -print | sort ) |
    sed 's|^\./||' |
    while IFS= read -r f; do
      printf '  %-34s %8s  %s\n' "$f" \
        "$(wc -c < "$STAGE/$f" | tr -d ' ')" \
        "$(sha256 "$STAGE/$f")"
    done
  echo
  if command -v keytool >/dev/null 2>&1 && [ -n "$KEYSTORE" ] && [ -f "$KEYSTORE" ]; then
    fp="$(keytool -list -v -keystore "$KEYSTORE" -storepass android 2>/dev/null |
      grep -E "SHA256:|别名|Alias" | sed 's/^/  /' || true)"
    if [ -n "$fp" ]; then
      echo "keystore 指纹（恢复后请核对一致）："
      printf '%s\n' "$fp"
    fi
  fi
} > "$STAGE/MANIFEST.txt"
chmod 600 "$STAGE/MANIFEST.txt"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
OUT="$OUT_DIR/piggypal-secrets-$(date '+%Y%m%d-%H%M%S').tar.gz"

echo "==> 打包（不加密，包里是明文密钥）"
# COPYFILE_DISABLE=1 防止 macOS 把扩展属性写成 ._ 文件
COPYFILE_DISABLE=1 tar czf "$OUT" -C "$STAGE" .
chmod 600 "$OUT"

echo
echo "✅ 已生成：$OUT"
echo "   大小：$(du -h "$OUT" | cut -f1)"
echo "   SHA-256：$(sha256 "$OUT")"
echo
echo "下一步："
echo "  1. 拷一份到 NAS（和数据库备份分开放）："
echo "       scp \"$OUT\" <你的NAS账号>@<NAS地址>:<NAS 备份根>/secrets/"
echo "     或者直接拖进挂载的共享文件夹"
echo "  2. 这个包是明文，目录权限设成 700，只在自己机器和 NAS 私有目录里流动"
echo "  3. 每季度跑一次恢复演练：--restore 解开，核对 MANIFEST 里的 keystore 指纹"
