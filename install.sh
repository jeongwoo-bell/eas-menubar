#!/bin/bash
# EAS Builds 설치 스크립트
#   curl -fsSL https://raw.githubusercontent.com/jeongwoo-bell/eas-menubar/main/install.sh | bash
# 저장소를 clone한 경우: ./install.sh
set -euo pipefail

REPO="${EAS_BUILDS_REPO:-jeongwoo-bell/eas-menubar}"   # ← 배포할 GitHub 저장소로 바꾸기
BRANCH="${EAS_BUILDS_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"
PLUGIN_FILE="eas-builds.30s.sh"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; red=$'\033[31m'; reset=$'\033[0m'
ok()   { echo "${green}✔${reset} $*"; }
die()  { echo "${red}✖${reset} $*" >&2; exit 1; }

echo
echo "  ${bold}EAS Builds 설치${reset}"
echo "  ${dim}────────────────────────────────────────────${reset}"
echo

[ "$(uname -s)" = "Darwin" ] || die "macOS에서만 쓸 수 있어요."

# 1. SwiftBar
if [ -d "/Applications/SwiftBar.app" ] || [ -d "$HOME/Applications/SwiftBar.app" ]; then
  ok "SwiftBar 설치돼 있음"
elif command -v brew >/dev/null 2>&1; then
  echo "SwiftBar 설치 중…"
  brew install --cask swiftbar >/dev/null
  ok "SwiftBar 설치 완료"
else
  die "SwiftBar가 필요해요. https://github.com/swiftbar/SwiftBar/releases 에서 설치한 뒤 다시 실행해 주세요."
fi

# 2. 플러그인 폴더 (이미 정해져 있으면 그대로, 없으면 ~/SwiftBarPlugins)
PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
PLUGIN_DIR="${PLUGIN_DIR/#\~/$HOME}"
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR="$HOME/SwiftBarPlugins"
  defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR"
fi
mkdir -p "$PLUGIN_DIR"
ok "플러그인 폴더: ${PLUGIN_DIR/#$HOME/\~}"

# 3. 플러그인 파일 (clone한 폴더에서 실행했으면 그 파일, 아니면 GitHub에서 받기)
#    curl | bash 로 실행하면 BASH_SOURCE가 파일이 아니므로 현재 폴더의 파일을 잘못 집지 않도록 확인
SRC_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
TARGET="$PLUGIN_DIR/$PLUGIN_FILE"
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/$PLUGIN_FILE" ]; then
  cp "$SRC_DIR/$PLUGIN_FILE" "$TARGET"
else
  # 공개 저장소면 raw URL, 비공개면 gh 인증으로 받기 (실패해도 기존 파일은 그대로)
  if curl -fsSL "$RAW/$PLUGIN_FILE" -o "$TARGET.tmp" 2>/dev/null; then
    :
  elif command -v gh >/dev/null 2>&1 && gh api "repos/$REPO/contents/$PLUGIN_FILE?ref=$BRANCH" \
         -H "Accept: application/vnd.github.raw" > "$TARGET.tmp" 2>/dev/null; then
    :
  else
    rm -f "$TARGET.tmp"
    die "플러그인을 받지 못했어요 ($REPO). gh auth login 후 다시 실행하거나, 저장소를 clone해서 ./install.sh 를 실행해 주세요."
  fi
  mv "$TARGET.tmp" "$TARGET"
fi
chmod +x "$TARGET"
rm -rf "$HOME/.cache/swiftbar-eas"   # v1 캐시 정리
ok "플러그인 설치: ${TARGET/#$HOME/\~}"

# 4. 터미널 명령 eas-builds
BIN_DIR=""
for d in /opt/homebrew/bin /usr/local/bin; do
  if [ -d "$d" ] && [ -w "$d" ]; then BIN_DIR="$d"; break; fi
done
if [ -z "$BIN_DIR" ]; then BIN_DIR="$HOME/.local/bin"; mkdir -p "$BIN_DIR"; fi
cat > "$BIN_DIR/eas-builds" <<EOF
#!/bin/bash
# EAS_BUILDS_SHIM — eas-builds uninstall 로 지워짐
exec "$TARGET" "\$@"
EOF
chmod +x "$BIN_DIR/eas-builds"
ok "명령어 설치: eas-builds"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "${dim}  $BIN_DIR 가 PATH에 없어요. ~/.zshrc 에 추가하세요: export PATH=\"$BIN_DIR:\$PATH\"${reset}" ;;
esac

# 5. SwiftBar 실행
pgrep -x SwiftBar >/dev/null 2>&1 || open -a SwiftBar
ok "SwiftBar 실행"

# 6. 설정 마법사 (로그인 + 앱 선택)
if [ "${EAS_BUILDS_SKIP_SETUP:-0}" != "1" ]; then
  if (exec </dev/tty) 2>/dev/null; then
    "$TARGET" setup </dev/tty
  else
    echo
    echo "  키보드 입력을 받을 수 없어 설정 마법사를 건너뛰었어요. 터미널에서 실행하세요: ${bold}eas-builds setup${reset}"
  fi
fi
