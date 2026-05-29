#!/usr/bin/env bash
# CoreWeave BMaaS information collection toolkit for EQTY Labs POC
# Usage: source bmaas.sh  OR  ./bmaas.sh <command> [args]
#
# Required env vars:
#   CW_TOKEN   - CoreWeave API bearer token (from https://console.coreweave.com/tokens)
#   CW_ZONE    - Zone, e.g. "us-east-04a"
#
# Optional env vars:
#   CW_ORG     - Org ID filter for multi-tenant queries

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BASE_URL="https://api.coreweave.com/bmaas/${CW_ZONE:-UNSET}/v1beta1"
TOKEN="${CW_TOKEN:-}"

_check_env() {
  if [[ -z "$TOKEN" ]]; then
    echo "ERROR: CW_TOKEN is not set. Export your API token first." >&2
    exit 1
  fi
  if [[ "${CW_ZONE:-UNSET}" == "UNSET" ]]; then
    echo "ERROR: CW_ZONE is not set. Export the zone, e.g. export CW_ZONE=us-east-04a" >&2
    exit 1
  fi
}

_curl() {
  curl --silent --fail-with-body \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    "$@"
}

_jq() {
  if command -v jq &>/dev/null; then
    jq "$@"
  else
    cat  # fall back to raw output if jq not installed
  fi
}

# ---------------------------------------------------------------------------
# Bare Metal Pools
# ---------------------------------------------------------------------------

# List all bare metal pools in the zone
list_pools() {
  _check_env
  echo "=== Bare Metal Pools (zone: ${CW_ZONE}) ===" >&2
  _curl -X GET "${BASE_URL}/baremetalpools" | _jq '.'
}

# Get a single pool by ID
get_pool() {
  local pool_id="${1:?Usage: get_pool <pool-id>}"
  _check_env
  echo "=== Pool: ${pool_id} ===" >&2
  _curl -X GET "${BASE_URL}/baremetalpools/${pool_id}" | _jq '.'
}

# Print a concise pool summary table (requires jq)
summary_pools() {
  _check_env
  echo "=== Pool Summary (zone: ${CW_ZONE}) ===" >&2
  list_pools | _jq -r '
    ["ID","NAME","INSTANCE_TYPE","TARGET","CURRENT","QUEUED","PENDING_DEL"],
    (.bareMetalPools[]? |
      [.id, .name, .instanceType,
       (.targetCount|tostring),
       (.currentNodes|tostring),
       (.queuedNodes|tostring),
       (.pendingDeletion|tostring)])
    | @tsv' | column -t
}

# ---------------------------------------------------------------------------
# Bare Metal Nodes
# ---------------------------------------------------------------------------

# List all nodes in the zone (auto-paginates)
list_nodes() {
  _check_env
  local page_token=""
  local page=1

  echo "=== All Bare Metal Nodes (zone: ${CW_ZONE}) ===" >&2

  while true; do
    local url="${BASE_URL}/baremetals"
    [[ -n "$page_token" ]] && url="${url}?pageToken=${page_token}"

    local response
    response=$(_curl -X GET "$url")

    echo "$response" | _jq '.bareMetals[]?'

    page_token=$(echo "$response" | _jq -r '.nextPageToken // empty')
    [[ -z "$page_token" ]] && break
    ((page++))
    echo "  [fetching page ${page}...]" >&2
  done
}

# List nodes belonging to a specific pool (by pool name)
list_nodes_for_pool() {
  local pool_name="${1:?Usage: list_nodes_for_pool <pool-name>}"
  _check_env
  echo "=== Nodes in pool '${pool_name}' (zone: ${CW_ZONE}) ===" >&2
  _curl -X GET "${BASE_URL}/baremetals" | \
    _jq --arg p "$pool_name" '.bareMetals[] | select(.resourceFriendlyName == $p)'
}

# Get a single node by ID
get_node() {
  local node_id="${1:?Usage: get_node <node-id>}"
  _check_env
  echo "=== Node: ${node_id} ===" >&2
  _curl -X GET "${BASE_URL}/baremetals/${node_id}" | _jq '.'
}

