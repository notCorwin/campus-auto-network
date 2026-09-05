#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"

LABEL="com.nowaywastaken.csustautologin"
DOMAIN="gui/$(id -u)"
BINARY_DEST="$HOME/.local/bin/csust-auto-login"
DATA_DIR="$HOME/Library/Application Support/csust-auto-login"
LOG_DIR="$HOME/Library/Logs/csust-auto-login"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

ACTION="install"
if [[ $# -gt 1 ]]; then echo "用法：bash install.sh [install|uninstall]" >&2; exit 2; fi
if [[ $# -eq 1 ]]; then ACTION="$1"; fi
case "$ACTION" in
  uninstall)
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      launchctl bootout "$DOMAIN/$LABEL"
    fi
    rm -f "$PLIST_DEST" "$BINARY_DEST"
    echo "已卸载后台任务和安装的程序；账号配置与日志已保留，可重新安装恢复。"
    exit 0
    ;;
  install) ;;
  *) echo "用法：bash install.sh [install|uninstall]" >&2; exit 2 ;;
esac

echo "正在编译校园网自动登录..."
cargo build --release --locked
install -d -m 700 "$DATA_DIR" "$LOG_DIR"
mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
if [[ ! -f "$DATA_DIR/config.json" ]]; then
  ./target/release/csust-auto-login configure
fi

STAGING_DIR="$(mktemp -d "$DATA_DIR/install.XXXXXX")"
PREVIOUS_LOADED=false
CHANGED=false
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then PREVIOUS_LOADED=true; fi

cleanup() {
  local result=$?
  if [[ $result -ne 0 && "$CHANGED" == true ]]; then
    echo "安装失败，恢复此前的程序与后台配置..." >&2
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    if [[ -f "$STAGING_DIR/previous-binary" ]]; then
      cp -p "$STAGING_DIR/previous-binary" "$BINARY_DEST"
    else
      rm -f "$BINARY_DEST"
    fi
    if [[ -f "$STAGING_DIR/previous.plist" ]]; then
      cp -p "$STAGING_DIR/previous.plist" "$PLIST_DEST"
      if [[ "$PREVIOUS_LOADED" == true ]]; then
        launchctl bootstrap "$DOMAIN" "$PLIST_DEST" || true
      fi
    else
      rm -f "$PLIST_DEST"
    fi
  fi
  rm -f "$STAGING_DIR/binary" "$STAGING_DIR/service.plist" "$STAGING_DIR/previous-binary" "$STAGING_DIR/previous.plist"
  rmdir "$STAGING_DIR"
  return "$result"
}
trap cleanup EXIT

if [[ -e "$BINARY_DEST" ]]; then cp -p "$BINARY_DEST" "$STAGING_DIR/previous-binary"; fi
if [[ -e "$PLIST_DEST" ]]; then cp -p "$PLIST_DEST" "$STAGING_DIR/previous.plist"; fi
install -m 755 ./target/release/csust-auto-login "$STAGING_DIR/binary"
cp "./$LABEL.plist" "$STAGING_DIR/service.plist"
plutil -replace Program -string "$BINARY_DEST" "$STAGING_DIR/service.plist"
plutil -insert WorkingDirectory -string "$DATA_DIR" "$STAGING_DIR/service.plist"
plutil -insert StandardErrorPath -string "$LOG_DIR/launchd.stderr.log" "$STAGING_DIR/service.plist"
plutil -lint "$STAGING_DIR/service.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Program' "$STAGING_DIR/service.plist")" == "$BINARY_DEST" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$STAGING_DIR/service.plist")" == run ]]

if [[ "$PREVIOUS_LOADED" == true ]]; then launchctl bootout "$DOMAIN/$LABEL"; fi
CHANGED=true
mv -f "$STAGING_DIR/binary" "$BINARY_DEST"
mv -f "$STAGING_DIR/service.plist" "$PLIST_DEST"
launchctl enable "$DOMAIN/$LABEL"
launchctl bootstrap "$DOMAIN" "$PLIST_DEST"
CHANGED=false
echo "安装完成。每次登录 macOS 后自动运行，每 15 秒检查一次校园网。"
echo "配置向导：csust-auto-login configure"
echo "立即登录：csust-auto-login login"
echo "查看状态：csust-auto-login status"
echo "连接诊断：csust-auto-login doctor"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "当前 PATH 不含 ~/.local/bin，请使用完整路径：$BINARY_DEST" ;;
esac
