#!/usr/bin/env bash

# ── Cluster Config ─────────────────────────────────────────────────────────────
NODE1_IP="192.168.200.74"
NODE2_IP="192.168.200.75"
NODE3_IP="192.168.200.76"
AUTH_ZONE="65536.ir."
NS1="ns1.65536.ir"
RECURSIVE_TEST="dns.google"

AUTH_RECORD="test.65536.ir"

AUTH_PORT=5300
RECURSOR_PORT=5301
DNSDIST_PORT=5454
# ──────────────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0
FAILED_TESTS=()

pass() {
  echo -e "  ${GREEN}✓${NC} $1"
  PASS=$((PASS + 1))
}

fail() {
  echo -e "  ${RED}✗${NC} $1"
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("$1")
}

section() {
  echo -e "\n${CYAN}${BOLD}══ $1 ══${NC}"
}

check_port() {
  local desc="$1" host="$2" port="$3"
  if nc -z -w 3 "$host" "$port" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

check_dns() {
  local desc="$1" server="$2" port="$3" name="$4" type="${5:-A}"
  local result
  result=$(dig +short +time=3 +tries=1 "$type" "$name" "@$server" -p "$port" 2>/dev/null)
  if [[ -n "$result" ]]; then
    pass "$desc  →  $(echo "$result" | head -1)"
  else
    fail "$desc  (no answer)"
  fi
}

check_dns_contains() {
  local desc="$1" server="$2" port="$3" name="$4" type="$5" expected="$6"
  local result
  result=$(dig +short +time=3 +tries=1 "$type" "$name" "@$server" -p "$port" 2>/dev/null)
  if echo "$result" | grep -q "$expected"; then
    pass "$desc"
  else
    fail "$desc  (expected '$expected', got '${result:-empty}')"
  fi
}

# ── Config Summary ─────────────────────────────────────────────────────────────
echo -e "${BOLD}PowerDNS Cluster Test${NC}"
echo "────────────────────────────────────────"
echo "  Auth Zone  : $AUTH_ZONE"
echo "  Node 1 IP  : $NODE1_IP"
echo "  Node 2 IP  : $NODE2_IP"
echo "  Node 3 IP  : $NODE3_IP"
echo "  Ports      : auth=$AUTH_PORT  recursor=$RECURSOR_PORT  dnsdist=$DNSDIST_PORT"

# ── Port Reachability ──────────────────────────────────────────────────────────
section "Port Reachability"

for n in 1 2 3; do
  ip_var="NODE${n}_IP"; ip="${!ip_var}"
  check_port "node${n} ($ip) authoritative  :${AUTH_PORT}"    "$ip" "$AUTH_PORT"
  check_port "node${n} ($ip) recursor       :${RECURSOR_PORT}" "$ip" "$RECURSOR_PORT"
  check_port "node${n} ($ip) dnsdist        :${DNSDIST_PORT}" "$ip" "$DNSDIST_PORT"
done

# ── Authoritative DNS ──────────────────────────────────────────────────────────
section "Authoritative DNS — direct on port ${AUTH_PORT}"

for n in 1 2 3; do
  ip_var="NODE${n}_IP"; ip="${!ip_var}"
  check_dns_contains "node${n} ($ip) SOA for ${AUTH_ZONE}"    "$ip" "$AUTH_PORT" "$AUTH_ZONE"  SOA "$AUTH_ZONE"
  check_dns_contains "node${n} ($ip) NS  for ${AUTH_ZONE}"    "$ip" "$AUTH_PORT" "$AUTH_ZONE"  NS  "$NS1"
  check_dns          "node${n} ($ip) A   for ${AUTH_RECORD}"  "$ip" "$AUTH_PORT" "$AUTH_RECORD" A
done

# ── Recursor DNS ───────────────────────────────────────────────────────────────
section "Recursor DNS — direct on port ${RECURSOR_PORT}"

for n in 1 2 3; do
  ip_var="NODE${n}_IP"; ip="${!ip_var}"
  check_dns "node${n} ($ip) resolve ${RECURSIVE_TEST}" "$ip" "$RECURSOR_PORT" "$RECURSIVE_TEST" A
done

# ── dnsdist Routing ────────────────────────────────────────────────────────────
section "dnsdist — routing on port ${DNSDIST_PORT}"

for n in 1 2 3; do
  ip_var="NODE${n}_IP"; ip="${!ip_var}"
  check_dns_contains "node${n} ($ip) dnsdist → auth zone SOA"          "$ip" "$DNSDIST_PORT" "$AUTH_ZONE"       SOA "$AUTH_ZONE"
  check_dns          "node${n} ($ip) dnsdist → auth record ($AUTH_RECORD)" "$ip" "$DNSDIST_PORT" "$AUTH_RECORD"  A
  check_dns          "node${n} ($ip) dnsdist → recursive ($RECURSIVE_TEST)" "$ip" "$DNSDIST_PORT" "$RECURSIVE_TEST" A
done

# ── Cross-Node Fallback Backends ───────────────────────────────────────────────
section "Cross-Node — fallback backends reachability"

check_dns "node2 auth ($NODE2_IP:${AUTH_PORT}) reachable from node1" "$NODE2_IP" "$AUTH_PORT" "$AUTH_ZONE" SOA
check_dns "node3 auth ($NODE3_IP:${AUTH_PORT}) reachable from node1" "$NODE3_IP" "$AUTH_PORT" "$AUTH_ZONE" SOA
check_dns "node1 auth ($NODE1_IP:${AUTH_PORT}) reachable from node2" "$NODE1_IP" "$AUTH_PORT" "$AUTH_ZONE" SOA

check_dns "node2 recursor ($NODE2_IP:${RECURSOR_PORT}) resolve ${RECURSIVE_TEST}" "$NODE2_IP" "$RECURSOR_PORT" "$RECURSIVE_TEST" A
check_dns "node3 recursor ($NODE3_IP:${RECURSOR_PORT}) resolve ${RECURSIVE_TEST}" "$NODE3_IP" "$RECURSOR_PORT" "$RECURSIVE_TEST" A
check_dns "node1 recursor ($NODE1_IP:${RECURSOR_PORT}) resolve ${RECURSIVE_TEST}" "$NODE1_IP" "$RECURSOR_PORT" "$RECURSIVE_TEST" A

# ── Summary ────────────────────────────────────────────────────────────────────
section "Summary"
echo "  Total: $((PASS + FAIL))   Pass: $PASS   Fail: $FAIL"

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
  echo -e "\n  ${RED}${BOLD}Failed tests:${NC}"
  for t in "${FAILED_TESTS[@]}"; do
    echo -e "    ${RED}✗${NC} $t"
  done
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}All tests passed ✓${NC}"
else
  echo -e "  ${RED}${BOLD}${FAIL} test(s) failed ✗${NC}"
fi

exit $FAIL
