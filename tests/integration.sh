#!/usr/bin/env bash
# Read-only integration test: run the plugin's real poll command against a live
# KEF speaker and check Model.parsePoll understands the response. Does not
# change any speaker state.
#
# Usage: tests/integration.sh <speaker-ip>
set -euo pipefail

HOST="${1:?usage: tests/integration.sh <speaker-ip>}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DIR

node - "$HOST" <<'EOF'
const { execFileSync } = require("node:child_process")
const assert = require("node:assert")
const Model = require(process.env.DIR + "/Model.js")

const host = process.argv[2]
const cmd = Model.pollCommand(host)
const raw = execFileSync(cmd[0], cmd.slice(1), { encoding: "utf8", timeout: 10000 })

const state = Model.parsePoll(raw)
assert.ok(state, "parsePoll returned null for a live response:\n" + raw)
assert.ok(typeof state.volume === "number", "volume missing")
assert.ok(state.status === "standby" || state.status === "powerOn", "unexpected status: " + state.status)
assert.ok(state.deviceName.length > 0, "deviceName missing")

console.log("ok — " + state.deviceName + " (" + state.status + "), volume " + state.volume
  + (state.source ? ", source " + state.source : ""))
EOF
