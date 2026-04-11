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
    # FETCH DATA
    # -----------------------------
    RAW_STATE=$(docker exec "$DOCKER_NODE" wget -qO- "http://$API_IP:$API_PORT/events/state" 2>/dev/null)
    if [ $? -ne 0 ]; then
      echo "Error: Failed to fetch state for $DOCKER_NODE"
      i=$((i+1))
      continue
    fi

    STATE_JSON=$(echo "$RAW_STATE" | head -n 1 | sed 's/^data: //')

    EARNINGS_JSON=$(docker exec "$DOCKER_NODE" wget -qO- "http://$API_IP:$API_PORT/node/provider/service-earnings" 2>/dev/null)
    if [ $? -ne 0 ]; then
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
    ACTIVE_SESSIONS=$(echo "$STATE_JSON" | jq -r '.payload.sessions // [] | length')
    UNSETTLED_EARNINGS=$(echo "$STATE_JSON" | jq -r '.payload.identities[0].earnings_tokens.human // "0"')
    TOTAL_EARNINGS=$(echo "$STATE_JSON" | jq -r '.payload.identities[0].earnings_total_tokens.human // "0"')

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
    PRICE_DVPN=$(get_price "dvpn")
    PRICE_SCRAPING=$(get_price "scraping")
    PRICE_DATA=$(get_price "data_transfer")

    SESS_DVPN=$(get_service_sessions "dvpn")
    SESS_SCRAPING=$(get_service_sessions "scraping")
    SESS_DATA=$(get_service_sessions "data_transfer")

    EARN_DVPN=$(get_service_earnings "dvpn")
    EARN_SCRAPING=$(get_service_earnings "scraping")
    EARN_DATA=$(get_service_earnings "data_transfer")

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
    curl -s -XPOST "$INFLUX_URL" --data-binary "$LINE"

    i=$((i+1))
  done

  sleep "$LOOP_DELAY"

done
