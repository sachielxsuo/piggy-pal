#!/usr/bin/env bash
# PiggyPal 客户端发版：打包 → 上传 APK 到腾讯云 → 写 latest.json → 验证线上版本信息。
#
# 用法：
#   ./release_apk.sh "修复了 xxx"             # 打包并发布（版本号取自 client/pubspec.yaml）
#   ./release_apk.sh "强制更新说明" --force   # 低于本版的客户端必须更新（= --min 本次版本号）
#   ./release_apk.sh "..." --min 19           # 指定最低可用 versionCode，低于它的客户端强制更新
#   ./release_apk.sh --skip-build "仅重传"    # 不重新打包，直接上传现有 APK
#
# 发版前先把 client/pubspec.yaml 的 version 加一（如 1.0.1+2 → 1.0.2+3），
# versionCode（+ 后面的数字）必须比线上大，手机端才会提示更新。
#
# 最低版本号（min_version_code）：
#   - 不传 --min / --force 时，沿用线上 latest.json 里已有的值，发新版不会顺手关掉强制更新
#   - 想解除强制更新，显式传 --min 0
#   - 必须 <= 本次 versionCode，服务端也会再夹一次，配错最多退化成普通更新
set -euo pipefail

cd "$(dirname "$0")"

# 服务器地址 / 域名来自 deploy.env（不入库，模板见 deploy.env.example）。
# 只填当前没设置的变量，所以命令行环境变量优先级更高。
if [ -f deploy.env ]; then
  while IFS='=' read -r key val; do
    case "$key" in ''|'#'*) continue ;; esac
    case "$key" in
      PIGGYPAL_SERVER|PIGGYPAL_USER|PIGGYPAL_DOMAIN|PIGGYPAL_REMOTE_DIR|PIGGYPAL_API_BASE)
        val=$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')
        eval "if [ -z \"\${$key:-}\" ]; then export $key=\"\$val\"; fi"
        ;;
    esac
  done < deploy.env
fi

if [ -z "${PIGGYPAL_SERVER:-}" ] || [ -z "${PIGGYPAL_DOMAIN:-}" ]; then
  echo "❌ 缺少部署配置：PIGGYPAL_SERVER / PIGGYPAL_DOMAIN" >&2
  echo "   cp deploy.env.example deploy.env 后填上自己的服务器 IP 和域名" >&2
  echo "   或临时指定：PIGGYPAL_SERVER=1.2.3.4 PIGGYPAL_DOMAIN=piggy.example.com $0 ..." >&2
  exit 1
fi

SERVER="$PIGGYPAL_SERVER"
TARGET="${PIGGYPAL_USER:-root}@${SERVER}"
REMOTE_DIR="${PIGGYPAL_REMOTE_DIR:-/opt/piggy-pal}"
DOMAIN="$PIGGYPAL_DOMAIN"

NOTE=""
FORCE=false
SKIP_BUILD=false
MIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --min)
      if [[ $# -lt 2 ]]; then
        echo "❌ --min 需要 versionCode，例如 --min 19" >&2
        exit 1
      fi
      MIN="$2"; shift 2
      ;;
    --min=*) MIN="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    -*)
      echo "❌ 未知参数：$1" >&2
      exit 1
      ;;
    *)
      if [ -n "$NOTE" ]; then
        NOTE="$NOTE $1"
      else
        NOTE="$1"
      fi
      shift
      ;;
  esac
done

LINE=$(grep -E '^version:' client/pubspec.yaml | head -1 | awk '{print $2}')
VERSION_NAME="${LINE%%+*}"
VERSION_CODE="${LINE##*+}"
if ! [[ "$VERSION_CODE" =~ ^[0-9]+$ ]]; then
  echo "❌ client/pubspec.yaml 的 version 需要形如 1.0.1+2，当前：$LINE" >&2
  exit 1
fi
if [ -z "$NOTE" ]; then
  NOTE="稳定性与体验优化"
fi

# 最低版本号：显式 --min > --force（取本次版本）> 沿用线上已有值
if [[ -n "$MIN" ]] && ! [[ "$MIN" =~ ^[0-9]+$ ]]; then
  echo "❌ --min 必须是整数 versionCode，当前：$MIN" >&2
  exit 1
