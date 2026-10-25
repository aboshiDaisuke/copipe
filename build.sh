#!/bin/bash
# Copipe.app をビルドする。 ./build.sh install で /Applications にも入れる
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Copipe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Copipe "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"

# アイコン（Support/icon_1024.png から .icns を作る）
ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Support/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Support/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# 自分用の証明書で署名する（ビルドし直してもアクセシビリティの許可が外れない）
# なければ作ってログインキーチェーンに入れる（codesign だけは確認なしで使えるようにする）
if ! security find-identity -p codesigning | grep -q "Copipe Local Signing"; then
    CERT_DIR=$(mktemp -d)
    cat > "$CERT_DIR/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Copipe Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    PASS=$(openssl rand -hex 12)
    if openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$CERT_DIR/cert.cnf" \
           -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" 2>/dev/null &&
       { openssl pkcs12 -export -legacy -inkey "$CERT_DIR/key.pem" -in "$CERT_DIR/cert.pem" \
             -out "$CERT_DIR/id.p12" -passout "pass:$PASS" 2>/dev/null ||
         openssl pkcs12 -export -inkey "$CERT_DIR/key.pem" -in "$CERT_DIR/cert.pem" \
             -out "$CERT_DIR/id.p12" -passout "pass:$PASS"; } &&
       security import "$CERT_DIR/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign >/dev/null; then
        echo "署名用の証明書「Copipe Local Signing」を作りました（初回は、入れ替えたあとにアクセシビリティを許可し直してください）"
    fi
    rm -rf "$CERT_DIR"
fi
if security find-identity -p codesigning | grep -q "Copipe Local Signing"; then
    codesign --force --sign "Copipe Local Signing" "$APP"
else
    codesign --force --sign - "$APP"
    echo "注意: 証明書を作れなかったので仮の署名にしました。入れ替えるとアクセシビリティの許可が外れます" >&2
fi
echo "ビルド完了: $APP"

if [[ "${1:-}" == "install" ]]; then
    rm -rf /Applications/Copipe.app
    cp -R "$APP" /Applications/
    # copipe:// のリンクが /Applications のほうで開くように、ビルド用のコピーは登録から外す
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
    "$LSREGISTER" -f /Applications/Copipe.app
    echo "インストール完了: /Applications/Copipe.app"
fi
