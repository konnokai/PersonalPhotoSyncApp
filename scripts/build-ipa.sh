#!/usr/bin/env bash
# 產生「未簽署」的 IPA，交給 Sideloadly、AltStore、iOS App Signer 之類的工具重新簽署後安裝。
# 用法：scripts/build-ipa.sh [輸出目錄]    預設輸出到 build/ipa/PhotoSync.ipa
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-build/ipa}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 建置 Release、arm64、真機；不簽署，簽署交給之後的工具。
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$WORK/dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

APP="$WORK/dd/Build/Products/Release-iphoneos/PhotoSync.app"
[ -d "$APP" ] || { echo "找不到 $APP" >&2; exit 1; }

mkdir -p "$WORK/ipa/Payload" "$OUT_DIR"
cp -R "$APP" "$WORK/ipa/Payload/"
IPA="$OUT_DIR/PhotoSync.ipa"
rm -f "$IPA"
# ditto 保留符號連結；--norsrc 不收 ._* 檔（會讓簽署工具誤判）；--keepParent 讓 zip 最上層是 Payload/。
(cd "$WORK/ipa" && ditto -c -k --norsrc --keepParent Payload "$WORK/PhotoSync.zip")
mv "$WORK/PhotoSync.zip" "$IPA"

echo "完成：$IPA ($(du -h "$IPA" | cut -f1))"
# 先存成變數再檢查：grep -q 提早結束會讓 unzip 收到 SIGPIPE，在 pipefail 下被當成失敗。
LISTING="$(unzip -l "$IPA")"
grep -q "Payload/PhotoSync.app/PhotoSync$" <<<"$LISTING" || { echo "IPA 裡沒有主程式" >&2; exit 1; }
if grep -q "/\._" <<<"$LISTING"; then echo "IPA 含有 ._ 檔" >&2; exit 1; fi
echo "內容檢查：Payload/PhotoSync.app/PhotoSync 存在，沒有 ._ 檔"
