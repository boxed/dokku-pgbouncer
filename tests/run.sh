#!/usr/bin/env bash
# Exercises ./commands against stubbed dokku/docker CLIs.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/tests/bin:$PATH"
export PLUGIN_CORE_AVAILABLE_PATH="$ROOT/tests/core"

PASS=0 FAIL=0
CURRENT=""

# Each scenario gets a throwaway state dir; clear any left by an aborted run.
rm -rf "$ROOT"/tests/state.*
trap 'rm -rf "$ROOT"/tests/state.*' EXIT

setup() {
  CURRENT="$1"
  STATE=$(mktemp -d "$ROOT/tests/state.XXXXXX")
  CALLS="$STATE/calls.log"
  : >"$CALLS"
  export STATE CALLS
  touch "$STATE/app_myapp"
  printf '' >"$STATE/apc_myapp"
  printf 'postgres://postgres:secret123@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
  printf 'postgres:16.2' >"$STATE/container_dokku.postgres.mydb"
  touch "$STATE/image_postgres_16.2"
}

run() {
  OUT=$("$ROOT/commands" "$@" 2>&1)
  RC=$?
  return 0
}

check() {
  local what="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [$CURRENT] $what"
    echo "  rc=$RC"
    echo "  | ${OUT//$'\n'/$'\n'  | }"
  fi
}

cfg() { cat "$STATE/cfg_$1_$2" 2>/dev/null; }
psn() { cat "$STATE/psn_$1" 2>/dev/null; }
apc() { cat "$STATE/apc_$1" 2>/dev/null; }
members() { cat "$STATE/netmembers_$1" 2>/dev/null; }
eq() { [[ "$1" == "$2" ]] || { echo "  expected '$2', got '$1'"; return 1; }; }
gone() { [[ ! -e "$STATE/$1" ]] || { echo "  expected $1 to be gone"; return 1; }; }
kept() { [[ -e "$STATE/$1" ]] || { echo "  expected $1 to still exist"; return 1; }; }
has() { [[ "$1" == *"$2"* ]] || { echo "  expected to contain '$2'"; return 1; }; }
hasnt() { [[ "$1" != *"$2"* ]] || { echo "  expected NOT to contain '$2'"; return 1; }; }

# --- 1. happy path -----------------------------------------------------------
setup "connect happy path"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "PGBOUNCER_URL" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://postgres:secret123@myapp-pgbouncer.web:6432/mydb"
check "PGBOUNCER_HOST" eq "$(cfg myapp PGBOUNCER_HOST)" "myapp-pgbouncer.web"
check "DATABASES_DBNAME" eq "$(cfg myapp-pgbouncer DATABASES_DBNAME)" "mydb"
check "DATABASES_PORT" eq "$(cfg myapp-pgbouncer DATABASES_PORT)" "5432"
check "marker set" eq "$(cfg myapp-pgbouncer DOKKU_PGBOUNCER_DB_SERVICE)" "mydb"
check "post-start-network" eq "$(psn mydb)" "pgbouncer-myapp"
check "DATABASE_URL kept" eq "$(cfg myapp DATABASE_URL)" "postgres://postgres:secret123@dokku-postgres-mydb:5432/mydb"
check "postgres on network" has "$(members pgbouncer-myapp)" "dokku.postgres.mydb"
check "app on network" has "$(members pgbouncer-myapp)" "myapp.web.1"
check "probe reuses service image" has "$(cat "$CALLS")" "docker run --rm --network pgbouncer-myapp -e PGPASSWORD -e PGCONNECT_TIMEOUT=5 postgres:16.2 psql"
check "probe runs a query" has "$(cat "$CALLS")" "SELECT 1"
check "probe keeps the password out of argv" hasnt "$(grep '^docker run' "$CALLS")" "secret123"
check "no image pulled" hasnt "$(cat "$CALLS")" "docker pull"

# --- 1b. percent-encoded database name --------------------------------------
setup "percent-encoded database name"
printf 'postgres://postgres:secret123@dokku-postgres-mydb:5432/my%%2Ddb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "pgbouncer gets the real name" eq "$(cfg myapp-pgbouncer DATABASES_DBNAME)" "my-db"
check "url keeps encoding" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://postgres:secret123@myapp-pgbouncer.web:6432/my%2Ddb"

# --- 2. percent-encoded credentials, '@' in password -------------------------
setup "percent-encoded credentials"
printf 'postgres://us%%65r:p%%40ss@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "user decoded" eq "$(cfg myapp-pgbouncer DATABASES_USER)" "user"
check "password decoded" eq "$(cfg myapp-pgbouncer DATABASES_PASSWORD)" "p@ss"
check "url keeps encoding" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://us%65r:p%40ss@myapp-pgbouncer.web:6432/mydb"

