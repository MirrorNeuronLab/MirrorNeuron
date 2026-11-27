#!/usr/bin/env bash
set -eu
export PATH="$PATH:/opt/podman/bin:/opt/homebrew/bin:/usr/local/bin"
if [ -n "${CONTAINER_HOST:-}${CONTAINER_CONNECTION:-}" ]; then
  exec podman info >/dev/null
fi
case "$(uname -s)" in
  Darwin)
    if ! podman info >/dev/null 2>&1; then podman machine start; fi
    ;;
  Linux)
    socket="${PODMAN_HOST_SOCKET:-$(podman info --format '{{.Host.RemoteSocket.Path}}')}"
    if [ ! -S "${socket#unix://}" ]; then
      if [ "$(id -u)" = 0 ]; then systemctl start podman.socket
      else systemctl --user start podman.socket
      fi
    fi
    ;;
esac
podman info >/dev/null
