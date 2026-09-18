#!/usr/bin/env bash
# SafeProfiles tunnel worker - plain text, nothing hidden.
# Runs a password-protected SOCKS5 server locally and exposes it via
# pinggy.io. Publishes the public address to endpoint.json in this repo.
set -u
[ -z "$SOCKS_USER" ] && { echo "SOCKS_USER secret missing"; exit 1; }
[ -z "$SOCKS_PASS" ] && { echo "SOCKS_PASS secret missing"; exit 1; }

EP_FILE="endpoint.json"
LAST=""

microsocks -i 127.0.0.1 -p 1080 "$SOCKS_USER" "$SOCKS_PASS" &
SOCKS_PID=$!
trap 'kill $SOCKS_PID 2>/dev/null' EXIT

git config user.name  "safeprofiles-bot" 2>/dev/null || true
git config user.email "safeprofiles-bot@users.noreply.github.com" 2>/dev/null || true

publish() {
  local addr="$1" host_port
  [ "$addr" = "$LAST" ] && return 0
  host_port="${addr#tcp://}"
  printf '{"endpoint":"%s","updated":"%s"}\n' "$host_port" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$EP_FILE"
  git add "$EP_FILE" 2>/dev/null || true
  git commit -qm "endpoint: $host_port" 2>/dev/null || true
  git pull --rebase -q 2>/dev/null || true
  if git push -q 2>/dev/null; then
    LAST="$addr"
    echo "published endpoint: $host_port"
  else
    LAST=""
    echo "WARN: push failed, will retry on next reconnect"
  fi
}

while kill -0 "$SOCKS_PID" 2>/dev/null; do
  rm -f tunnel.log
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=25 -o ServerAliveCountMax=4 \
      -p 443 -R 0:localhost:1080 tcp@a.pinggy.io >tunnel.log 2>&1 &
  SSH_PID=$!
  ADDR=""
  for _ in $(seq 1 25); do
    kill -0 "$SSH_PID" 2>/dev/null || break
    ADDR=$(grep -oE 'tcp://[A-Za-z0-9.-]+:[0-9]+' tunnel.log 2>/dev/null | head -n1)
    if [ -z "$ADDR" ]; then
      H=$(grep -oE '[A-Za-z0-9-]+\.tcp\.pinggy\.io:[0-9]+' tunnel.log 2>/dev/null | head -n1)
      [ -n "$H" ] && ADDR="tcp://$H"
    fi
    [ -n "$ADDR" ] && break
    sleep 1
  done
  if [ -n "$ADDR" ]; then
    publish "$ADDR"
    wait "$SSH_PID" 2>/dev/null || true   # tunnel dropped -> reconnect
  else
    kill "$SSH_PID" 2>/dev/null || true
    sleep 20
  fi
done
echo "socks server exited"
