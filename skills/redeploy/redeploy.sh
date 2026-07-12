#!/usr/bin/env bash
# /redeploy — sync the T3 Code deploy checkout to an exact copy of origin/main,
# rebuild, and restart the prod service (t3code.service, fronted by Caddy on :7443).
#
# Run this from a T3 chat. The chat lives INSIDE t3code.service, so the chat's own
# session WILL drop when the service restarts. The restart is fired as a detached
# systemd unit so it completes regardless; results land in $STATUS_LOG.
set -euo pipefail

DEPLOY_DIR="${T3_DEPLOY_DIR:-/home/dgordon/projects/meta/t3code-v2}"
SERVICE="${T3_SERVICE:-t3code.service}"
LOOPBACK_URL="${T3_HEALTH_URL:-http://127.0.0.1:3773/}"
PUBLIC_URL="${T3_PUBLIC_URL:-https://15.204.108.12:7443/}"
STATUS_LOG="${T3_REDEPLOY_LOG:-/tmp/t3-redeploy-status.log}"

# --- guard: only run on the actual deploy host ---
if [ ! -e "$DEPLOY_DIR/.git" ]; then
  echo "redeploy: deploy dir '$DEPLOY_DIR' not found — this is not the T3 deploy host. Aborting." >&2
  exit 1
fi
if ! systemctl --user cat "$SERVICE" >/dev/null 2>&1; then
  echo "redeploy: user service '$SERVICE' not found — this is not the T3 deploy host. Aborting." >&2
  exit 1
fi

export PATH="$HOME/.local/share/mise/shims:$DEPLOY_DIR/node_modules/.bin:$PATH"
export CI=true

echo "==> Fetching origin and syncing $DEPLOY_DIR to a copy of origin/main"
git -C "$DEPLOY_DIR" fetch origin --quiet
TARGET_SHORT="$(git -C "$DEPLOY_DIR" rev-parse --short origin/main)"
TARGET_SUBJ="$(git -C "$DEPLOY_DIR" log -1 --format='%s' origin/main)"
git -C "$DEPLOY_DIR" checkout --detach --force origin/main
# Drop the throwaway 'deploy' label if it lingers — the deploy dir is now just a
# detached snapshot of origin/main, so there is no mystery branch to reason about.
git -C "$DEPLOY_DIR" branch -D deploy >/dev/null 2>&1 || true
echo "    now at $TARGET_SHORT — $TARGET_SUBJ"

echo "==> Installing dependencies"
( cd "$DEPLOY_DIR" && pnpm install --prefer-offline )

echo "==> Building"
( cd "$DEPLOY_DIR" && pnpm build )

echo "==> Build OK. Firing detached restart of $SERVICE"
echo "    (this chat's session will drop when the server restarts)"
UNIT="t3-redeploy-$(date +%s)"
systemd-run --user --collect --unit="$UNIT" bash -c "
  sleep 2
  systemctl --user restart $SERVICE
  for i in \$(seq 1 40); do
    code=\$(curl -s -o /dev/null -w '%{http_code}' '$LOOPBACK_URL' 2>/dev/null || echo 000)
    [ \"\$code\" = '200' ] && break
    sleep 1
  done
  {
    echo \"redeploy \$(date -Is)\"
    echo \"target=$TARGET_SHORT ($TARGET_SUBJ)\"
    echo \"service-active=\$(systemctl --user is-active $SERVICE)\"
    echo \"loopback-3773=\$(curl -s -o /dev/null -w '%{http_code}' '$LOOPBACK_URL' 2>/dev/null)\"
    echo \"public-7443=\$(curl -sk -o /dev/null -w '%{http_code}' '$PUBLIC_URL' 2>/dev/null)\"
    echo \"served-commit=\$(git -C '$DEPLOY_DIR' rev-parse --short HEAD)\"
  } > '$STATUS_LOG' 2>&1
"

echo
echo "Redeploy launched for $TARGET_SHORT ($TARGET_SUBJ)."
echo "The service restarts in ~2s; this chat will disconnect."
echo "Reconnect, then verify with:  cat $STATUS_LOG"
