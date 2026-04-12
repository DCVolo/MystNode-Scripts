#!/bin/sh

# Install dependencies silently
apk add --no-cache curl jq >/dev/null 2>&1

# -----------------------------
# CONFIGURATION
# -----------------------------
API_IP="${TEQUILA_API_IP}"
API_PORT="${TEQUILA_API_PORT}"
INFLUX_URL="${INFLUX_URL}"
LOOP_DELAY="${SCRIPT_INTERVAL}"

# -----------------------------
# AUTH
# ------------------------------
AUTH_USERNAME="${INFLUX_USERNAME}"
AUTH_PASSWORD="${INFLUX_PASSWORD}"

# -----------------------------
# VALIDATE REQUIRED ENV VARS
# -----------------------------
if [ -z "$DOCKER_CTNS_NAME" ] || [ -z "$NODES_NAME" ]; then
  echo "Error: DOCKER_CTNS_NAME or NODES_NAME not set"
  exit 1
fi

if [ -z "$API_IP" ] || [ -z "$API_PORT" ] || [ -z "$INFLUX_URL" ]; then
  echo "Error: TEQUILA_API_IP, TEQUILA_API_PORT, or INFLUX_URL not set"
  exit 1
fi

if [ -z "$AUTH_USERNAME" ] || [ -z "$AUTH_PASSWORD" ]; then
  echo "Error: INFLUX_USERNAME or INFLUX_PASSWORD not set"
  exit 1
fi

# -----------------------------
# SPLIT SPACE-SEPARATED LISTS
# -----------------------------
CTN_COUNT=$(echo "$DOCKER_CTNS_NAME" | wc -w)
NODE_COUNT=$(echo "$NODES_NAME" | wc -w)

if [ "$CTN_COUNT" -ne "$NODE_COUNT" ]; then
  echo "Error: DOCKER_CTNS_NAME and NODES_NAME length mismatch"
  exit 1
fi

# -----------------------------
# INFLUXDB.v1 VALUE FORMATTER
# -----------------------------
format_influx_value() {
  VAL="$1"

  # Integer (no decimal)
  if echo "$VAL" | grep -Eq '^[0-9]+$'; then
    echo "${VAL}i"
    return
  fi

  # Float
  if echo "$VAL" | grep -Eq '^[0-9]+\.[0-9]+$'; then
    echo "$VAL"
    return
  fi

  # Fallback
  echo "0i"
}

