#!/usr/bin/env bash
# seo-launchpad-restore.sh — run ON nc-ph-4291 (203.161.33.5), as the user that owns the app.
# Safe by default: reports only. Nothing is killed or started without a flag.
#
#   bash seo-launchpad-restore.sh              # diagnose only
#   bash seo-launchpad-restore.sh --restart-app
#   bash seo-launchpad-restore.sh --restart-tunnel
#   bash seo-launchpad-restore.sh --zip        # bundle the app for handoff
#
# Why: the Vercel proxy (seo-launchpad-eta.vercel.app) reads a tunnel URL from
# getclients4u-lab/seo-launchpad-tunnel/url.txt, last written 2026-10-20 15:09Z.
# That hostname is now NXDOMAIN, so :3400 and its cloudflared supervisor are both down.

set -uo pipefail

APP_PORT="${APP_PORT:-3400}"
GH_URL_TXT="https://raw.githubusercontent.com/getclients4u-lab/seo-launchpad-tunnel/main/url.txt"
RESTART_APP=0; RESTART_TUNNEL=0; DO_ZIP=0
for a in "$@"; do
  case "$a" in
    --restart-app) RESTART_APP=1 ;;
    --restart-tunnel) RESTART_TUNNEL=1 ;;
    --zip) DO_ZIP=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a"; exit 2 ;;
  esac
done

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  ✓ %s\n' "$*"; }
bad() { printf '  ✗ %s\n' "$*"; }
inf() { printf '    %s\n' "$*"; }

say "1 · Backend on 127.0.0.1:${APP_PORT}"
LISTEN=$(ss -ltnp 2>/dev/null | grep -E "[:.]${APP_PORT}\b" || true)
CODE=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "http://127.0.0.1:${APP_PORT}/" 2>/dev/null); CODE=${CODE:-000}
if [ -n "$LISTEN" ]; then
  ok "something listens on ${APP_PORT}"; inf "$LISTEN"
else
  bad "nothing listening on ${APP_PORT}"
fi
inf "curl 127.0.0.1:${APP_PORT}/ -> HTTP ${CODE}"

APP_DIR=""
PID=$(echo "$LISTEN" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)
if [ -n "${PID:-}" ]; then
  inf "process: $(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null | cut -c1-160)"
  APP_DIR=$(readlink -f "/proc/$PID/cwd" 2>/dev/null || true)
  [ -n "$APP_DIR" ] && inf "cwd:     $APP_DIR"
fi
if [ -z "$APP_DIR" ]; then
  # best-effort search for the app directory (single match only, never guesses)
  CAND=$(find "$HOME" /opt /srv /var/www -maxdepth 4 -name package.json -not -path '*/node_modules/*' 2>/dev/null \
         | xargs -r grep -l -i "launchpad" 2>/dev/null | xargs -r -n1 dirname | sort -u | head -5)
  if [ -n "$CAND" ]; then inf "candidate app dirs:"; echo "$CAND" | sed 's/^/      /'; fi
fi

if [ "$RESTART_APP" = "1" ]; then
  if [ -z "$APP_DIR" ] || [ ! -d "$APP_DIR" ]; then
    bad "--restart-app: no app directory identified — refusing to guess. Set APP_DIR=/path."
    [ -n "${APP_DIR:-}" ] || exit 3
  fi
  if [ -n "${PID:-}" ] && [ "$CODE" != "000" ]; then
    ok "app already answering — not restarting"
  else
    START=""
    [ -f "$APP_DIR/server.js" ]   && START="node server.js"
    [ -f "$APP_DIR/app.js" ]      && [ -z "$START" ] && START="node app.js"
    [ -f "$APP_DIR/index.js" ]    && [ -z "$START" ] && START="node index.js"
    if [ -z "$START" ] && [ -f "$APP_DIR/package.json" ]; then
      grep -q '"start"' "$APP_DIR/package.json" && START="npm start --silent"
    fi
    if [ -z "$START" ]; then bad "no obvious entrypoint in $APP_DIR (server.js/app.js/index.js/npm start)"; exit 3; fi
    inf "starting: cd $APP_DIR && $START"
    ( cd "$APP_DIR" && setsid nohup env PORT="$APP_PORT" bash -lc "$START" >"$HOME/launchpad-app.log" 2>&1 & )
    sleep 4
    NEW=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "http://127.0.0.1:${APP_PORT}/" 2>/dev/null); NEW=${NEW:-000}
    [ "$NEW" = "200" ] && ok "app is up (HTTP 200)" || bad "app still not answering (HTTP $NEW) — see ~/launchpad-app.log"
  fi