# --- 3. service argument does not match DATABASE_URL host --------------------
setup "wrong service argument"
printf 'postgres://postgres:secret123@dokku-postgres-otherdb:5432/otherdb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "explains mismatch" has "$OUT" "different postgres service"
check "app untouched" eq "$(cfg myapp PGBOUNCER_URL)" ""
check "networks untouched" eq "$(apc myapp)" ""

# --- 4. query string on DATABASE_URL ----------------------------------------
setup "query string"
printf 'postgres://postgres:secret123@dokku-postgres-mydb:5432/mydb?sslmode=require' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "dbname has no query" eq "$(cfg myapp-pgbouncer DATABASES_DBNAME)" "mydb"
check "warns about query" has "$OUT" "Ignoring the query string"
check "warns about TLS" has "$OUT" "asks for TLS"
check "url has no query" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://postgres:secret123@myapp-pgbouncer.web:6432/mydb"

# --- 5. values that cannot be written into pgbouncer.ini --------------------
setup "unsafe database name"
printf 'postgres://postgres:secret123@dokku-postgres-mydb:5432/my%%20db' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "names the field" has "$OUT" "database name contains"

setup "unsafe user"
printf 'postgres://po%%22stgres:secret123@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "names the field" has "$OUT" "database user contains"

setup "unsafe password"
printf 'postgres://postgres:sec%%20ret@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "names the field" has "$OUT" "database password contains"

# --- 6. no password in DATABASE_URL -----------------------------------------
setup "no password"
printf 'postgres://postgres@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "accurate message" has "$OUT" "has no password"

setup "empty password"
printf 'postgres://postgres:@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "accurate message" has "$OUT" "empty password"

# --- 7. name collision with a foreign app -----------------------------------
setup "foreign app name collision"
touch "$STATE/app_myapp-pgbouncer"
printf 'true' >"$STATE/deployed_myapp-pgbouncer"
printf 'someone-elses-secret' >"$STATE/cfg_myapp-pgbouncer_IMPORTANT"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "refuses to overwrite" has "$OUT" "Refusing to overwrite"
check "foreign config intact" eq "$(cfg myapp-pgbouncer IMPORTANT)" "someone-elses-secret"
check "no image deployed over it" hasnt "$(cat "$CALLS")" "git:from-image"

setup "adopt empty app"
touch "$STATE/app_myapp-pgbouncer"
printf 'false' >"$STATE/deployed_myapp-pgbouncer"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "says adopting" has "$OUT" "adopting it"

# --- 8. repointing the app at a different postgres service -------------------
setup "reconnect to a different service"
touch "$STATE/app_myapp-pgbouncer"
printf 'true' >"$STATE/deployed_myapp-pgbouncer"
printf 'otherdb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-myapp' >"$STATE/psn_otherdb"
printf 'postgres:16.2' >"$STATE/container_dokku.postgres.otherdb"
touch "$STATE/net_pgbouncer-myapp"
printf 'dokku.postgres.otherdb\n' >"$STATE/netmembers_pgbouncer-myapp"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "old service released" eq "$(psn otherdb)" ""
check "old container detached" hasnt "$(members pgbouncer-myapp)" "dokku.postgres.otherdb"
check "new container attached" has "$(members pgbouncer-myapp)" "dokku.postgres.mydb"
check "new service set" eq "$(psn mydb)" "pgbouncer-myapp"
check "marker updated" eq "$(cfg myapp-pgbouncer DOKKU_PGBOUNCER_DB_SERVICE)" "mydb"

# --- 9. rollback on failure --------------------------------------------------
setup "rollback when the probe fails"
printf 'othernet' >"$STATE/apc_myapp"
touch "$STATE/net_othernet" "$STATE/failverify"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "reports the probe output" has "$OUT" "connection to server"
check "env vars rolled back" eq "$(cfg myapp PGBOUNCER_URL)" ""
check "networks restored" eq "$(apc myapp)" "othernet"

setup "rollback when rebuild fails"
printf 'othernet' >"$STATE/apc_myapp"
touch "$STATE/net_othernet" "$STATE/fail_ps_rebuild_myapp"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "env vars rolled back" eq "$(cfg myapp PGBOUNCER_URL)" ""
check "networks restored" eq "$(apc myapp)" "othernet"

