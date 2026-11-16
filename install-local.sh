#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing wu-listener (local Mac)..."

WU_CLI_PATH="$(command -v wu || true)"
if [[ -z "$WU_CLI_PATH" || ! -x "$WU_CLI_PATH" ]]; then
  for candidate in "$HOME/.local/bin/wu" "/usr/local/bin/wu" "/Applications/Wu.app/Contents/MacOS/cli"; do
    if [[ -x "$candidate" ]]; then
      WU_CLI_PATH="$candidate"
      break
    fi
  done
fi
if [[ -z "$WU_CLI_PATH" || ! -x "$WU_CLI_PATH" ]]; then
  echo "Could not find Wu's CLI. Install it from Wu → Install CLI, then rerun this script." >&2
  exit 1
fi

mkdir -p "$HOME/.local/bin"

cp "$SCRIPT_DIR/wu-listener" "$HOME/.local/bin/wu-listener"
chmod +x "$HOME/.local/bin/wu-listener"

# Install launchd service
mkdir -p "$HOME/Library/LaunchAgents"
WU_CLI_PATH="$WU_CLI_PATH" HOME="$HOME" TEMPLATE_PATH="$SCRIPT_DIR/com.wu.remote-listener.plist" \
  OUTPUT_PATH="$HOME/Library/LaunchAgents/com.wu.remote-listener.plist" \
  /usr/bin/python3 - <<'PY'
import os
import plistlib

with open(os.environ["TEMPLATE_PATH"], "rb") as template:
    plist_data = plistlib.load(template)

plist_data["ProgramArguments"][1] = os.path.join(os.environ["HOME"], ".local/bin/wu-listener")
plist_data["EnvironmentVariables"]["WU_CLI_PATH"] = os.environ["WU_CLI_PATH"]

with open(os.environ["OUTPUT_PATH"], "wb") as output:
    plistlib.dump(plist_data, output)
PY

# Stop the old service label if this machine had the original Zed version installed.
launchctl bootout "gui/$(id -u)/com.zed.remote-listener" 2>/dev/null || true
# Load/reload the Wu service.
launchctl bootout "gui/$(id -u)/com.wu.remote-listener" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.wu.remote-listener.plist"

echo "==> wu-listener is running."
echo ""
echo "Next steps:"
echo "  1. Add 'RemoteForward 7682 127.0.0.1:7682' to your SSH host in ~/.ssh/config"
echo "  2. Install wu-remote on your server (copy wu-remote to ~/.local/bin/wu)"
echo "  3. Set WU_SSH_HOST on the server to your SSH config alias"
