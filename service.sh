#!/usr/bin/env bash
set -e

SERVICE_NAME="EbookAudioService"
NSSM_PATH="C:/EbookAutomation/nssm.exe"
if [ ! -f "$NSSM_PATH" ]; then
    NSSM_PATH="C:/Program Files/nssm/nssm.exe"
fi

action="${1:-}"

if [ -z "$action" ]; then
    echo "========================================"
    echo "   EbookAudioService Manager (Bash)"
    echo "========================================"
    echo "Usage: ./service.sh {start|stop|restart|status|logs}"
    exit 1
fi

case "$action" in
    start)
        echo "[*] Starting $SERVICE_NAME..."
        if [ -f "$NSSM_PATH" ]; then
            "$NSSM_PATH" start "$SERVICE_NAME"
        else
            net start "$SERVICE_NAME"
        fi
        ;;
    stop)
        echo "[*] Stopping $SERVICE_NAME..."
        if [ -f "$NSSM_PATH" ]; then
            "$NSSM_PATH" stop "$SERVICE_NAME"
        else
            net stop "$SERVICE_NAME"
        fi
        ;;
    restart)
        echo "[*] Restarting $SERVICE_NAME..."
        if [ -f "$NSSM_PATH" ]; then
            "$NSSM_PATH" stop "$SERVICE_NAME" >/dev/null 2>&1 || true
            "$NSSM_PATH" start "$SERVICE_NAME"
        else
            net stop "$SERVICE_NAME" >/dev/null 2>&1 || true
            net start "$SERVICE_NAME"
        fi
        ;;
    status)
        echo "[*] Checking status for $SERVICE_NAME..."
        if [ -f "$NSSM_PATH" ]; then
            "$NSSM_PATH" status "$SERVICE_NAME"
        else
            sc query "$SERVICE_NAME"
        fi
        ;;
    logs)
        echo "[*] Displaying recent service logs..."
        if [ -f "service_out.log" ]; then
            echo "=== STDOUT LOG ==="
            tail -n 30 service_out.log
        else
            echo "[!] service_out.log not found."
        fi
        if [ -f "service_err.log" ]; then
            echo "=== STDERR LOG ==="
            tail -n 30 service_err.log
        else
            echo "[!] service_err.log not found."
        fi
        ;;
    *)
        echo "[!] Invalid option: $action"
        echo "Usage: ./service.sh {start|stop|restart|status|logs}"
        exit 1
        ;;
esac