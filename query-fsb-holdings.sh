#!/bin/bash
# Query FSB token holdings from the Canton Network Quickstart environment.
#
# Usage:
#   ./query-fsb-holdings.sh [username]
#
# Examples:
#   ./query-fsb-holdings.sh                  # App Provider (default, port 3975)
#   ./query-fsb-holdings.sh app-provider     # App Provider
#   ./query-fsb-holdings.sh app-user         # Default App User
#   ./query-fsb-holdings.sh app-user-2       # Custom App User created earlier
#   ./query-fsb-holdings.sh sv               # Super Validator
#
# The script automatically maps usernames to their Participant JSON API port:
#   app-provider / app-provider-*  -> 3975
#   app-user / app-user-*          -> 2975
#   sv / sv-*                      -> 4975

set -euo pipefail

USERNAME="${1:-app-provider}"

case "$USERNAME" in
  app-provider*) PORT=3975; ROLE="App Provider" ;;
  app-user*)     PORT=2975; ROLE="App User" ;;
  sv*)           PORT=4975; ROLE="SV" ;;
  *)
    echo "Unknown user: $USERNAME"
    echo "Supported prefixes: app-provider, app-user, sv"
    exit 1
    ;;
esac

docker exec splice-onboarding bash -c '
source /app/utils.sh

USERNAME="'"$USERNAME"'"
PORT="'"$PORT"'"
ROLE="'"$ROLE"'"
PARTICIPANT="canton:${PORT}"

AUDIENCE="https://canton.network.global"
TOKEN=$(generate_jwt "ledger-api-user" "$AUDIENCE")
USER_TOKEN=$(generate_jwt "$USERNAME" "$AUDIENCE")

PARTY=$(curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "http://$PARTICIPANT/v2/users/$USERNAME" | jq -r ".user.primaryParty")

if [ -z "$PARTY" ] || [ "$PARTY" = "null" ]; then
  echo "ERROR: User \"$USERNAME\" not found on $PARTICIPANT"
  exit 1
fi

OFFSET=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "http://$PARTICIPANT/v2/state/ledger-end" | jq -r ".offset")

RESULT=$(curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "http://$PARTICIPANT/v2/state/active-contracts" \
  --data-raw "{
    \"filter\": {
      \"filtersByParty\": {
        \"$PARTY\": {
          \"templateFilters\": [{
            \"templateId\": \"#ctoken-fsb:CToken.FSBHolding:FSBHolding\"
          }]
        }
      }
    },
    \"activeAtOffset\": $OFFSET
  }")

HOLDINGS=$(echo "$RESULT" | jq -r "[
  .[]
  | select(.contractEntry.JsActiveContract.createdEvent.packageName == \"ctoken-fsb\")
  | .contractEntry.JsActiveContract.createdEvent
  | select(.templateId | endswith(\"FSBHolding\"))
  | {
      contractId: .contractId,
      owner:      .createArgument.owner,
      amount:     .createArgument.amount,
      locked:     (.createArgument.lock != null),
      createdAt:  .createdAt
    }
]" 2>/dev/null)

COUNT=$(echo "$HOLDINGS" | jq "length")
TOTAL=$(echo "$HOLDINGS" | jq "[.[].amount | tonumber] | add // 0")

echo "==========================================="
echo " FSB Token Holdings"
echo "==========================================="
echo " User:          $USERNAME"
echo " Role:          $ROLE"
echo " Participant:   $PARTICIPANT"
echo " Party:         $PARTY"
echo " Ledger Offset: $OFFSET"
echo "-------------------------------------------"
echo " Holdings:      $COUNT"
echo " Total FSB:     $TOTAL"
echo "==========================================="

if [ "$COUNT" != "0" ]; then
  echo ""
  echo "$HOLDINGS" | jq -r ".[] | \"  ContractId: \(.contractId[:24])...\n  Owner:      \(.owner)\n  Amount:     \(.amount)\n  Locked:     \(.locked)\n  Created:    \(.createdAt)\n\""
fi
' 2>&1 | grep -v "^http://" | grep -v "^get_user_party" | grep -v "^--data-raw"
