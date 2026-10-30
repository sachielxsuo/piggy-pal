#!/usr/bin/env bash
# PiggyPal 客户端打包脚本（线上发布用 release 包）。
#
# 用法：
#   ./build.sh              # Android release（arm64 单架构，不兼容老设备）
#   ./build.sh -p ios       # iOS（需 Xcode + CocoaPods + 开发者账号，暂未配环境）
# 产物：client/build/app/outputs/flutter-apk/app-release.apk
set -euo pipefail

PLATFORM="android"
while getopts "p:" opt; do
  case "$opt" in
    p) PLATFORM="$OPTARG" ;;
    *) ;;
  esac
done

cd "$(dirname "$0")/client"

# API 地址来自仓库根的 deploy.env（不入库，模板见 deploy.env.example）。
# 只填当前没设置的变量，命令行环境变量优先级更高。
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

API_BASE_URL="${PIGGYPAL_API_BASE:-}"
if [ -z "$API_BASE_URL" ] && [ -n "${PIGGYPAL_DOMAIN:-}" ]; then
  API_BASE_URL="https://${PIGGYPAL_DOMAIN}"
fi
if [ -z "$API_BASE_URL" ]; then
  echo "❌ 没有 API 地址：客户端会连不上后端" >&2
  echo "   cp deploy.env.example deploy.env 并填 PIGGYPAL_DOMAIN，或传 PIGGYPAL_API_BASE=https://..." >&2
  exit 1
fi
echo "==> API 地址：$API_BASE_URL"

# 从 server/.env 读取全站共享 token，打包时注入（token 会被编译进 APK）
API_TOKEN=$(grep -E '^API_TOKEN=' ../server/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)
if [ -z "$API_TOKEN" ]; then
  echo "⚠️  未从 server/.env 读到 API_TOKEN；若服务端已开启校验，请求会返回 401" >&2
fi

case "$PLATFORM" in
  android)
    echo "==> 打包 Android release（arm64 单架构）"
    flutter build apk --release --target-platform android-arm64 \
      --dart-define=API_TOKEN="$API_TOKEN" \
      --dart-define=API_BASE_URL="$API_BASE_URL"

    echo "==> 校验 release 包关键类未被 R8 裁剪（SharedPreferences / JNI）"
    APK="build/app/outputs/flutter-apk/app-release.apk"
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT
    unzip -p "$APK" classes.dex > "$TMP_DIR/classes.dex"

    # 优先用 Android SDK 的 dexdump 精确校验方法签名；找不到时退化为字符串检查
    DEXDUMP=$(command -v dexdump || true)
    if [ -z "$DEXDUMP" ]; then
      for base in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
        "$HOME/Library/Android/sdk" "/usr/local/lib/android/sdk"; do
        [ -n "$base" ] || continue
        DEXDUMP=$(ls "$base"/build-tools/*/dexdump 2>/dev/null | tail -1 || true)
        [ -n "$DEXDUMP" ] && break
      done
    fi

    if [ -n "$DEXDUMP" ]; then
      "$DEXDUMP" -d "$TMP_DIR/classes.dex" > "$TMP_DIR/dex.txt" 2>/dev/null || true
      if ! grep -aqF "(Ljava/lang/String;Ljava/util/List;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;" "$TMP_DIR/dex.txt"; then
        echo "❌ SharedPreferences 的 getAll 方法签名被 R8 改写（kotlin/coroutines/Continuation 被混淆）。" >&2
        echo "   检查 client/android/app/proguard-rules.pro 是否仍然保留 JNI 依赖的 Kotlin 类。" >&2
        exit 1
      fi
      if ! grep -aqF "'Lkotlin/coroutines/intrinsics/CoroutineSingletons;'" "$TMP_DIR/dex.txt"; then
        echo "❌ kotlin/coroutines/intrinsics/CoroutineSingletons 被 R8 裁掉，SharedPreferences 会崩溃。" >&2
        echo "   检查 client/android/app/proguard-rules.pro。" >&2
        exit 1
      fi
      echo "✅ JNI 关键类和签名正常"
    else
      echo "⚠️  未找到 dexdump，跳过签名校验（建议安装 Android SDK build-tools）" >&2
      if ! grep -aqF "kotlin/coroutines/intrinsics/CoroutineSingletons" "$TMP_DIR/classes.dex"; then
        echo "❌ release 包缺少 CoroutineSingletons，SharedPreferences 会崩溃。" >&2
        exit 1
      fi
    fi
    echo "✅ 产物：$APK"
    ;;
  ios)
    echo "==> 打包 iOS release（需 macOS + Xcode + CocoaPods + 开发者账号，暂未配）"
    flutter build ipa --release --dart-define=API_TOKEN="$API_TOKEN" \
      --dart-define=API_BASE_URL="$API_BASE_URL"
    ;;
  *)
    echo "❌ 未知平台：$PLATFORM（支持 android / ios）" >&2
    exit 1
    ;;
esac
