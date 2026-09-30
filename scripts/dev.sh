#!/bin/bash
# 开发模式（make dev）：构建并启动开发版，日志直接输出到终端，改动后自动生效。
#
#   - Swift 代码 / Package.swift / Info.plist：保存后自动增量编译并重启；编译失败时旧进程继续运行
#   - 聊天面板（Resources/chat）和内置扩展（extensions）：直接从源码目录加载，保存后页面自动刷新，
#     只改 CSS 时就地替换样式、保留页面状态（见 Sources/Spotcat/Web/DevReload.swift）
#
# Ctrl+C 退出并关闭开发版。不依赖 fswatch 等外部工具。
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="build/Spotcat Dev.app"
STAMP="$(mktemp)"
PID=""

stop_app() {
  pkill -f "$APP/Contents/MacOS/Spotcat" 2>/dev/null
  while pgrep -f "$APP/Contents/MacOS/Spotcat" >/dev/null; do sleep 0.1; done
  PID=""
}

start_app() {
  SPOTCAT_SOURCE_ROOT="$ROOT" "$APP/Contents/MacOS/Spotcat" &
  PID=$!
}

build() {
  touch "$STAMP"
  echo "==> $(date +%H:%M:%S) building…"
  ./scripts/bundle.sh debug 2>&1 | grep -vE '^\[([0-9]+ ?/ ?[0-9]+|Planning)|replacing existing signature'
  return "${PIPESTATUS[0]}"
}

trap 'stop_app; rm -f "$STAMP"; exit 0' INT TERM

# 首次构建成功前不启动
until build; do
  echo "!! build failed, waiting for changes…"
  while [ -z "$(find Sources Package.swift Resources/Info.plist -newer "$STAMP" -print -quit)" ]; do sleep 0.5; done
done
stop_app
start_app
echo "==> Spotcat Dev running (Swift changes rebuild + restart; chat/extensions reload live). Ctrl+C to quit."

while true; do
  sleep 0.5
  [ -n "$(find Sources Package.swift Resources/Info.plist -newer "$STAMP" -print -quit)" ] || continue
  sleep 0.3 # 等编辑器把一批文件写完
  if build; then
    stop_app
    start_app
    echo "==> restarted"
  else
    echo "!! build failed, keeping the running app"
  fi
done
