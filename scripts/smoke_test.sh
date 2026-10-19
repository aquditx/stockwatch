#!/usr/bin/env bash
# Phase 1 smoke test: creates an owner and a staff user, then exercises the API.
# Usage: ./scripts/smoke_test.sh owner@example.com staff@example.com 'StrongPass123'
# Needs: aws cli (configured), jq, curl, and a deployed stack (terraform apply).
set -euo pipefail

OWNER_EMAIL="${1:?owner email}"
STAFF_EMAIL="${2:?staff email}"
PASSWORD="${3:?password (10+ chars, upper, lower, number)}"

tf() { terraform -chdir="$(dirname "$0")/../terraform" output -raw "$1"; }
API_URL="$(tf api_url)"
POOL_ID="$(tf user_pool_id)"
CLIENT_ID="$(tf user_pool_client_id)"
REGION="$(tf region)"

ensure_user() { # email group
  aws cognito-idp admin-create-user --region "$REGION" --user-pool-id "$POOL_ID" \
    --username "$1" --message-action SUPPRESS \
    --user-attributes Name=email,Value="$1" Name=email_verified,Value=true >/dev/null 2>&1 || true
  aws cognito-idp admin-set-user-password --region "$REGION" --user-pool-id "$POOL_ID" \
    --username "$1" --password "$PASSWORD" --permanent
  aws cognito-idp admin-add-user-to-group --region "$REGION" --user-pool-id "$POOL_ID" \
    --username "$1" --group-name "$2"
}

token() { # email -> ID token
  aws cognito-idp initiate-auth --region "$REGION" --client-id "$CLIENT_ID" \
    --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters USERNAME="$1",PASSWORD="$PASSWORD" \
    --query 'AuthenticationResult.IdToken' --output text
}

call() { # token method path [json]
  local t="$1" m="$2" p="$3" d="${4:-}"
  if [ -n "$d" ]; then
    curl -s -w '\nHTTP %{http_code}\n' -X "$m" "$API_URL$p" \
      -H "Authorization: $t" -H 'Content-Type: application/json' -d "$d"
  else
    curl -s -w '\nHTTP %{http_code}\n' -X "$m" "$API_URL$p" -H "Authorization: $t"
  fi
}

echo "== Creating users"
ensure_user "$OWNER_EMAIL" owner
ensure_user "$STAFF_EMAIL" staff
OWNER_TOKEN="$(token "$OWNER_EMAIL")"
STAFF_TOKEN="$(token "$STAFF_EMAIL")"

echo; echo "== No token -> expect 401"
curl -s -w '\nHTTP %{http_code}\n' "$API_URL/products"

echo; echo "== Staff creates product -> expect 403"
call "$STAFF_TOKEN" POST /products \
  '{"name":"Widget","sku":"W-1","stock":12,"reorder_threshold":5,"reorder_qty":50,"supplier_email":"supplier@example.com"}'

echo; echo "== Owner creates product -> expect 201"
CREATED="$(curl -s -X POST "$API_URL/products" -H "Authorization: $OWNER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Widget","sku":"W-1","stock":12,"reorder_threshold":5,"reorder_qty":50,"supplier_email":"supplier@example.com"}')"
echo "$CREATED" | jq .
PID="$(echo "$CREATED" | jq -r .product_id)"

echo; echo "== Staff lists products -> expect 200"
call "$STAFF_TOKEN" GET /products

echo; echo "== Staff sells 10 (12 -> 2) -> expect 200, stock 2"
call "$STAFF_TOKEN" POST "/products/$PID/stock" '{"delta":-10}'

echo; echo "== Staff sells 10 more -> expect 409 (insufficient stock)"
call "$STAFF_TOKEN" POST "/products/$PID/stock" '{"delta":-10}'

echo; echo "== Invalid payload -> expect 400"
call "$OWNER_TOKEN" POST /products '{"name":"","stock":-1}'

echo; echo "== Staff deletes -> expect 403"
call "$STAFF_TOKEN" DELETE "/products/$PID"

echo; echo "== Owner deletes -> expect 200"
call "$OWNER_TOKEN" DELETE "/products/$PID"

echo; echo "Done."