fi
if [[ -z "$MIN" ]]; then
  if [[ "$FORCE" == true ]]; then
    MIN="$VERSION_CODE"
  else
    MIN=$(ssh "$TARGET" "sudo cat $REMOTE_DIR/data/releases/latest.json 2>/dev/null" 2>/dev/null \
      | python3 -c 'import json, sys
try:
    print(int(json.load(sys.stdin).get("min_version_code") or 0))
except Exception:
    print(0)' 2>/dev/null || echo 0)
    MIN=${MIN:-0}
  fi
fi
if [[ "$MIN" -gt "$VERSION_CODE" ]]; then
  echo "❌ min_version_code（$MIN）不能大于本次 versionCode（$VERSION_CODE）" >&2
  echo "   否则所有设备都会被挡在门外" >&2
  exit 1
fi

echo "==> 版本：v$VERSION_NAME (versionCode=$VERSION_CODE)，最低可用 versionCode=$MIN"

# flutter 不在 PATH 里时，按 PIGGYPAL_FLUTTER_BIN → FLUTTER_ROOT → 常见安装位置 依次找。
# 这里不写死任何本机绝对路径：换台机器 / 换个人跑都只需要设一个环境变量。
if ! command -v flutter >/dev/null 2>&1; then
  for candidate in \
    "${PIGGYPAL_FLUTTER_BIN:-}" \
    "${FLUTTER_ROOT:+$FLUTTER_ROOT/bin/flutter}" \
    "$HOME/flutter/bin/flutter" \
    "$HOME/development/flutter/bin/flutter" \
    /opt/homebrew/bin/flutter \
    /usr/local/bin/flutter; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      export PATH="$(dirname "$candidate"):$PATH"
      break
    fi
  done
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "❌ 找不到 flutter 命令" >&2
  echo "   把 flutter 加进 PATH，或指定：PIGGYPAL_FLUTTER_BIN=/path/to/flutter ./release_apk.sh \"...\"" >&2
  exit 1
fi

if [ "$SKIP_BUILD" == false ]; then
  # Flutter 会把「生成文件所在的绝对路径」写进 libapp.so，里面有一条
  # file:///.../client/.dart_tool/flutter_build/dart_plugin_registrant.dart。
  # 直接在仓库目录打包，这条路径就带上开发机的用户名，并随 APK 发到每台设备。
  # 所以默认把源码复制到一个中性目录再打包，路径里就不会出现个人信息。
  # 想就地打包（本地快速验证）：PIGGYPAL_BUILD_IN_PLACE=1 ./release_apk.sh ...
  if [ "${PIGGYPAL_BUILD_IN_PLACE:-0}" = "1" ]; then
    echo "==> 就地打包（PIGGYPAL_BUILD_IN_PLACE=1，APK 会包含本机路径）"
    ./build.sh
  else
    BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/piggy-pal-build.XXXXXX")"
    trap 'rm -rf "$BUILD_DIR"' EXIT
    echo "==> 在中性目录打包（APK 不带本机路径）：$BUILD_DIR"
    # 只排除缓存和产物；server/.env、deploy.env、key.properties 都是本机未跟踪文件，
    # 会被一起复制过去（临时目录 700，用完即删）
    rsync -a \
      --exclude '.git/' \
      --exclude 'build/' \
      --exclude '.dart_tool/' \
      --exclude 'server/piggy-pal-server' \
      ./ "$BUILD_DIR"/
    ( cd "$BUILD_DIR" && ./build.sh )
    mkdir -p "client/build/app/outputs/flutter-apk"
    cp "$BUILD_DIR/client/build/app/outputs/flutter-apk/app-release.apk" \
      "client/build/app/outputs/flutter-apk/app-release.apk"
    echo "==> 已拷回 client/build/app/outputs/flutter-apk/app-release.apk"
    rm -rf "$BUILD_DIR"
    trap - EXIT
  fi
else
  echo "==> 跳过打包，使用现有 APK"
fi

APK="client/build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$APK" ]; then
  echo "❌ 找不到 APK：$APK" >&2
  exit 1
fi

# 签名指纹校验：必须是同一把 keystore，否则已安装设备无法覆盖升级
# （INSTALL_FAILED_UPDATE_INCOMPATIBLE，只能卸载重装）。
# 当前用的是 2024-01-17 生成的 debug keystore，有效期到 2054-01-09。
EXPECTED_SHA256="${PIGGYPAL_SIGN_SHA256:-a8ec22c1d255c0ae5436bbb41053038ee6743095f163a65353aca007f83bb56e}"

