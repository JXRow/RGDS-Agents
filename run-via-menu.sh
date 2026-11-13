#!/bin/sh
# 按掌机菜单 (muos2.bin) 选中 APPS 条目时的真实流程启动 RGDS-Agents：
#   写 /tmp/.next → chmod 777 → cpu_setting.sh deflt → SIGINT 让 muos2.bin 走正常退出 (exit 0)
#   → dmenu_ln 执行 sh /tmp/.next；app 退出后 loadapp.sh 的循环自动拉起菜单。
# muos2.bin 退出后才会释放 ALSA 播放设备和手柄 event3，所以 app 才能出声、独占按键。
# 绝不要 kill -9：muos2.bin 非 0 退出时 dmenu_ln 只会 sleep 30，不会执行 /tmp/.next。
#
# 用法（在掌机上）: run-via-menu.sh [app 参数...]     例: run-via-menu.sh --selftest
# 从电脑:          ssh rgds /mnt/mmc/Roms/APPS/RGDS-Agents/run-via-menu.sh

APP_SH="$(cd "$(dirname "$0")/.." && pwd)/RGDS-Agents.sh"
LOVE_BIN="$(cd "$(dirname "$0")" && pwd)/bin/love"

[ -x "$APP_SH" ] || { echo "!! 找不到启动脚本 $APP_SH" >&2; exit 1; }

FRONTEND="$(pidof muos2.bin)"
if [ -z "$FRONTEND" ]; then
    echo "!! muos2.bin 没在运行（可能已有其他 app 在前台），请先退出当前 app 回到菜单" >&2
    exit 1
fi

printf '"%s"  %s\n' "$APP_SH" "$*" > /tmp/.next
chmod 777 /tmp/.next
/mnt/vendor/ctrl/cpu_setting.sh deflt
kill -INT "$FRONTEND"

i=0
while [ $i -lt 20 ]; do
    PID="$(pgrep -f "^$LOVE_BIN" | head -n 1)"
    if [ -n "$PID" ]; then
        echo ">> 已启动: love PID $PID（日志 /tmp/RGDS-Agents.log）"
        exit 0
    fi
    sleep 0.5
    i=$((i + 1))
done
echo "!! 10 秒内没看到 love 进程；查看 /tmp/RGDS-Agents.log" >&2
exit 1
