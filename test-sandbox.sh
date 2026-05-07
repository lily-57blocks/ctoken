#!/bin/bash
# Test ctoken-fsb contracts on a running dpm sandbox.
#
# Workflow:
#   1. Verify sandbox connectivity
#   2. Allocate a Party + create Ledger User "admin"
#   3. Create FSBIssuer contract
#   4. Execute FSBIssuer_Mint choice
#   5. Query & print FSBHolding balance
#
# Usage:
#   ./test-sandbox.sh [total-supply]
#
# Examples:
#   ./test-sandbox.sh             # Mint 1,000,000 FSB (default)
#   ./test-sandbox.sh 500000      # Mint 500,000 FSB
#
# Prerequisites:
#   - dpm sandbox running: dpm sandbox --dar .daml/dist/ctoken-fsb-0.0.2.dar
#   - jq installed (brew install jq)
#   - node available with jsonwebtoken in ../ctoken-transfer/node_modules/

set -euo pipefail

TOTAL_SUPPLY="${1:-1000000}"
PARTICIPANT="http://localhost:6864"
AUDIENCE="https://canton.network.global"
JWT_SECRET="unsafe"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JWT_MODULE="$SCRIPT_DIR/../ctoken-transfer/node_modules/jsonwebtoken"

# ─── Preflight checks ────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install with: brew install jq"
  exit 1
fi

if ! command -v node &>/dev/null; then
  echo "ERROR: node is required."
  exit 1
fi

if [ ! -d "$JWT_MODULE" ]; then
  echo "ERROR: jsonwebtoken module not found at $JWT_MODULE"
  echo "  Run: cd ../ctoken-transfer && npm install"
  exit 1
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

generate_jwt() {
  local sub="$1"
  node -e "
    const jwt = require('$JWT_MODULE');
    console.log(jwt.sign(
      { sub: '$sub', aud: '$AUDIENCE' },
      '$JWT_SECRET',
      { algorithm: 'HS256' }
    ));"
}

# Submit a command to /v2/commands/submit-and-wait and return the response body.
# Exits on non-200.
submit_command() {
  local label="$1"
  local payload="$2"

  local result
  result=$(curl -s -w "\n%{http_code}" \
    -H "Content-Type: application/json" \
    "$PARTICIPANT/v2/commands/submit-and-wait" \
    --data-raw "$payload")

  local http_code body
  http_code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')

  if [ "$http_code" != "200" ]; then
    echo ""
    echo "  ERROR [$label] HTTP $http_code:"
    echo "$body" | jq -c . 2>/dev/null || echo "$body"
    exit 1
  fi
  echo "$body"
}

# Query active contracts for a given templateId and return the raw ACS array.
# No auth token needed: sandbox allows unauthenticated reads.
query_acs() {
  local party="$1"
  local template_id="$2"

  local offset
  offset=$(curl -s \
    -H "Content-Type: application/json" \
    "$PARTICIPANT/v2/state/ledger-end" | jq -r '.offset')

  curl -s \
    -H "Content-Type: application/json" \
    "$PARTICIPANT/v2/state/active-contracts" \
    --data-raw "{
      \"filter\": {
        \"filtersByParty\": {
          \"$party\": {
            \"templateFilters\": [{\"templateId\": \"$template_id\"}]
          }
        }
      },
      \"activeAtOffset\": $offset
    }"
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo "==========================================="
echo " FSB Sandbox Test"
echo "==========================================="
echo " Participant:  $PARTICIPANT"
echo " Total Supply: $TOTAL_SUPPLY FSB"
echo "==========================================="
echo ""

