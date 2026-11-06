#!/bin/sh
# Installs the latest Tadak release:
#   curl -fsSL https://raw.githubusercontent.com/E-JIWON/tadak/main/install.sh | sh
set -e
URL=${TADAK_ZIP:-https://github.com/E-JIWON/tadak/releases/latest/download/Tadak.zip}
DEST=${TADAK_DEST:-/Applications}
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]; then
    echo "Tadak은 macOS 14 이상이 필요해요." >&2; exit 1
fi
if ! mkdir -p "$DEST" 2>/dev/null || [ ! -w "$DEST" ]; then
    echo "$DEST 폴더에 설치할 권한이 없어요. 관리자 계정이 아니라면 명령 끝을 '| TADAK_DEST=\$HOME/Applications sh'로 바꿔 실행해 보세요." >&2; exit 1
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$DEST/Tadak.app.new"' EXIT
echo "Tadak 내려받는 중…"
curl -fsSL "$URL" -o "$TMP/Tadak.zip"
ditto -x -k "$TMP/Tadak.zip" "$TMP"
[ -x "$TMP/Tadak.app/Contents/MacOS/Tadak" ] || { echo "내려받은 파일에 Tadak 앱이 없어요." >&2; exit 1; }
ditto "$TMP/Tadak.app" "$DEST/Tadak.app.new"  # copy first: a failed install must leave the old app in place
pkill -x Tadak || true  # quitting by Apple Event would ask for Automation permission; refused, two copies end up running
sleep 1
rm -rf "$DEST/Tadak.app"
mv "$DEST/Tadak.app.new" "$DEST/Tadak.app"
open "$DEST/Tadak.app"
echo "설치했어요. 메뉴 막대의 '탁' 아이콘을 눌러 보세요."
echo "처음 설치했다면 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 Tadak을 켜 주세요."
echo "업데이트했다면 이미 켜져 있어도 껐다 다시 켜 주세요."
