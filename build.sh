#!/bin/bash
#
# Shotter を Xcode なし (Command Line Tools のみ) でビルドするスクリプト。
#
#   ./build.sh            … デバッグビルド
#   ./build.sh release    … リリースビルド (-O)
#   ./build.sh run        … ビルドしてから起動
#   ./build.sh install    … リリースビルドして /Applications に入れる
#                            （Dock・Launchpad・Spotlight から起動できるようにする）
#   ./build.sh dist       … 配布用の universal binary を作って zip に固める
#   ./build.sh clean      … build/ と dist/ を削除
#
# dist で公証まで行う場合は、次の 2 つを環境変数で渡す。
# どちらも未設定なら ad-hoc 署名のままパッケージだけ作る。
#
#   SHOTTER_DEVELOPER_ID   例: "Developer ID Application: Your Name (TEAMID)"
#   SHOTTER_NOTARY_PROFILE xcrun notarytool store-credentials で作った プロファイル名
#
set -euo pipefail

APP_NAME="Shotter"
DEPLOYMENT_TARGET="13.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT/$APP_NAME"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

MODE="${1:-debug}"
RUN_AFTER_BUILD="no"
INSTALL_AFTER_BUILD="no"

case "$MODE" in
    clean)
        rm -rf "$BUILD_DIR" "$DIST_DIR"
        echo "🧹 build/ と dist/ を削除しました"
        exit 0
        ;;
    run)
        MODE="debug"
        RUN_AFTER_BUILD="yes"
        ;;
    install)
        MODE="release"
        INSTALL_AFTER_BUILD="yes"
        ;;
    debug|release|dist)
        ;;
    *)
        echo "使い方: ./build.sh [debug|release|run|install|dist|clean]" >&2
        exit 1
        ;;
esac

if [ "$MODE" = "debug" ]; then
    OPT_FLAGS=(-Onone -g -D DEBUG)
else
    OPT_FLAGS=(-O -whole-module-optimization)
fi

# 配布物は Intel Mac でも動くよう universal binary にする。
if [ "$MODE" = "dist" ]; then
    ARCHS=(arm64 x86_64)
else
    ARCHS=("$(uname -m)")
fi

SDK_PATH="$(xcrun --show-sdk-path)"

# --- ソース収集 -------------------------------------------------------------
SOURCES=()
while IFS= read -r file; do
    SOURCES+=("$file")
done < <(find "$SRC_DIR" -name '*.swift' | sort)

if [ ${#SOURCES[@]} -eq 0 ]; then
    echo "❌ $SRC_DIR に Swift ファイルが見つかりません" >&2
    exit 1
fi

echo "🔨 $APP_NAME をビルド中 (${MODE}, ${ARCHS[*]}, ${#SOURCES[@]} ファイル)"

# --- バンドル構築 -----------------------------------------------------------
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# .dSYM は -o の隣に生成されるため、いったんバンドル外でリンクしてから
# 実行ファイルだけをバンドルへコピーする。
OBJ_DIR="$BUILD_DIR/intermediates"
rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR"

SLICES=()
for arch in "${ARCHS[@]}"; do
    [ ${#ARCHS[@]} -gt 1 ] && echo "   ↳ ${arch}"
    xcrun swiftc \
        "${SOURCES[@]}" \
        -o "$OBJ_DIR/$APP_NAME-$arch" \
        -sdk "$SDK_PATH" \
        -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
        -swift-version 5 \
        -parse-as-library \
        "${OPT_FLAGS[@]}" \
        -framework AppKit \
        -framework SwiftUI \
        -framework ScreenCaptureKit \
        -framework CoreImage \
        -framework CoreMedia \
        -framework Vision
    SLICES+=("$OBJ_DIR/$APP_NAME-$arch")
done

if [ ${#SLICES[@]} -gt 1 ]; then
    lipo -create -output "$MACOS_DIR/$APP_NAME" "${SLICES[@]}"
else
    cp "${SLICES[0]}" "$MACOS_DIR/$APP_NAME"
fi

cp "$SRC_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
cp "$SRC_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# --- 署名 -------------------------------------------------------------------
if [ "$MODE" = "dist" ]; then
    # 配布物では自己署名 "Shotter Dev" を使わない（他人の Mac では信頼されず、
    # かえって「壊れている」と判断されることがあるため）。
    if [ -n "${SHOTTER_DEVELOPER_ID:-}" ]; then
        echo "🔏 署名 ID: $SHOTTER_DEVELOPER_ID (hardened runtime)"
        codesign --force --sign "$SHOTTER_DEVELOPER_ID" \
            --options runtime --timestamp "$APP_BUNDLE"
    else
        echo "🔏 署名 ID: ad-hoc（未公証。受け取った人は Gatekeeper の解除操作が必要です）"
        codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null
    fi
else
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
fi

echo "✅ ビルド成功: $APP_BUNDLE"

if [ "$RUN_AFTER_BUILD" = "yes" ]; then
    # すでに起動していれば一度終了させる
    pkill -x "$APP_NAME" 2>/dev/null || true
    open "$APP_BUNDLE"
    echo "🚀 起動しました (メニューバー右側のアイコンを確認してください)"
fi

if [ "$INSTALL_AFTER_BUILD" = "yes" ]; then
    INSTALLED_APP="/Applications/$APP_NAME.app"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "$INSTALLED_APP"
    ditto "$APP_BUNDLE" "$INSTALLED_APP"
    echo "📦 /Applications/$APP_NAME.app に入れました（Dock・Launchpad・Spotlight から起動できます）"
    open "$INSTALLED_APP"
    echo "🚀 起動しました (メニューバー右側のアイコンを確認してください)"
fi

[ "$MODE" = "dist" ] || exit 0

# --- 配布用パッケージ -------------------------------------------------------
VERSION="${SHOTTER_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")}"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

# zip ではなく ditto を使う。バンドルの署名やシンボリックリンクが壊れないため。
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

if [ -n "${SHOTTER_NOTARY_PROFILE:-}" ]; then
    echo "📮 公証に提出中（数分かかります）…"
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$SHOTTER_NOTARY_PROFILE" \
        --wait

    echo "📎 チケットを添付中…"
    xcrun stapler staple "$APP_BUNDLE"

    # staple 後のバンドルで zip を作り直す（オフラインでも検証が通るように）。
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    echo "🔎 Gatekeeper の判定:"
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/   /'
else
    echo "⚠️  公証はスキップしました（SHOTTER_NOTARY_PROFILE が未設定）"
fi

echo
echo "📦 配布物: $ZIP_PATH"
echo "   バージョン: $VERSION"
lipo -archs "$MACOS_DIR/$APP_NAME" | sed 's/^/   アーキテクチャ: /'
du -h "$ZIP_PATH" | awk '{print "   サイズ: " $1}'
