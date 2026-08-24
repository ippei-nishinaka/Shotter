#!/bin/bash
#
# Shotter を Xcode なし (Command Line Tools のみ) でビルドするスクリプト。
#
#   ./build.sh            … デバッグビルド
#   ./build.sh release    … リリースビルド (-O)
#   ./build.sh run        … ビルドしてから起動
#   ./build.sh clean      … build/ を削除
#
set -euo pipefail

APP_NAME="Shotter"
DEPLOYMENT_TARGET="13.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT/$APP_NAME"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

MODE="${1:-debug}"
RUN_AFTER_BUILD="no"

case "$MODE" in
    clean)
        rm -rf "$BUILD_DIR"
        echo "🧹 build/ を削除しました"
        exit 0
        ;;
    run)
        MODE="debug"
        RUN_AFTER_BUILD="yes"
        ;;
    debug|release)
        ;;
    *)
        echo "使い方: ./build.sh [debug|release|run|clean]" >&2
        exit 1
        ;;
esac

if [ "$MODE" = "release" ]; then
    OPT_FLAGS=(-O -whole-module-optimization)
else
    OPT_FLAGS=(-Onone -g -D DEBUG)
fi

SDK_PATH="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos${DEPLOYMENT_TARGET}"

# --- ソース収集 -------------------------------------------------------------
SOURCES=()
while IFS= read -r file; do
    SOURCES+=("$file")
done < <(find "$SRC_DIR" -name '*.swift' | sort)

if [ ${#SOURCES[@]} -eq 0 ]; then
    echo "❌ $SRC_DIR に Swift ファイルが見つかりません" >&2
    exit 1
fi

echo "🔨 $APP_NAME をビルド中 (${MODE}, ${TARGET}, ${#SOURCES[@]} ファイル)"

# --- バンドル構築 -----------------------------------------------------------
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# .dSYM は -o の隣に生成されるため、いったんバンドル外でリンクしてから
# 実行ファイルだけをバンドルへコピーする。
OBJ_DIR="$BUILD_DIR/intermediates"
rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR"

xcrun swiftc \
    "${SOURCES[@]}" \
    -o "$OBJ_DIR/$APP_NAME" \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -swift-version 5 \
    -parse-as-library \
    "${OPT_FLAGS[@]}" \
    -framework AppKit \
    -framework SwiftUI \
    -framework ScreenCaptureKit \
    -framework CoreImage \
    -framework CoreMedia \
    -framework Vision

cp "$OBJ_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"

cp "$SRC_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# --- 署名 -------------------------------------------------------------------
# ad-hoc 署名はビルドのたびに署名ハッシュが変わるため、画面収録の権限が
# 毎回リセットされる。自己署名の証明書 "Shotter Dev" がキーチェーンにあれば
# そちらを使い、権限を維持できるようにする (作成: tools/create-signing-identity.sh)。
SIGN_IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Shotter Dev"; then
    SIGN_IDENTITY="Shotter Dev"
    echo "🔏 署名 ID: $SIGN_IDENTITY"
else
    echo "🔏 署名 ID: ad-hoc (権限を保持したい場合は tools/create-signing-identity.sh を実行)"
fi
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_BUNDLE" >/dev/null

echo "✅ ビルド成功: $APP_BUNDLE"

if [ "$RUN_AFTER_BUILD" = "yes" ]; then
    # すでに起動していれば一度終了させる
    pkill -x "$APP_NAME" 2>/dev/null || true
    open "$APP_BUNDLE"
    echo "🚀 起動しました (メニューバー右側のアイコンを確認してください)"
fi