setup "rollback when the service already backs another pgbouncer"
printf 'othernet' >"$STATE/apc_myapp"
touch "$STATE/net_othernet"
printf 'pgbouncer-otherapp' >"$STATE/psn_mydb"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "explains the conflict" has "$OUT" "can only back one pgbouncer"
check "networks restored" eq "$(apc myapp)" "othernet"
check "other pgbouncer untouched" eq "$(psn mydb)" "pgbouncer-otherapp"

setup "rollback when the image deploy fails"
printf 'othernet' >"$STATE/apc_myapp"
touch "$STATE/net_othernet" "$STATE/fail_git_from-image_myapp-pgbouncer"
printf 'x' >"$STATE/cfg_myapp_PGBOUNCER_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "stale url removed" eq "$(cfg myapp PGBOUNCER_URL)" ""
check "networks restored" eq "$(apc myapp)" "othernet"

setup "rollback when the app does not join the network"
printf 'othernet' >"$STATE/apc_myapp"
touch "$STATE/net_othernet" "$STATE/nojoin"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "explains the problem" has "$OUT" "did not join network"
check "env vars rolled back" eq "$(cfg myapp PGBOUNCER_URL)" ""
check "networks restored" eq "$(apc myapp)" "othernet"

# --- 10. connect is idempotent with a stopped postgres container -------------
setup "stopped postgres container already attached"
touch "$STATE/net_pgbouncer-myapp" "$STATE/stopped_dokku.postgres.mydb"
printf 'dokku.postgres.mydb\n' >"$STATE/netmembers_pgbouncer-myapp"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "sees existing membership" has "$OUT" "already on network"
check "does not re-connect" hasnt "$(cat "$CALLS")" "docker network connect"

# --- 11. missing postgres container -----------------------------------------
setup "postgres container missing"
rm -f "$STATE/container_dokku.postgres.mydb"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "clear message" has "$OUT" "Does postgres service"
check "nothing created" eq "$(apc myapp)" ""

# --- 12. disconnect ---------------------------------------------------------
setup "disconnect happy path"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-myapp othernet' >"$STATE/apc_myapp"
touch "$STATE/net_othernet"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
printf 'dokku.postgres.mydb\nmyapp.web.1\n' >"$STATE/netmembers_pgbouncer-myapp"
printf 'x' >"$STATE/cfg_myapp_PGBOUNCER_URL"
run pgbouncer:disconnect myapp
check "exits 0" eq "$RC" "0"
check "url removed" eq "$(cfg myapp PGBOUNCER_URL)" ""
check "other network kept" eq "$(apc myapp)" "othernet"
check "post-start-network cleared" eq "$(psn mydb)" ""
check "bouncer app destroyed" gone "app_myapp-pgbouncer"
check "network destroyed" gone "net_pgbouncer-myapp"

setup "disconnect refuses a foreign app"
touch "$STATE/app_myapp-pgbouncer"
printf 'x' >"$STATE/cfg_myapp_PGBOUNCER_URL"
printf 'pgbouncer-myapp' >"$STATE/apc_myapp"
run pgbouncer:disconnect myapp mydb
check "fails" eq "$RC" "1"
check "refuses" has "$OUT" "Refusing to destroy"
check "nothing unset yet" eq "$(cfg myapp PGBOUNCER_URL)" "x"
check "networks untouched" eq "$(apc myapp)" "pgbouncer-myapp"
check "app not destroyed" kept "app_myapp-pgbouncer"

setup "disconnect leaves another pgbouncer's post-start-network alone"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-otherapp' >"$STATE/psn_mydb"
run pgbouncer:disconnect myapp
check "exits 0" eq "$RC" "0"
check "left alone" eq "$(psn mydb)" "pgbouncer-otherapp"
check "says so" has "$OUT" "leaving it alone"

# --- 13. info ---------------------------------------------------------------
setup "info redacts the password"
touch "$STATE/app_myapp-pgbouncer"
printf 'hunter2' >"$STATE/cfg_myapp-pgbouncer_DATABASES_PASSWORD"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DATABASES_DBNAME"
run pgbouncer:info myapp
check "exits 0" eq "$RC" "0"
check "password hidden" hasnt "$OUT" "hunter2"
check "redaction marker" has "$OUT" "[redacted]"
check "other keys shown" has "$OUT" "DATABASES_DBNAME:  mydb"

# --- 14. argument validation ------------------------------------------------
setup "missing arguments"
run pgbouncer:connect
check "fails" eq "$RC" "1"
check "asks for app" has "$OUT" "specify a main app name"
run pgbouncer:connect myapp
check "fails" eq "$RC" "1"
check "asks for service" has "$OUT" "specify a postgres service name"
run pgbouncer:nonsense
check "not-implemented exit" eq "$RC" "10"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