# ── [0/5] Verify sandbox connectivity ────────────────────────────────────────
echo "=== [0/5] Checking sandbox connectivity ==="
VERSION_RESP=$(curl -s -o /dev/null -w "%{http_code}" "$PARTICIPANT/v2/version" 2>/dev/null)
if [ "$VERSION_RESP" != "200" ]; then
  echo "  ERROR: Cannot reach sandbox at $PARTICIPANT (HTTP $VERSION_RESP)"
  echo ""
  echo "  Make sure dpm sandbox is running:"
  echo "    cd $(basename "$SCRIPT_DIR") && dpm sandbox --dar .daml/dist/ctoken-fsb-0.0.2.dar"
  exit 1
fi
CANTON_VER=$(curl -s "$PARTICIPANT/v2/version" | jq -r '.version // "unknown"')
echo "  Canton version: $CANTON_VER"
echo ""

# ── [1/5] Allocate Party (idempotent) ────────────────────────────────────────
echo "=== [1/5] Allocating Party ==="
TOKEN=$(generate_jwt "admin")

# Check if user 'admin' already exists and has a primaryParty
EXISTING_USER=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  "$PARTICIPANT/v2/users/admin")

if [ "$EXISTING_USER" = "200" ]; then
  PARTY=$(curl -s \
    -H "Authorization: Bearer $TOKEN" \
    "$PARTICIPANT/v2/users/admin" | jq -r '.user.primaryParty')
  echo "  Reusing existing Party: $PARTY"
else
  ALLOCATE_RESULT=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$PARTICIPANT/v2/parties" \
    --data-raw '{"partyIdHint": "admin", "displayName": "Admin"}')

  ALLOCATE_HTTP=$(echo "$ALLOCATE_RESULT" | tail -n1)
  ALLOCATE_BODY=$(echo "$ALLOCATE_RESULT" | sed '$d')

  if [ "$ALLOCATE_HTTP" != "200" ]; then
    echo "  ERROR (HTTP $ALLOCATE_HTTP): $ALLOCATE_BODY"
    exit 1
  fi
  PARTY=$(echo "$ALLOCATE_BODY" | jq -r '.partyDetails.party')
  echo "  Allocated new Party: $PARTY"
fi
echo ""

# ── [2/5] Create Ledger User (idempotent) ─────────────────────────────────────
echo "=== [2/5] Creating Ledger User 'admin' ==="
if [ "$EXISTING_USER" = "200" ]; then
  echo "  Reusing existing user 'admin' -> primaryParty: ${PARTY%%::*}"
else
  USER_RESULT=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$PARTICIPANT/v2/users" \
    --data-raw "{
      \"user\": {
        \"id\": \"admin\",
        \"primaryParty\": \"$PARTY\",
        \"isDeactivated\": false,
        \"metadata\": {\"annotations\": {}, \"resourceVersion\": \"\"},
        \"identityProviderId\": \"\"
      },
      \"rights\": [
        {\"kind\": {\"CanActAs\": {\"value\": {\"party\": \"$PARTY\"}}}},
        {\"kind\": {\"CanReadAs\": {\"value\": {\"party\": \"$PARTY\"}}}}
      ]
    }")

  USER_HTTP=$(echo "$USER_RESULT" | tail -n1)
  USER_BODY=$(echo "$USER_RESULT" | sed '$d')

  if [ "$USER_HTTP" != "200" ]; then
    echo "  ERROR (HTTP $USER_HTTP): $USER_BODY"
    exit 1
  fi
  echo "  Created user 'admin' -> primaryParty: ${PARTY%%::*}"
fi
echo ""

# ── [3/5] Create FSBIssuer contract ──────────────────────────────────────────
echo "=== [3/5] Creating FSBIssuer contract ==="
submit_command "FSBIssuer Create" "{
  \"commands\": [{
    \"CreateCommand\": {
      \"templateId\": \"#ctoken-fsb:CToken.FSBIssuer:FSBIssuer\",
      \"createArguments\": {
        \"admin\": \"$PARTY\",
        \"totalSupply\": \"${TOTAL_SUPPLY}.0000000000\",
        \"minted\": false
      }
    }
  }],
  \"workflowId\": \"test-sandbox\",
  \"userId\": \"admin\",
  \"commandId\": \"create-issuer-$(date +%s%3N)\",
  \"deduplicationPeriod\": {\"Empty\": {}},
  \"actAs\": [\"$PARTY\"],
  \"readAs\": [\"$PARTY\"],
  \"submissionId\": \"si-1-$(date +%s%3N)\",
  \"disclosedContracts\": [],
  \"domainId\": \"\",
  \"packageIdSelectionPreference\": []
}" > /dev/null
echo "  FSBIssuer created."
echo ""

