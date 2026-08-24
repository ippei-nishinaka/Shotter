#!/bin/bash
#
# 開発用の自己署名コード署名証明書 "Shotter Dev" を作成する。
#
# ad-hoc 署名 (codesign -s -) だとビルドのたびに署名ハッシュが変わるため、
# 「画面収録」の許可が毎回リセットされてしまう。安定した署名 ID で署名すると
# 一度許可すればビルドし直しても許可が維持される。
#
# 実行するとキーチェーンへのアクセス許可を求めるダイアログが出ることがある。
# うまくいかない場合は「キーチェーンアクセス.app > 証明書アシスタント >
# 証明書を作成」で、名前 "Shotter Dev" / 証明書のタイプ「コード署名」/
# 自己署名を選んで手動作成しても同じ結果になる。
#
set -euo pipefail

IDENTITY_NAME="Shotter Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "✅ 署名 ID \"$IDENTITY_NAME\" はすでに存在します"
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/openssl.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = $IDENTITY_NAME

[ v3 ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
CNF

echo "🔑 自己署名証明書を生成中…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP_DIR/key.pem" \
    -out "$TMP_DIR/cert.pem" \
    -config "$TMP_DIR/openssl.cnf" 2>/dev/null

openssl pkcs12 -export \
    -inkey "$TMP_DIR/key.pem" \
    -in "$TMP_DIR/cert.pem" \
    -out "$TMP_DIR/identity.p12" \
    -name "$IDENTITY_NAME" \
    -passout pass:shotter 2>/dev/null

KEYCHAIN="$(security default-keychain | sed -e 's/^ *"//' -e 's/"$//')"
echo "📥 キーチェーンへ登録中: $KEYCHAIN"
security import "$TMP_DIR/identity.p12" -k "$KEYCHAIN" -P shotter -T /usr/bin/codesign

echo "🔏 コード署名用に信頼設定を追加中（パスワードを求められる場合があります）…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP_DIR/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "$IDENTITY_NAME"; then
    echo "✅ 署名 ID \"$IDENTITY_NAME\" を作成しました。./build.sh が自動的に使用します。"
else
    echo "⚠️  作成に失敗しました。キーチェーンアクセス.app から手動で作成してください。"
    exit 1
fi
