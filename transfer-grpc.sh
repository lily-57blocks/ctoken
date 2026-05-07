#!/bin/bash
# Transfer FSB tokens via the Canton gRPC Ledger API using Daml Script.
#
# This script tests FSBHolding_Transfer over gRPC (port 6865), in contrast to
# test-sandbox.sh which uses the HTTP JSON API (port 6864).
#
# Workflow (executed inside the Daml Script runtime via dpm script):
#   1. Allocate admin + recipient parties via gRPC
#   2. Create FSBIssuer and mint 1,000,000 FSB to admin
#   3. Exercise FSBHolding_Transfer: send 100 FSB to recipient
#   4. Assert recipient balance == 100 FSB
#   5. Assert admin change balance == 999,900 FSB
#
# Usage:
#   ./transfer-grpc.sh
#
# Prerequisites:
#   - dpm sandbox running: dpm sandbox --dar .daml/dist/ctoken-fsb-0.0.2.dar
#   - DAR built (this script runs dpm build automatically)
#   - Ledger user "admin" must exist (run ./test-sandbox.sh first, or it will
#     be created automatically by the Daml Script's allocatePartyByHint call)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LEDGER_HOST="localhost"
LEDGER_PORT="6865"
USER_ID="admin"
DAR_FILE=".daml/dist/ctoken-fsb-0.0.2.dar"
SCRIPT_NAME="CToken.TransferScript:transferFSB"

# ─── Preflight ────────────────────────────────────────────────────────────────

if ! command -v dpm &>/dev/null; then
  echo "ERROR: dpm not found. Install the Canton SDK first."
  exit 1
fi

# ─── Main ─────────────────────────────────────────────────────────────────────

echo "==========================================="
echo " FSB Transfer via gRPC (Daml Script)"
echo "==========================================="
echo " Ledger:  $LEDGER_HOST:$LEDGER_PORT (gRPC)"
echo " Script:  $SCRIPT_NAME"
echo " User ID: $USER_ID"
echo "==========================================="
echo ""

cd "$SCRIPT_DIR"

# ── [1/2] Build DAR ───────────────────────────────────────────────────────────
echo "=== [1/2] Building DAR ==="
dpm build 2>&1 | grep -E "Compiling|Created|error|warning" || true
echo "  Build complete: $DAR_FILE"
echo ""

# ── [2/2] Run Daml Script via gRPC ───────────────────────────────────────────
echo "=== [2/2] Running transferFSB via gRPC ==="
echo ""

dpm script \
  --dar "$DAR_FILE" \
  --script-name "$SCRIPT_NAME" \
  --ledger-host "$LEDGER_HOST" \
  --ledger-port "$LEDGER_PORT" \
  --user-id "$USER_ID" \
  -w

echo ""
echo "==========================================="
echo " Done."
echo "==========================================="
