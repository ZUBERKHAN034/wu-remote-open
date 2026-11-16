# Wu Remote Open (`wu .` over SSH)

Opens a Wu remote project from a remote SSH session, similar to `code .` with VS Code.

Built on top of Wu's native remote SSH support, which accepts `wu ssh://host/path` from the local CLI. This bridges the gap so you can run `wu .` from the remote side too.

## How it works

```
You (SSH'd into my-server)
  │
  │  wu .
  │
  ▼
~/.local/bin/wu (on my-server)
  │  Sends "my-server:/current/dir" to localhost:7682
  │
  ▼
SSH Reverse Tunnel (RemoteForward 7682)
  │  Forwards remote:7682 → local Mac:7682
  │
  ▼
~/.local/bin/wu-listener (on Mac, launchd service)
  │  Receives request, runs: wu ssh://my-server/current/dir
  │
  ▼
Wu opens with a remote SSH project at that directory
```

## Usage

From an SSH session on your remote server:

```bash
wu .           # open current directory in Wu
wu /some/path  # open specific path in Wu
wu             # same as wu .
```

## All files

### Local Mac

#### 1. `~/.local/bin/wu-listener`

Python TCP server. Listens on port 7682 for NUL-separated host and directory fields, then opens Wu remote projects.

```python
#!/usr/bin/env python3
"""Listener that opens Wu remote projects from SSH sessions.

Runs on the local Mac. Remote machines send requests via SSH reverse
port forwarding to open a Wu remote project at a specific directory.

Protocol: NUL-separated UTF-8 host and absolute directory fields over TCP.
"""

import socket
import subprocess
import signal
import sys
import os
from urllib.parse import quote

PORT = 7682
MAX_REQUEST_SIZE = 16384


def handle_request(data):
    fields = data.split(b"\0")
    if len(fields) != 3 or fields[2] != b"":
        raise ValueError("request must contain NUL-separated host and directory fields")
    host, directory = (field.decode("utf-8") for field in fields[:2])
    if not host or not directory:
        raise ValueError("host and directory must not be empty")
    if not directory.startswith("/"):
        raise ValueError("directory must be an absolute path")

    # Bracket IPv6 literals so Wu can parse the SSH URL as a URI authority.
    authority_host = f"[{host}]" if ":" in host and not host.startswith("[") else host
    cli_path = os.environ.get("WU_CLI_PATH") or "/usr/local/bin/wu"
    remote_path = quote(directory, safe="/~")
    subprocess.Popen([cli_path, f"ssh://{authority_host}{remote_path}"])


def receive_request(conn):
    chunks = []
    size = 0
    while True:
        chunk = conn.recv(min(4096, MAX_REQUEST_SIZE + 1 - size))
        if not chunk:
            break
        chunks.append(chunk)
        size += len(chunk)
        if size > MAX_REQUEST_SIZE:
            raise ValueError("request is too large")
    return b"".join(chunks)


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", PORT))
        sock.listen(5)

        while True:
            conn, _ = sock.accept()
            with conn:
                try:
                    handle_request(receive_request(conn))
                except (OSError, UnicodeDecodeError, ValueError, subprocess.SubprocessError) as error:
                    print(f"wu-listener: {error}", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
```

#### 2. `~/Library/LaunchAgents/com.wu.remote-listener.plist`

Launchd service that auto-starts `wu-listener` on login and keeps it running.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.wu.remote-listener</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/Users/your-user/.local/bin/wu-listener</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>WU_CLI_PATH</key>
        <string>/usr/local/bin/wu</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/wu-listener.err</string>
</dict>
</plist>
```

#### 3. `~/.ssh/config` (relevant addition)

The `RemoteForward` line creates a reverse tunnel: anything connecting to port 7682 on the remote server gets forwarded back to port 7682 on your Mac.

```
Host my-server
    HostName <ip-or-hostname>
    User <username>
    RemoteForward 7682 127.0.0.1:7682
```

### Remote server

#### 4. `~/.local/bin/wu`

The command you actually type. Resolves the target directory to an absolute path and sends it through the reverse tunnel via netcat.

```bash
#!/bin/bash
# Open a Wu remote project on the local machine via reverse SSH tunnel.
# Usage: wu [directory]  (defaults to current directory)
#
# Installed on the remote server. Requires:
#   - wu-listener running on the local Mac
#   - RemoteForward 7682 127.0.0.1:7682 in SSH config for this host
#
# WU_SSH_HOST can be set to the SSH config alias for this server.
# Set it in your shell config, e.g.: export WU_SSH_HOST="my-server"

if (( $# > 1 )); then
    echo "Usage: wu [directory]" >&2
    exit 2
fi

dir="${1:-.}"
dir=$(cd -- "$dir" 2>/dev/null && pwd) || { echo "wu: cannot access '$dir'" >&2; exit 1; }

host="${WU_SSH_HOST:-$(hostname -f 2>/dev/null || hostname)}"

response="$(printf '%s\0%s\0' "$host" "$dir" | nc -q1 127.0.0.1 7682 2>/dev/null)" || {
    echo "wu: could not connect to local listener on port 7682" >&2
    echo "  Make sure wu-listener is running and SSH has RemoteForward 7682" >&2
    exit 1
}

if [[ "$response" != "OK" ]]; then
    echo "wu: local listener rejected the request; check /tmp/wu-listener.err" >&2
    exit 1
fi
echo "Opening Wu at $dir"
```

## Adding another server

1. Add `RemoteForward 7682 127.0.0.1:7682` to that host in `~/.ssh/config`
2. Copy `wu-remote` to `~/.local/bin/wu` on the remote server
3. Set `export WU_SSH_HOST="<ssh-alias>"` in the server's `.bashrc`

## Troubleshooting

**`wu: could not connect to local listener on port 7682`**
- Check the listener is running: `ps aux | grep wu-listener`
- Restart it: `launchctl kickstart -k gui/$(id -u)/com.wu.remote-listener`
- Check logs: `cat /tmp/wu-listener.err`

**`Warning: remote port forwarding failed for listen port 7682`**
- Harmless. Means another SSH session already has the tunnel. The existing tunnel still works.

**Wu opens but doesn't connect**
- Test directly: `wu ssh://your-host/home/user`
- Make sure Wu's remote SSH connection works from your local terminal: `wu ssh://your-host/home/user`

## Why it works this way

Wu already supports `wu ssh://host/path` natively, so the listener just calls that directly. No helper scripts needed on the local side.

The installer records the Wu CLI's absolute path in launchd's environment because launchd runs with a minimal PATH.

Port 7682 (one above the Ghostty listener at 7681). Change it in the listener, SSH config, and remote script if needed.