# -----------------------------
# LOOP FOREVER
# -----------------------------
while true; do

  i=1
  for DOCKER_NODE in $DOCKER_CTNS_NAME; do
    NODE_NAME=$(echo "$NODES_NAME" | cut -d' ' -f "$i")

    echo "Processing node: $NODE_NAME (container: $DOCKER_NODE)"

    # -----------------------------
    # CHECK CONTAINER EXISTS
    # -----------------------------
    if ! docker inspect "$DOCKER_NODE" >/dev/null 2>&1; then
      echo "Error: Container $DOCKER_NODE does not exist"
      i=$((i+1))
      continue
    fi

    # -----------------------------
    # FETCH DATA (SSE FIRST LINE)
    # -----------------------------
    RAW_STATE=$(docker exec "$DOCKER_NODE" sh -c "wget -qO- \"http://$API_IP:$API_PORT/events/state\" | head -n 1" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$RAW_STATE" ]; then
      echo "Error: Failed to fetch state for $DOCKER_NODE"
      i=$((i+1))
      continue
    fi

    STATE_JSON=$(echo "$RAW_STATE" | sed 's/^data: //')

    # -----------------------------
    # FETCH EARNINGS
    # -----------------------------
    EARNINGS_JSON=$(docker exec "$DOCKER_NODE" sh -c "wget -qO- \"http://$API_IP:$API_PORT/node/provider/service-earnings\" | head -n 1" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$EARNINGS_JSON" ]; then
      echo "Error: Failed to fetch earnings for $DOCKER_NODE"
      i=$((i+1))
      continue
    fi

    # -----------------------------
    # VALIDATE JSON
    # -----------------------------
    echo "$STATE_JSON" | jq -e . >/dev/null 2>&1 || {
      echo "Error: Invalid JSON in state response for $DOCKER_NODE"
      i=$((i+1))
      continue
    }

    echo "$EARNINGS_JSON" | jq -e . >/dev/null 2>&1 || {
      echo "Error: Invalid JSON in earnings response for $DOCKER_NODE"
      i=$((i+1))
      continue
    }

    # -----------------------------
    # EXTRACT GLOBAL METRICS
    # -----------------------------
    ACTIVE_SESSIONS=$(format_influx_value "$(echo "$STATE_JSON" | jq -r '.payload.sessions | length')")
    UNSETTLED_EARNINGS=$(format_influx_value "$(echo "$STATE_JSON" | jq -r '.payload.identities[0].earnings_tokens.human')")
    TOTAL_EARNINGS=$(format_influx_value "$(echo "$STATE_JSON" | jq -r '.payload.identities[0].earnings_total_tokens.human')")

    # -----------------------------
    # SERVICE HELPERS
    # -----------------------------
    get_price() {
      echo "$STATE_JSON" | jq -r ".payload.service_info[] | select(.type==\"$1\") | .proposal.price.per_gib_tokens.human // \"0\""
    }

    get_service_sessions() {
      echo "$STATE_JSON" | jq -r ".payload.sessions | map(select(.service_type==\"$1\")) | length // 0"
    }

    get_service_earnings() {
      echo "$EARNINGS_JSON" | jq -r ".${1}_tokens.human // \"0\""
    }

    # -----------------------------
    # EXTRACT PER-SERVICE METRICS
    # -----------------------------
    PRICE_DVPN=$(format_influx_value "$(get_price "dvpn")")
    PRICE_SCRAPING=$(format_influx_value "$(get_price "scraping")")
    PRICE_DATA=$(format_influx_value "$(get_price "data_transfer")")

    SESS_DVPN=$(format_influx_value "$(get_service_sessions "dvpn")")
    SESS_SCRAPING=$(format_influx_value "$(get_service_sessions "scraping")")
    SESS_DATA=$(format_influx_value "$(get_service_sessions "data_transfer")")

    EARN_DVPN=$(format_influx_value "$(get_service_earnings "dvpn")")
    EARN_SCRAPING=$(format_influx_value "$(get_service_earnings "scraping")")
    EARN_DATA=$(format_influx_value "$(get_service_earnings "data_transfer")")

    # -----------------------------
    # BUILD INFLUXDB LINE PROTOCOL
    # -----------------------------
    LINE="mystnode,node_name=$NODE_NAME \
active_sessions=$ACTIVE_SESSIONS, \
earnings_unsettled=$UNSETTLED_EARNINGS, \
earnings_total=$TOTAL_EARNINGS, \
dvpn_active_sessions=$SESS_DVPN, \
dvpn_price_per_gib=$PRICE_DVPN, \
dvpn_earnings=$EARN_DVPN, \
scraping_active_sessions=$SESS_SCRAPING, \
scraping_price_per_gib=$PRICE_SCRAPING, \
scraping_earnings=$EARN_SCRAPING, \
data_transfer_active_sessions=$SESS_DATA, \
data_transfer_price_per_gib=$PRICE_DATA, \
data_transfer_earnings=$EARN_DATA"

    LINE=$(echo "$LINE" | tr -d ' ')

    # -----------------------------
    # SEND TO INFLUXDB
    # -----------------------------
    echo "[DEBUG] Sending line: $LINE"

    curl -sS -XPOST "$INFLUX_URL" -u "$AUTH_USERNAME:$AUTH_PASSWORD" --data-binary "$LINE"

    i=$((i+1))
  done

  sleep "$LOOP_DELAY"

done
