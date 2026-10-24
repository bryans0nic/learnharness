#!/usr/bin/env bash
# Sets up an app made from ClaudeOS's Build or GitHub tab on a Pi: a systemd service that runs it (starts at boot,
# restarts when it crashes) and a cron job that runs scripts/deploy-pi.sh every 2 minutes, so a merged PR is live within
# a couple of minutes. Run once from the app's checkout (on main). Settings come from .claudeos/deploy.json. ClaudeOS
# itself is set up by scripts/install-pi.sh instead.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
[ -f .claudeos/deploy.json ] || { echo "No .claudeos/deploy.json here; this script is for apps made from ClaudeOS."; exit 1; }
cfg() { node -e 'try{const v=JSON.parse(require("fs").readFileSync(".claudeos/deploy.json","utf8"))[process.argv[1]];if(v!=null)process.stdout.write(String(v))}catch{}' "$1"; }
NAME="$(cfg name)"
PORT="$(cfg port)"
[ -n "$NAME" ] && [ -n "$PORT" ] || { echo ".claudeos/deploy.json needs a name and a port."; exit 1; }
mkdir -p logs

if [ -f pnpm-lock.yaml ]; then
  PACKAGE_MANAGER="pnpm"
  pnpm install --frozen-lockfile
else
  PACKAGE_MANAGER="npm"
  npm ci --no-audit --no-fund
fi
START="$(cfg start)"; START="${START:-$PACKAGE_MANAGER start}"
BUILD="$(cfg build)"; BUILD="${BUILD:-$PACKAGE_MANAGER run build}"
bash -c "$BUILD"
sudo tee "/etc/systemd/system/$NAME.service" >/dev/null <<UNIT
[Unit]
Description=$NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$DIR
Environment=NODE_ENV=production
Environment=PORT=$PORT
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/env bash -c '$START'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now "$NAME"

( crontab -l 2>/dev/null | grep -v "$DIR/scripts/deploy-pi.sh" || true
  echo "*/2 * * * * flock -n /tmp/$NAME-deploy.lock $DIR/scripts/deploy-pi.sh >>$DIR/logs/deploy.log 2>&1" ) | crontab -
echo "Auto-deploy is on: every 2 minutes, merged PRs on main go live here. Log: $DIR/logs/deploy.log"

if [ "$(cfg listen)" = lan ]; then
  # Bound to 0.0.0.0: the home network and the tailnet both reach it at this port, and `tailscale serve` would clash with it.
  command -v tailscale >/dev/null && sudo tailscale serve --tcp="$PORT" off 2>/dev/null || true
  echo "Reachable on the home network and the tailnet at port $PORT."
elif command -v tailscale >/dev/null; then
  # Any device on your tailnet can then open http://<this Pi's name>:$PORT
  sudo tailscale serve --bg --tcp="$PORT" "tcp://localhost:$PORT" && echo "Shared on Tailscale at port $PORT."
else
  echo "Tailscale isn't installed, so it isn't shared. Later: sudo tailscale serve --bg --tcp=$PORT tcp://localhost:$PORT"
fi