find_apksigner() {
  if command -v apksigner >/dev/null 2>&1; then
    command -v apksigner
    return
  fi
  local base p
  for base in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
    "$HOME/Library/Android/sdk" "/usr/local/lib/android/sdk"; do
    [ -n "$base" ] || continue
    p=$(ls "$base"/build-tools/*/apksigner 2>/dev/null | tail -1 || true)
    if [ -n "$p" ]; then
      echo "$p"
      return
    fi
  done
}

APKSIGNER=$(find_apksigner)
if [ -z "$APKSIGNER" ]; then
  echo "❌ 找不到 apksigner，无法校验签名。请安装 Android SDK build-tools。" >&2
  exit 1
fi

CERT_INFO=$("$APKSIGNER" verify --print-certs "$APK" 2>&1) || {
  echo "❌ APK 签名校验失败：" >&2
  echo "$CERT_INFO" >&2
  exit 1
}
ACTUAL_SHA256=$(printf '%s\n' "$CERT_INFO" \
  | awk -F': ' '/SHA-256 digest/{print $2; exit}' \
  | tr -d ':' | tr 'A-F' 'a-f')

if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "❌ 签名指纹不匹配，已中止发布。" >&2
  echo "   期望：$EXPECTED_SHA256" >&2
  echo "   实际：${ACTUAL_SHA256:-（未读到）}" >&2
  echo "   原因通常是 key.properties 指向了别的 keystore，或 keystore 被重新生成。" >&2
  echo "   已安装的 App 会装不上这个包，请先恢复原 keystore（见 docs/故障排查.md）。" >&2
  exit 1
fi
echo "==> 签名校验通过：${ACTUAL_SHA256:0:16}…"

APK_BYTES=$(stat -f%z "$APK" 2>/dev/null || stat -c%s "$APK")
SHA=$(shasum -a 256 "$APK" | awk '{print $1}')
FILE="piggy-pal-${VERSION_NAME}-${VERSION_CODE}.apk"
echo "==> 安装包：${FILE}（${APK_BYTES} bytes，sha256=${SHA:0:16}…）"

echo "==> 上传到服务器 $TARGET:$REMOTE_DIR/data/releases"
ssh "$TARGET" "sudo install -d -o piggy-pal -g piggy-pal $REMOTE_DIR/data/releases"
scp "$APK" "$TARGET:/tmp/$FILE"
ssh "$TARGET" "sudo mv /tmp/$FILE $REMOTE_DIR/data/releases/$FILE && sudo chown piggy-pal:piggy-pal $REMOTE_DIR/data/releases/$FILE && sudo chmod 644 $REMOTE_DIR/data/releases/$FILE"

echo "==> 写入 latest.json"
TMP_JSON=$(mktemp)
trap 'rm -f "$TMP_JSON"' EXIT
VERSION_NAME="$VERSION_NAME" VERSION_CODE="$VERSION_CODE" FILE="$FILE" \
  APK_BYTES="$APK_BYTES" SHA="$SHA" NOTE="$NOTE" FORCE="$FORCE" MIN_VERSION_CODE="$MIN" \
  python3 - "$TMP_JSON" <<'PY'
import json, os, sys

data = {
    "version_code": int(os.environ["VERSION_CODE"]),
    "version_name": os.environ["VERSION_NAME"],
    "apk_url": "/app/download/" + os.environ["FILE"],
    "size": int(os.environ["APK_BYTES"]),
    "sha256": os.environ["SHA"],
    "changelog": os.environ["NOTE"],
    "force": os.environ["FORCE"] == "true",
    "min_version_code": int(os.environ["MIN_VERSION_CODE"]),
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
scp "$TMP_JSON" "$TARGET:/tmp/piggy-pal-latest.json"
ssh "$TARGET" "sudo mv /tmp/piggy-pal-latest.json $REMOTE_DIR/data/releases/latest.json && sudo chown piggy-pal:piggy-pal $REMOTE_DIR/data/releases/latest.json && sudo chmod 644 $REMOTE_DIR/data/releases/latest.json"

# 只保留最近 5 个安装包，旧包自动清理（含本次上传的那个）
ssh "$TARGET" "cd $REMOTE_DIR/data/releases && ls -1t *.apk 2>/dev/null | tail -n +6 | xargs -r rm -f"

echo "==> 验证线上版本信息"
TOKEN=$(grep -E '^API_TOKEN=' server/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)
if [ -n "$TOKEN" ]; then
  curl -fsS -H "X-API-Token: $TOKEN" "https://$DOMAIN/app/latest" | python3 -m json.tool
else
  curl -fsS "https://$DOMAIN/app/latest" | python3 -m json.tool
fi

echo "✅ 发布完成：v$VERSION_NAME ($VERSION_CODE)"
echo "   已安装的 App 下次启动 / 关于页「检查更新」即可拉到新版本。"
