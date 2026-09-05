#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"

LABEL="com.nowaywastaken.csustautologin"
DOMAIN="gui/$(id -u)"
APP_NAME="CampusAutoLogin"
APP_SOURCE="$(pwd)/target/CampusAutoLogin.app"
APP_DEST="$HOME/Applications/$APP_NAME.app"
DATA_DIR="$HOME/Library/Application Support/csust-auto-login"
OLD_BINARY="$HOME/.local/bin/csust-auto-login"
OLD_MONITOR="$HOME/.local/bin/csust-auto-login-monitor"
OLD_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

ACTION="install"
if [[ $# -gt 1 ]]; then
  echo "用法：bash install.sh [install|uninstall]" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then ACTION="$1"; fi

old_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

stop_old_service() {
  if old_loaded; then launchctl bootout "$DOMAIN/$LABEL"; fi
}

quit_app() {
  if [[ -x "$APP_DEST/Contents/MacOS/CampusAutoLogin" ]]; then
    "$APP_DEST/Contents/MacOS/CampusAutoLogin" --unregister >/dev/null 2>&1 || true
  fi
  osascript -e "tell application id \"$LABEL\" to quit" >/dev/null 2>&1 || true
}

case "$ACTION" in
  uninstall)
    stop_old_service
    quit_app
    rm -rf "$APP_DEST"
    rm -f "$OLD_PLIST" "$OLD_BINARY" "$OLD_MONITOR"
    echo "已卸载 App 和旧后台任务；配置与日志已保留。"
    exit 0
    ;;
  install) ;;
  *)
    echo "用法：bash install.sh [install|uninstall]" >&2
    exit 2
    ;;
esac

echo "正在构建校园网自动登录 App..."
bash build.sh
[[ -x "$APP_SOURCE/Contents/MacOS/CampusAutoLogin" ]]

install -d -m 700 "$DATA_DIR" "$HOME/Applications"
STAGING_DIR="$(mktemp -d "$DATA_DIR/install.XXXXXX")"
PREVIOUS_LOADED=false
CHANGED=false

if old_loaded; then PREVIOUS_LOADED=true; fi

cleanup() {
  local result=$?
  if [[ $result -ne 0 && "$CHANGED" == true ]]; then
    echo "安装失败，恢复此前的后台配置..." >&2
    quit_app
    rm -rf "$APP_DEST"
    if [[ -d "$STAGING_DIR/previous-app" ]]; then
      ditto "$STAGING_DIR/previous-app" "$APP_DEST"
    fi
    if [[ -f "$STAGING_DIR/previous-binary" ]]; then
      install -m 755 "$STAGING_DIR/previous-binary" "$OLD_BINARY"
    fi
    if [[ -f "$STAGING_DIR/previous-monitor" ]]; then
      install -m 755 "$STAGING_DIR/previous-monitor" "$OLD_MONITOR"
    fi
    if [[ -f "$STAGING_DIR/previous.plist" ]]; then
      install -m 600 "$STAGING_DIR/previous.plist" "$OLD_PLIST"
      if [[ "$PREVIOUS_LOADED" == true ]]; then
        launchctl bootstrap "$DOMAIN" "$OLD_PLIST" || true
      fi
    fi
  fi
  rm -rf "$STAGING_DIR"
  return "$result"
}
trap cleanup EXIT

if [[ -d "$APP_DEST" ]]; then ditto "$APP_DEST" "$STAGING_DIR/previous-app"; fi
if [[ -f "$OLD_BINARY" ]]; then cp -p "$OLD_BINARY" "$STAGING_DIR/previous-binary"; fi
if [[ -f "$OLD_MONITOR" ]]; then cp -p "$OLD_MONITOR" "$STAGING_DIR/previous-monitor"; fi
if [[ -f "$OLD_PLIST" ]]; then cp -p "$OLD_PLIST" "$STAGING_DIR/previous.plist"; fi

quit_app
sleep 0.5
stop_old_service
rm -rf "$APP_DEST"
ditto "$APP_SOURCE" "$APP_DEST"
CHANGED=true

open "$APP_DEST"
started=false
for _ in {1..10}; do
  if pgrep -f "$APP_DEST/Contents/MacOS/CampusAutoLogin" >/dev/null 2>&1; then
    started=true
    break
  fi
  sleep 0.5
done
if [[ "$started" != true ]]; then
  echo "App 未能启动，请检查系统日志。" >&2
  exit 1
fi

rm -f "$OLD_PLIST" "$OLD_BINARY" "$OLD_MONITOR"
CHANGED=false
echo "安装完成。App 已启动，网络事件触发、每 60 秒兜底检查一次。"
echo "配置：打开菜单栏的“校园网自动登录” → 设置…"
echo "卸载：bash install.sh uninstall（配置与日志保留）"
