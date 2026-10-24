#!/usr/bin/env bash
# Deploys merged PRs to this Pi: when origin/main has moved, fast-forward this checkout, install packages if the
# lockfile changed, rebuild, run migrations and restart the service, then check that it answers. If any step fails the
# checkout goes back to the previous commit and the service is rebuilt and restarted on it; that commit is not tried
# again until main moves on. Run every 2 minutes by cron (installed by scripts/install-pi.sh or
# scripts/install-autodeploy-pi.sh, under flock so a slow build never overlaps the next run); safe to run by hand.
# Output goes to logs/deploy.log, the last result to logs/deploy-status.json.
#
# Settings come from .claudeos/deploy.json (see docs/deploy.md): name (the systemd service), port, build, migrate,
# health. ClaudeOS itself has none and uses the defaults below.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
mkdir -p logs
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
cfg() { node -e 'try{const v=JSON.parse(require("fs").readFileSync(".claudeos/deploy.json","utf8"))[process.argv[1]];if(v!=null)process.stdout.write(String(v))}catch{}' "$1"; }

SERVICE="$(cfg name)"; SERVICE="${SERVICE:-claudeos}"
PORT="${PORT:-$(cfg port)}"; PORT="${PORT:-3000}"
BUILD_CMD="$(cfg build)"; BUILD_CMD="${BUILD_CMD:-npm run build}"
MIGRATE_CMD="$(cfg migrate)" # none by default: ClaudeOS migrates when it starts
HEALTH="$(cfg health)"; HEALTH="${HEALTH:-/}"

# Any answer below 500 within 90 seconds counts as up (a login redirect is fine).
healthy() {
  local code
  for _ in $(seq 45); do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT$HEALTH" || true)"
    if [ "${code:-000}" != 000 ] && [ "$code" -lt 500 ]; then return 0; fi
    sleep 2
  done
  return 1
}
# result, commit, previous, detail → logs/deploy-status.json (shown in ClaudeOS under Settings → Changelog)
status() {
  node -e 'require("fs").writeFileSync("logs/deploy-status.json",JSON.stringify({at:new Date().toISOString(),result:process.argv[1],commit:process.argv[2],previous:process.argv[3],detail:process.argv[4]})+"\n")' "$@"
}

[ "$(git branch --show-current)" = main ] || exit 0 # someone is working on another branch here
GIT_TERMINAL_PROMPT=0 git fetch --quiet origin main
OLD="$(git rev-parse HEAD)"
NEW="$(git rev-parse origin/main)"
[ "$OLD" != "$NEW" ] || exit 0
[ "$NEW" != "$(cat logs/deploy-failed 2>/dev/null || true)" ] || exit 0 # this commit already failed; wait for main to move

# Same as deploy-mac.sh: local copies identical to what main now has would block the fast-forward; drop them.
git status --porcelain --untracked-files=all | while IFS= read -r line; do
  path="${line:3}"
  [ -f "$path" ] || continue
  [ "$(git rev-parse -q --verify "$NEW:$path" 2>/dev/null)" = "$(git hash-object "$path")" ] || continue
  if [ "${line:0:2}" = "??" ]; then rm -- "$path"; else git checkout --quiet HEAD -- "$path"; fi
  log "dropped local copy of $path (same as main)"
done

if ! git merge --ff-only --quiet "$NEW"; then
  log "can't deploy $(git rev-parse --short "$NEW"): local changes or commits are in the way (see git status)"
  status failed "$(git rev-parse --short "$NEW")" "$(git rev-parse --short "$OLD")" "local changes or commits are in the way"
  exit 1
fi
log "deploying $(git rev-parse --short "$OLD")..$(git rev-parse --short "$NEW"): $(git log -1 --format=%s "$NEW")"

# Installs packages with whichever lockfile the project has (pnpm or npm).
install_deps() {
  if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile; else npm ci --no-audit --no-fund; fi
}

# Puts the previous commit back, rebuilds it and restarts the service. Database changes the new version already made are not undone.
fail() {
  log "$1; going back to $(git rev-parse --short "$OLD")"
  echo "$NEW" > logs/deploy-failed
  status failed "$(git rev-parse --short "$NEW")" "$(git rev-parse --short "$OLD")" "$1"
  if git reset --keep --quiet "$OLD"; then
    if ! git diff --quiet "$NEW" "$OLD" -- package-lock.json pnpm-lock.yaml; then install_deps || true; fi
    bash -c "$BUILD_CMD" || true
    sudo -n systemctl restart "$SERVICE" || true
  else
    log "couldn't go back to $(git rev-parse --short "$OLD"): local changes are in the way (see git status)"
  fi
  exit 1
}

if ! git diff --quiet "$OLD" "$NEW" -- package-lock.json pnpm-lock.yaml; then
  log "packages changed, installing"
  install_deps || fail "the package install failed"
fi
# ponytail: the build replaces the running build in place, so a broken build can leave the old one half-written until the rollback rebuilds it.
bash -c "$BUILD_CMD" || fail "the build failed"
if [ -n "$MIGRATE_CMD" ]; then
  bash -c "$MIGRATE_CMD" || fail "the migration failed"
fi

sudo -n systemctl restart "$SERVICE" || fail "couldn't restart $SERVICE"
healthy || fail "the new version didn't answer on port $PORT"

node scripts/record-deploy.mjs record "$OLD" "$NEW" || log "couldn't save the changelog entry"
rm -f logs/deploy-failed
status ok "$(git rev-parse --short "$NEW")" "$(git rev-parse --short "$OLD")" "$(git log -1 --format=%s "$NEW")"
log "deployed $(git rev-parse --short "$NEW") and restarted $SERVICE"