fi

say "2 · tunnel supervisor"
SUPS=$(pgrep -af "[t]unnel-supervisor" 2>/dev/null || true)
TUNS=$(pgrep -af "[c]loudflared" 2>/dev/null || true)
if [ -n "$SUPS" ]; then inf "supervisors:"; echo "$SUPS" | sed 's/^/      /'; else bad "no tunnel-supervisor running"; fi
if [ -n "$TUNS" ]; then inf "cloudflared:"; echo "$TUNS" | sed 's/^/      /'; else bad "no cloudflared running"; fi
SUP_COUNT=$( [ -n "$SUPS" ] && echo "$SUPS" | wc -l || echo 0 )
[ "$SUP_COUNT" -gt 1 ] && bad "$SUP_COUNT supervisors — that is the 2026-09-08 race. Keep exactly one."

if [ "$RESTART_TUNNEL" = "1" ]; then
  SUP_PATH=$( [ -n "$SUPS" ] && echo "$SUPS" | awk '{print $NF}' | head -1 || true )
  [ -z "$SUP_PATH" ] && SUP_PATH=$(find "$HOME" /opt /srv /var/www -maxdepth 5 -name 'tunnel-supervisor.sh' 2>/dev/null | head -1)
  if [ -z "$SUP_PATH" ]; then bad "tunnel-supervisor.sh not found — set SUP_PATH=/path/to/script"; exit 3; fi
  inf "stopping supervisors + their cloudflared children"
  pkill -f "tunnel-supervisor" 2>/dev/null; sleep 1
  pkill -f "cloudflared.*3400" 2>/dev/null || true
  sleep 1
  inf "starting ONE supervisor: $SUP_PATH"
  ( setsid nohup bash "$SUP_PATH" >"$HOME/tunnel-supervisor.log" 2>&1 & )
  ok "started — it should publish a fresh URL to GitHub within ~60s"
fi

say "3 · address book (what the Vercel proxy reads)"
NOW_URL=$(curl -s -m 10 "$GH_URL_TXT" | tr -d '\r\n' || true)
inf "url.txt: ${NOW_URL:-<unreadable>}"
if [ -n "$NOW_URL" ]; then
  HOST=${NOW_URL#https://}; HOST=${HOST%%/*}
  if getent hosts "$HOST" >/dev/null 2>&1; then
    ok "$HOST resolves"
    C2=$(curl -s -o /dev/null -m 10 -w "%{http_code}" "$NOW_URL/" 2>/dev/null); C2=${C2:-000}
    [ "$C2" = "200" ] && ok "tunnel answers HTTP 200 — the public URL is live again" || bad "tunnel answers HTTP $C2"
  else
    bad "$HOST does NOT resolve (NXDOMAIN) — that is why the site 502s"
  fi
fi
inf "last url.txt commit: https://github.com/getclients4u-lab/seo-launchpad-tunnel/commits/main"

if [ "$DO_ZIP" = "1" ]; then
  say "4 · bundle the app for handoff"
  if [ -z "$APP_DIR" ] || [ ! -d "$APP_DIR" ]; then bad "no app dir — nothing to zip"; exit 3; fi
  OUT="$HOME/launchpad-app-$(date +%F-%H%M).zip"
  ( cd "$(dirname "$APP_DIR")" && zip -qr "$OUT" "$(basename "$APP_DIR")" -x '*/node_modules/*' '*/.git/*' '*.log' )
  ok "wrote $OUT ($(du -h "$OUT" | cut -f1)) — send that file and the app can be hosted without any tunnel"
fi

say "5 · the one command that matters"
cat <<'EOS'
  # after --restart-app --restart-tunnel, from anywhere:
  curl -s -o /dev/null -w '%{http_code}\n' https://seo-launchpad-eta.vercel.app/
  # expect 200 (the proxy caches the URL for up to 60s)
EOS