# Reboot a node (power-cycle only, no DPU reconfigure)
reboot_node() {
  local node_id="${1:?Usage: reboot_node <node-id>}"
  _check_env
  echo "=== Rebooting node: ${node_id} ===" >&2
  _curl -X POST "${BASE_URL}/baremetals/${node_id}/reboot" | _jq '.'
}

# Reconfigure a node (DPU reconfigure + power-cycle; required after NodeProfile changes)
reconfigure_node() {
  local node_id="${1:?Usage: reconfigure_node <node-id>}"
  _check_env
  echo "=== Reconfiguring node: ${node_id} ===" >&2
  _curl -X POST "${BASE_URL}/baremetals/${node_id}/reboot/reconfigure" | _jq '.'
}

# Get the state history for a node (last 30 days)
get_node_history() {
  local node_id="${1:?Usage: get_node_history <node-id>}"
  _check_env
  echo "=== History for node: ${node_id} ===" >&2
  _curl -X GET "${BASE_URL}/baremetals/${node_id}/history" | _jq '.'
}

# Print a concise node summary table (requires jq)
summary_nodes() {
  local pool_name="${1:-}"
  _check_env

  local raw
  if [[ -n "$pool_name" ]]; then
    echo "=== Node Summary for pool '${pool_name}' ===" >&2
    raw=$(_curl -X GET "${BASE_URL}/baremetals?filter=name%3D${pool_name}")
  else
    echo "=== Node Summary — all pools (zone: ${CW_ZONE}) ===" >&2
    raw=$(list_nodes)
  fi

  # When list_nodes is called it emits one JSON object per node (not an array)
  # Handle both array-wrapped and raw-object responses
  echo "$raw" | _jq -r '
    if type == "array" then .[]
    elif has("bareMetals") then .bareMetals[]
    else .
    end |
    [.id, (.status.state // "unknown"), .instanceType, .resourceFriendlyName,
     (.network.node.ipv4 // "-"), .createdAt]
    | @tsv' | \
  { echo -e "ID\tSTATE\tINSTANCE_TYPE\tPOOL_NAME\tIPv4\tCREATED_AT"; cat; } | \
  column -t
}

# ---------------------------------------------------------------------------
# VPC-scoped overview
# ---------------------------------------------------------------------------

# Full VPC overview: pools + nodes, cross-referenced
vpc_overview() {
  _check_env
  echo ""
  echo "############################################################"
  echo "  CoreWeave BMaaS VPC Overview"
  echo "  Zone : ${CW_ZONE}"
  echo "  Time : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "############################################################"
  echo ""

  echo "--- POOLS ---"
  summary_pools
  echo ""

  echo "--- NODES ---"
  summary_nodes
  echo ""
}

# ---------------------------------------------------------------------------
# CLI dispatch (when script is executed directly, not sourced)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  cmd="${1:-help}"
  shift || true

  case "$cmd" in
    list-pools)         list_pools ;;
    get-pool)           get_pool "$@" ;;
    summary-pools)      summary_pools ;;
    list-nodes)         list_nodes ;;
    list-nodes-pool)    list_nodes_for_pool "$@" ;;
    get-node)           get_node "$@" ;;
    node-history)       get_node_history "$@" ;;
    reboot-node)        reboot_node "$@" ;;
    reconfigure-node)   reconfigure_node "$@" ;;
    summary-nodes)      summary_nodes "$@" ;;
    overview)           vpc_overview ;;
    help|*)
      cat <<EOF
Usage: $(basename "$0") <command> [args]

Environment variables required:
  CW_TOKEN   CoreWeave API bearer token
  CW_ZONE    Zone (e.g. us-east-04a)

Commands:
  overview                   Full VPC summary (pools + nodes)
  list-pools                 List all bare metal pools (raw JSON)
  summary-pools              Pools as a compact table
  get-pool <pool-id>         Get a single pool by UUID
  list-nodes                 List all nodes in zone (raw JSON, paginated)
  summary-nodes [pool-name]  Nodes as a compact table, optionally filtered
  list-nodes-pool <name>     List nodes for a specific pool (raw JSON)
  get-node <node-id>         Get a single node by UUID
  node-history <node-id>     Get state history for a node (last 30 days)
  reboot-node <node-id>      Power-cycle a node
  reconfigure-node <node-id> Reconfigure DPU + power-cycle (use after NodeProfile changes)
  help                       Show this help
EOF
      ;;
  esac
fi