# ── [4/5] Mint FSB tokens ─────────────────────────────────────────────────────
echo "=== [4/5] Minting $TOTAL_SUPPLY FSB ==="
ACS=$(query_acs "$PARTY" "#ctoken-fsb:CToken.FSBIssuer:FSBIssuer")
ISSUER_CID=$(echo "$ACS" | jq -r '
  [.[]
   | .contractEntry.JsActiveContract.createdEvent
   | select(.templateId | contains("FSBIssuer"))
   | select(.createArgument.minted == false)
  ] | last | .contractId')

if [ -z "$ISSUER_CID" ] || [ "$ISSUER_CID" = "null" ]; then
  echo "  ERROR: Could not find FSBIssuer contract in ACS."
  echo "  Raw ACS response:"
  echo "$ACS" | jq -c .
  exit 1
fi
echo "  FSBIssuer contractId: ${ISSUER_CID:0:24}..."

submit_command "FSBIssuer_Mint" "{
  \"commands\": [{
    \"ExerciseCommand\": {
      \"templateId\": \"#ctoken-fsb:CToken.FSBIssuer:FSBIssuer\",
      \"contractId\": \"$ISSUER_CID\",
      \"choice\": \"FSBIssuer_Mint\",
      \"choiceArgument\": {\"recipient\": \"$PARTY\"}
    }
  }],
  \"workflowId\": \"test-sandbox\",
  \"userId\": \"admin\",
  \"commandId\": \"mint-$(date +%s%3N)\",
  \"deduplicationPeriod\": {\"Empty\": {}},
  \"actAs\": [\"$PARTY\"],
  \"readAs\": [\"$PARTY\"],
  \"submissionId\": \"si-2-$(date +%s%3N)\",
  \"disclosedContracts\": [],
  \"domainId\": \"\",
  \"packageIdSelectionPreference\": []
}" > /dev/null
echo "  Minted $TOTAL_SUPPLY FSB."
echo ""

# ── [5/5] Verify FSBHolding balance ──────────────────────────────────────────
echo "=== [5/5] Verifying FSBHolding balance ==="
ACS2=$(query_acs "$PARTY" "#ctoken-fsb:CToken.FSBHolding:FSBHolding")

HOLDINGS=$(echo "$ACS2" | jq '
  [.[]
   | select(.contractEntry.JsActiveContract.createdEvent.packageName == "ctoken-fsb")
   | .contractEntry.JsActiveContract.createdEvent
   | select(.templateId | endswith("FSBHolding"))
   | {
       contractId: (.contractId[:24] + "..."),
       owner:      .createArgument.owner,
       amount:     (.createArgument.amount | tonumber)
     }
  ]')

COUNT=$(echo "$HOLDINGS" | jq 'length')
TOTAL=$(echo "$HOLDINGS" | jq '[.[].amount] | add // 0')

echo "  Holdings count: $COUNT"
echo "  Total balance:  $TOTAL FSB"
echo ""
echo "$HOLDINGS" | jq -r '.[] | "  ContractId: \(.contractId)\n  Owner:      \(.owner)\n  Amount:     \(.amount) FSB\n"'

if [ "$COUNT" -eq 0 ]; then
  echo "  WARNING: No FSBHolding found. Mint may have failed silently."
  exit 1
fi

echo "==========================================="
echo " Test passed!"
echo " $TOTAL_SUPPLY FSB minted to: ${PARTY%%::*}"
echo "==========================================="
