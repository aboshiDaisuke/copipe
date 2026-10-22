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
# 自分用の証明書があればそれで署名する（ビルドし直してもアクセシビリティの許可が外れない）
if security find-identity -p codesigning | grep -q "Copipe Local Signing"; then
    codesign --force --sign "Copipe Local Signing" "$APP"
else
    codesign --force --sign - "$APP"
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
