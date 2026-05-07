#!/bin/bash
# Upload ctoken-fsb DAR, create FSBIssuer, and mint FSB tokens.
#
# Usage:
#   ./mint-fsb.sh [total-supply] [recipient-username]
#
# Examples:
#   ./mint-fsb.sh                          # Mint 1,000,000 FSB to app-provider (default)
#   ./mint-fsb.sh 5000000                  # Mint 5,000,000 FSB to app-provider
#   ./mint-fsb.sh 1000000 app-user-2       # Mint 1,000,000 FSB to app-user-2
#
# Prerequisites:
#   - Canton Quickstart environment running (make start)
#   - DAR built at ctoken/.daml/dist/ctoken-fsb-*.dar
#   - damlc available on PATH (for inspecting DAR)

set -euo pipefail

TOTAL_SUPPLY="${1:-1000000}"
RECIPIENT_USERNAME="${2:-app-provider}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAR_FILE=$(ls "$SCRIPT_DIR"/.daml/dist/ctoken-fsb-*.dar 2>/dev/null | tail -1)

if [ -z "$DAR_FILE" ]; then
  echo "ERROR: No DAR file found. Run 'damlc build' in $SCRIPT_DIR first."
  exit 1
fi

echo "==========================================="
echo " FSB Token Mint"
echo "==========================================="
echo " DAR:          $(basename "$DAR_FILE")"
echo " Total Supply: $TOTAL_SUPPLY"
echo " Recipient:    $RECIPIENT_USERNAME"
echo "==========================================="
echo ""

# Determine recipient participant port
case "$RECIPIENT_USERNAME" in
  app-provider*) RECIPIENT_PORT=3975 ;;
  app-user*)     RECIPIENT_PORT=2975 ;;
  sv*)           RECIPIENT_PORT=4975 ;;
  *)
    echo "ERROR: Unknown user prefix: $RECIPIENT_USERNAME"
    exit 1
    ;;
esac

ADMIN_PORT=3975

# Copy DAR into container
echo "=== [1/5] Copying DAR to container ==="
docker cp "$DAR_FILE" splice-onboarding:/tmp/ctoken-fsb.dar
echo "  Done."
echo ""

# Run all ledger operations inside the splice-onboarding container
docker exec splice-onboarding bash -c '
set -euo pipefail
source /app/utils.sh

TOTAL_SUPPLY="'"$TOTAL_SUPPLY"'"
RECIPIENT_USERNAME="'"$RECIPIENT_USERNAME"'"
ADMIN_PORT="'"$ADMIN_PORT"'"
RECIPIENT_PORT="'"$RECIPIENT_PORT"'"

AUDIENCE="https://canton.network.global"
TOKEN=$(generate_jwt "ledger-api-user" "$AUDIENCE")
ADMIN_P="canton:${ADMIN_PORT}"
ADMIN_PARTY=$(get_user_party "$TOKEN" "ledger-api-user" "$ADMIN_P")

# Resolve recipient party
if [ "$RECIPIENT_USERNAME" = "app-provider" ] || [ "$RECIPIENT_USERNAME" = "ledger-api-user" ]; then
  RECIPIENT_PARTY="$ADMIN_PARTY"
else
  RECIPIENT_P="canton:${RECIPIENT_PORT}"
  RECIPIENT_PARTY=$(curl -s \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "http://$RECIPIENT_P/v2/users/$RECIPIENT_USERNAME" | jq -r ".user.primaryParty")
  if [ -z "$RECIPIENT_PARTY" ] || [ "$RECIPIENT_PARTY" = "null" ]; then
    echo "ERROR: User \"$RECIPIENT_USERNAME\" not found on canton:$RECIPIENT_PORT"
    exit 1
  fi
fi

echo "=== [2/5] Uploading DAR ==="
upload_to() {
  local port=$1
  local code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @/tmp/ctoken-fsb.dar \
    "http://canton:${port}/v2/packages")
  echo "  canton:${port} -> HTTP $code"
}
upload_to "$ADMIN_PORT"
if [ "$RECIPIENT_PORT" != "$ADMIN_PORT" ]; then
  upload_to "$RECIPIENT_PORT"
fi
echo ""

