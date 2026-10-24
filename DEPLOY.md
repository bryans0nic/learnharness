# Deploying learnharness

Set up from ClaudeOS (Build or GitHub tab). Everything here is read from `.claudeos/deploy.json`.

| | |
|---|---|
| Platform | Raspberry Pi (systemd) |
| Port | 9792 (this machine only: `127.0.0.1`, shared on the tailnet) |
| Mode | dev (`next dev`; switch to `production` in the file to build and `next start` instead) |
| Check | `/` must answer with a status below 500 |

## Turn it on (once, from this folder, on `main`)

```
bash scripts/install-autodeploy-pi.sh
```

That starts the app at boot, restarts it when it crashes, checks `origin/main` every 2 minutes, and shares the port on Tailscale
(`tailscale serve --bg --tcp=9792 tcp://localhost:9792`). Open it from any device on your tailnet at `http://<this machine>:9792`.

## What an update does

1. Fast-forwards `main`, runs `npm ci` if the lockfile changed, builds (production mode) and runs `migrate` if set.
2. Restarts the app and waits up to 90 seconds for `/` to answer.
3. If any step fails, goes back to the previous commit, restarts it, and leaves the failed commit alone until `main` moves on.
   Database changes the failed version already made are not undone.

The last result is in `logs/deploy-status.json`; the log is `logs/deploy.log`.
