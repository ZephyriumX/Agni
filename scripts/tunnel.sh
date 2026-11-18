#!/usr/bin/env sh
# macOS/Linux version of tunnel.ps1: HTTPS URL for the API on this machine (Cloudflare quick tunnel, no account).
# Install cloudflared first: brew install cloudflared   |   https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
PORT="${1:-8000}"
exec cloudflared tunnel --url "http://127.0.0.1:${PORT}"