echo "=== [3/5] Creating FSBIssuer ==="
CREATE_RESULT=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "http://$ADMIN_P/v2/commands/submit-and-wait" \
  --data-raw "{
    \"commands\": [{
      \"CreateCommand\": {
        \"templateId\": \"#ctoken-fsb:CToken.FSBIssuer:FSBIssuer\",
        \"createArguments\": {
          \"admin\": \"$ADMIN_PARTY\",
          \"totalSupply\": \"${TOTAL_SUPPLY}.0000000000\",
          \"minted\": false
        }
      }
    }],
    \"workflowId\": \"mint-fsb\",
    \"applicationId\": \"ledger-api-user\",
    \"commandId\": \"create-issuer-$(date +%s%N)\",
    \"deduplicationPeriod\": {\"Empty\": {}},
    \"actAs\": [\"$ADMIN_PARTY\"],
    \"readAs\": [\"$ADMIN_PARTY\"],
    \"submissionId\": \"create-issuer-$(date +%s%N)\",
    \"disclosedContracts\": [],
    \"domainId\": \"\",
    \"packageIdSelectionPreference\": []
  }")
HTTP=$(echo "$CREATE_RESULT" | tail -n1)
BODY=$(echo "$CREATE_RESULT" | sed "\$d")
if [ "$HTTP" != "200" ]; then
  echo "  ERROR (HTTP $HTTP): $BODY"
  exit 1
fi
echo "  Created: $(echo "$BODY" | jq -c .)"
echo ""

echo "=== [4/5] Minting $TOTAL_SUPPLY FSB ==="
OFFSET=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "http://$ADMIN_P/v2/state/ledger-end" | jq -r ".offset")
ACS=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "http://$ADMIN_P/v2/state/active-contracts" \
  --data-raw "{
    \"filter\": {\"filtersByParty\": {\"$ADMIN_PARTY\": {\"templateFilters\": [{\"templateId\": \"#ctoken-fsb:CToken.FSBIssuer:FSBIssuer\"}]}}},
    \"activeAtOffset\": $OFFSET
  }")
ISSUER_CID=$(echo "$ACS" | jq -r "
  [.[]
   | .contractEntry.JsActiveContract.createdEvent
   | select(.templateId | contains(\"FSBIssuer\"))
   | select(.createArgument.minted == false)
  ] | last | .contractId")

if [ -z "$ISSUER_CID" ] || [ "$ISSUER_CID" = "null" ]; then
  echo "  ERROR: Could not find FSBIssuer contract"
  exit 1
fi

MINT_RESULT=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "http://$ADMIN_P/v2/commands/submit-and-wait" \
  --data-raw "{
    \"commands\": [{
      \"ExerciseCommand\": {
        \"templateId\": \"#ctoken-fsb:CToken.FSBIssuer:FSBIssuer\",
        \"contractId\": \"$ISSUER_CID\",
        \"choice\": \"FSBIssuer_Mint\",
        \"choiceArgument\": {\"recipient\": \"$RECIPIENT_PARTY\"}
      }
    }],
    \"workflowId\": \"mint-fsb\",
    \"applicationId\": \"ledger-api-user\",
    \"commandId\": \"mint-$(date +%s%N)\",
    \"deduplicationPeriod\": {\"Empty\": {}},
    \"actAs\": [\"$ADMIN_PARTY\"],
    \"readAs\": [\"$ADMIN_PARTY\"],
    \"submissionId\": \"mint-$(date +%s%N)\",
    \"disclosedContracts\": [],
    \"domainId\": \"\",
    \"packageIdSelectionPreference\": []
  }")
MINT_HTTP=$(echo "$MINT_RESULT" | tail -n1)
MINT_BODY=$(echo "$MINT_RESULT" | sed "\$d")
if [ "$MINT_HTTP" != "200" ]; then
  echo "  ERROR (HTTP $MINT_HTTP): $MINT_BODY"
  exit 1
fi
echo "  Minted: $(echo "$MINT_BODY" | jq -c .)"
echo ""

echo "=== [5/5] Verifying ==="
OFFSET2=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "http://$ADMIN_P/v2/state/ledger-end" | jq -r ".offset")
HOLDING=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "http://$ADMIN_P/v2/state/active-contracts" \
  --data-raw "{
    \"filter\": {\"filtersByParty\": {\"$ADMIN_PARTY\": {\"templateFilters\": [{\"templateId\": \"#ctoken-fsb:CToken.FSBHolding:FSBHolding\"}]}}},
    \"activeAtOffset\": $OFFSET2
  }" | jq "[
    .[]
    | .contractEntry.JsActiveContract.createdEvent
    | select(.templateId | contains(\"FSBHolding\"))
    | select(.createArgument.owner == \"$RECIPIENT_PARTY\")
  ] | last | {amount: .createArgument.amount, owner: (.createArgument.owner | split(\"::\")[0])}")

echo "  $HOLDING"
echo ""
echo "==========================================="
echo " Mint complete!"
echo " $TOTAL_SUPPLY FSB -> $RECIPIENT_USERNAME"
echo "==========================================="
' 2>&1 | grep -v "^http://" | grep -v "^get_user_party" | grep -v "^--data-raw"
