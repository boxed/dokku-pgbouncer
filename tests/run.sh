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
  # The plugin keeps its rename marker under $DOKKU_LIB_ROOT/data/pgbouncer.
  export STATE CALLS DOKKU_LIB_ROOT="$STATE"
  touch "$STATE/app_myapp"
  printf '' >"$STATE/apc_myapp"
  printf 'postgres://postgres:secret123@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
  printf 'postgres:16.2' >"$STATE/container_dokku.postgres.mydb"
  touch "$STATE/image_postgres_16.2"
  printf 'true' >"$STATE/deployed_myapp"
  printf 'true' >"$STATE/running_myapp"
}

marker() { [[ -e "$STATE/data/pgbouncer/renaming.$1" ]]; }
note() { [[ -e "$STATE/data/pgbouncer/deleting.$1" ]]; }

run() {
  OUT=$("$ROOT/commands" "$@" 2>&1)
  RC=$?
  return 0
}

# Runs a dokku trigger hook (post-delete, post-app-rename) the way dokku would.
run_hook() {
  OUT=$("$ROOT/$1" "${@:2}" 2>&1)
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
# Whole-line match against the call log, so 'ps:restart myapp' does not also
# match 'ps:restart myapp-pgbouncer'.
called() { grep -qxF "$1" "$CALLS" || { echo "  expected the call '$1'"; return 1; }; }
times() { grep -cxF "$1" "$CALLS"; }
# Swallows stdout: the diagnostics a helper prints when it "fails" are exactly
# what is expected here.
not() { ! "$@" >/dev/null; }
hasnt() { [[ "$1" != *"$2"* ]] || { echo "  expected NOT to contain '$2'"; return 1; }; }

# --- 1. happy path -----------------------------------------------------------
setup "connect happy path"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "PGBOUNCER_URL" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://postgres:secret123@myapp-pgbouncer.web:6432/mydb"
check "PGBOUNCER_HOST" eq "$(cfg myapp PGBOUNCER_HOST)" "myapp-pgbouncer.web"
check "DB_NAME" eq "$(cfg myapp-pgbouncer DB_NAME)" "mydb"
check "DB_PORT" eq "$(cfg myapp-pgbouncer DB_PORT)" "5432"
check "listen port pinned" eq "$(cfg myapp-pgbouncer LISTEN_PORT)" "6432"
check "clients must authenticate" eq "$(cfg myapp-pgbouncer AUTH_TYPE)" "scram-sha-256"
check "admin console closed" hasnt "$(cfg myapp-pgbouncer ADMIN_USERS)" "postgres"
check "marker set" eq "$(cfg myapp-pgbouncer DOKKU_PGBOUNCER_DB_SERVICE)" "mydb"
check "deployed image recorded" eq "$(cfg myapp-pgbouncer DOKKU_PGBOUNCER_IMAGE)" "edoburu/pgbouncer:v1.25.2-p0"
check "post-start-network" eq "$(psn mydb)" "pgbouncer-myapp"
check "DATABASE_URL kept" eq "$(cfg myapp DATABASE_URL)" "postgres://postgres:secret123@dokku-postgres-mydb:5432/mydb"
check "postgres on network" has "$(members pgbouncer-myapp)" "dokku.postgres.mydb"
check "app on network" has "$(members pgbouncer-myapp)" "myapp.web.1"
check "probe reuses service image" has "$(cat "$CALLS")" "docker run --rm --network pgbouncer-myapp -e PGPASSWORD -e PGCONNECT_TIMEOUT=5 postgres:16.2 psql"
check "probe runs a query" has "$(cat "$CALLS")" "SELECT 1"
check "probe keeps the password out of argv" hasnt "$(grep '^docker run' "$CALLS")" "secret123"
check "no image pulled" hasnt "$(cat "$CALLS")" "docker pull"
# dokku's config:set echoes the values it sets unless DOKKU_QUIET_OUTPUT is on,
# which would print the password and the password-bearing PGBOUNCER_URL.
check "bouncer credentials set quietly" has "$(grep 'DB_PASSWORD=' "$CALLS")" "dokku [quiet] config:set"
check "PGBOUNCER_URL set quietly" has "$(grep 'PGBOUNCER_URL=' "$CALLS")" "dokku [quiet] config:set"
check "tuning defaults applied" eq "$(cfg myapp-pgbouncer POOL_MODE)" "transaction"
check "prepared statements survive transaction mode" eq "$(cfg myapp-pgbouncer MAX_PREPARED_STATEMENTS)" "100"
# Silently ignoring 'options' would let a client's search_path be dropped and
# its queries read the wrong schema; a rejected connection is the safer default.
check "startup parameters not silently ignored" eq "$(cfg myapp-pgbouncer IGNORE_STARTUP_PARAMETERS)" ""

# --- 1b. percent-encoded database name --------------------------------------
setup "percent-encoded database name"
printf 'postgres://postgres:secret123@dokku-postgres-mydb:5432/my%%2Ddb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "pgbouncer gets the real name" eq "$(cfg myapp-pgbouncer DB_NAME)" "my-db"
check "url keeps encoding" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://postgres:secret123@myapp-pgbouncer.web:6432/my%2Ddb"

# --- 2. percent-encoded credentials, '@' in password -------------------------
setup "percent-encoded credentials"
printf 'postgres://us%%65r:p%%40ss@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "user decoded" eq "$(cfg myapp-pgbouncer DB_USER)" "user"
check "password decoded" eq "$(cfg myapp-pgbouncer DB_PASSWORD)" "p@ss"
check "url keeps encoding" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://us%65r:p%40ss@myapp-pgbouncer.web:6432/mydb"

# The authority ends at the first '/', so an unencoded '@' in the password is
# still part of the userinfo rather than a second split point.
setup "unencoded '@' in the password"
printf 'postgres://postgres:p@ss@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "password kept whole" eq "$(cfg myapp-pgbouncer DB_PASSWORD)" "p@ss"
check "host parsed" eq "$(cfg myapp-pgbouncer DB_HOST)" "dokku.postgres.mydb"

# Splitting the whole URL on its last '@' would take the one in the path and
# leave 'db' as the host; the authority split has to happen before the path.
setup "unencoded '@' in the database name"
printf 'postgres://postgres:secret123@dokku-postgres-mydb:5432/my@db' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "blames the database name, not the host" has "$OUT" "database name 'my@db'"

# "$(urldecode ...)" used to strip the trailing newline, so this password
# reached pgbouncer truncated instead of being rejected.
setup "password with a trailing newline"
printf 'postgres://postgres:secret%%0A@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "names the problem" has "$OUT" "password contains quotes, whitespace"

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
check "dbname has no query" eq "$(cfg myapp-pgbouncer DB_NAME)" "mydb"
check "warns about query" has "$OUT" "Ignoring the query string"
check "warns about TLS" has "$OUT" "asks for TLS"
check "url has no query" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://postgres:secret123@myapp-pgbouncer.web:6432/mydb"

# --- 5. values the image cannot be handed safely ----------------------------
# The entrypoint interpolates the identifiers into a printf format string and
# into a grep regex, so they are checked against an allowlist.
setup "unsafe database name"
printf 'postgres://postgres:secret123@dokku-postgres-mydb:5432/my%%20db' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "names the field" has "$OUT" "database name 'my db'"

setup "database name with a printf conversion in it"
printf 'postgres://postgres:secret123@dokku-postgres-mydb:5432/my%%25sdb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "names the field" has "$OUT" "database name 'my%sdb'"

setup "unsafe user"
printf 'postgres://po%%22stgres:secret123@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "names the field" has "$OUT" "database user"

setup "unsafe password"
printf 'postgres://postgres:sec%%20ret@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "names the field" has "$OUT" "database password contains"

setup "unsafe service name"
run pgbouncer:connect myapp 'my db'
check "fails" eq "$RC" "1"
check "names the field" has "$OUT" "postgres service name 'my db'"

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

# The pgbouncer app's own networks are merged too: an operator may have attached
# it to a network of their own, and a re-run must not take it off again.
setup "connect keeps the other networks of the pgbouncer app"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_monitoring"
printf 'false' >"$STATE/deployed_myapp-pgbouncer"
printf 'monitoring' >"$STATE/apc_myapp-pgbouncer"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "both networks kept" eq "$(apc myapp-pgbouncer)" "monitoring pgbouncer-myapp"
run pgbouncer:connect myapp mydb
check "re-run exits 0" eq "$RC" "0"
check "no duplicate on a re-run" eq "$(apc myapp-pgbouncer)" "monitoring pgbouncer-myapp"

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

check "no needless restart of an app that was not pooled" not called "dokku ps:restart myapp"

# A re-run over a *working* setup reconfigures and restarts the live pooler
# before verifying it. Unsetting PGBOUNCER_URL is then not enough: the app's
# containers still carry it, so they keep querying the pgbouncer that just
# failed verification while dokku config says the app is on direct postgres.
setup "a failed re-run takes the app and the pooler back"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp" "$STATE/failverify"
printf 'true' >"$STATE/deployed_myapp-pgbouncer"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'edoburu/pgbouncer:v1.25.2-p0' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_IMAGE"
printf 'oldsecret' >"$STATE/cfg_myapp-pgbouncer_DB_PASSWORD"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
printf 'pgbouncer-myapp' >"$STATE/apc_myapp"
printf 'dokku.postgres.mydb\nmyapp.web.1\n' >"$STATE/netmembers_pgbouncer-myapp"
printf 'myapp-pgbouncer.web' >"$STATE/cfg_myapp_PGBOUNCER_HOST"
printf 'postgres://postgres:oldsecret@myapp-pgbouncer.web:6432/mydb' >"$STATE/cfg_myapp_PGBOUNCER_URL"
# A rotated password pgbouncer turns out not to be able to use.
printf 'postgres://postgres:rotated456@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "url removed" eq "$(cfg myapp PGBOUNCER_URL)" ""
check "app restarted so its containers follow the config" called "dokku ps:restart myapp"
check "says the app is being moved back" has "$OUT" "drop back to direct postgres"
check "pooler config restored" eq "$(cfg myapp-pgbouncer DB_PASSWORD)" "oldsecret"
check "pooler restarted with the restored config" eq "$(times "dokku ps:restart myapp-pgbouncer")" "2"
check "restored config not echoed" has "$(grep 'DB_PASSWORD=oldsecret' "$CALLS")" "dokku [quiet] config:set"

setup "rollback when restart fails"
printf 'othernet' >"$STATE/apc_myapp"
touch "$STATE/net_othernet" "$STATE/fail_ps_restart_myapp"
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

# An unreadable post-start-network cannot be read as "unset": that is the one
# reading that goes on to claim a service which may already back another app.
setup "connect refuses a service whose post-start-network cannot be read"
printf 'othernet' >"$STATE/apc_myapp"
touch "$STATE/net_othernet" "$STATE/pgfail_mydb"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "explains why" has "$OUT" "Could not read the post-start-network"
check "nothing created" eq "$(apc myapp)" "othernet"
check "no network created" not called "dokku network:create pgbouncer-myapp"
check "no app created" not called "dokku apps:create myapp-pgbouncer"

# The teardown paths make the opposite call: an unreadable value may be another
# app's, so it is left alone — and the operator is told it may need clearing.
setup "disconnect says what to do when post-start-network cannot be read"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp" "$STATE/pgfail_mydb"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
run pgbouncer:disconnect myapp
check "exits 0" eq "$RC" "0"
check "left alone" eq "$(psn mydb)" "pgbouncer-myapp"
check "tells the operator how to clear it" has "$OUT" "post-start-network \"\""
check "teardown still finished" gone "app_myapp-pgbouncer"

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
printf 'hunter2' >"$STATE/cfg_myapp-pgbouncer_DB_PASSWORD"
printf 'legacyhunter2' >"$STATE/cfg_myapp-pgbouncer_DATABASES_PASSWORD"
printf 'postgres://postgres:urlhunter2@dokku.postgres.mydb:5432/mydb' >"$STATE/cfg_myapp-pgbouncer_DATABASE_URL"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DB_NAME"
run pgbouncer:info myapp
check "exits 0" eq "$RC" "0"
check "password hidden" hasnt "$OUT" "hunter2"
check "redaction marker" has "$OUT" "[redacted]"
check "other keys shown" has "$OUT" "DB_NAME:  mydb"

setup "info follows a renamed app"
touch "$STATE/app_newname" "$STATE/app_oldname-pgbouncer"
printf 'oldname-pgbouncer.web' >"$STATE/cfg_newname_PGBOUNCER_HOST"
printf 'mydb' >"$STATE/cfg_oldname-pgbouncer_DB_NAME"
run pgbouncer:info newname
check "exits 0" eq "$RC" "0"
check "reads the recorded app" has "$OUT" "DB_NAME:  mydb"

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

# --- 15. a taken target service must not disturb the working setup -----------
# The conflict check has to run before the previous service is released:
# otherwise naming a taken service tears down this app's working pgbouncer and
# only then aborts.
setup "repointing onto a taken service leaves everything alone"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp"
printf 'true' >"$STATE/deployed_myapp-pgbouncer"
printf 'otherdb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-myapp' >"$STATE/psn_otherdb"        # the working setup
printf 'pgbouncer-otherapp' >"$STATE/psn_mydb"        # target is already taken
printf 'postgres:16.2' >"$STATE/container_dokku.postgres.otherdb"
printf 'dokku.postgres.otherdb\nmyapp.web.1\n' >"$STATE/netmembers_pgbouncer-myapp"
printf 'postgres://postgres:secret123@myapp-pgbouncer.web:6432/otherdb' >"$STATE/cfg_myapp_PGBOUNCER_URL"
printf 'pgbouncer-myapp' >"$STATE/apc_myapp"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "explains the conflict" has "$OUT" "can only back one pgbouncer"
check "old service still claimed" eq "$(psn otherdb)" "pgbouncer-myapp"
check "old container still attached" has "$(members pgbouncer-myapp)" "dokku.postgres.otherdb"
check "did not touch the target" eq "$(psn mydb)" "pgbouncer-otherapp"
check "working url intact" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://postgres:secret123@myapp-pgbouncer.web:6432/otherdb"
check "networks intact" eq "$(apc myapp)" "pgbouncer-myapp"
check "did not detach anything" hasnt "$(cat "$CALLS")" "docker network disconnect"

# A failure *after* the detach has to put the previous service back.
setup "rollback restores the previously connected service"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp" "$STATE/failverify"
printf 'true' >"$STATE/deployed_myapp-pgbouncer"
printf 'otherdb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'dokku.postgres.otherdb' >"$STATE/cfg_myapp-pgbouncer_DB_HOST"
printf 'pgbouncer-myapp' >"$STATE/psn_otherdb"
printf 'postgres:16.2' >"$STATE/container_dokku.postgres.otherdb"
printf 'dokku.postgres.otherdb\nmyapp.web.1\n' >"$STATE/netmembers_pgbouncer-myapp"
printf 'pgbouncer-myapp' >"$STATE/apc_myapp"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "old service reclaimed" eq "$(psn otherdb)" "pgbouncer-myapp"
check "old container reattached" has "$(members pgbouncer-myapp)" "dokku.postgres.otherdb"
check "target service released" eq "$(psn mydb)" ""
check "target container detached" hasnt "$(members pgbouncer-myapp)" "dokku.postgres.mydb"
# The pooler's own record has to come back too: it is what disconnect acts on,
# so leaving it naming the service the rollback just released would point the
# teardown at the wrong postgres service.
check "pooler still records the old service" eq "$(cfg myapp-pgbouncer DOKKU_PGBOUNCER_DB_SERVICE)" "otherdb"
check "pooler still points at the old host" eq "$(cfg myapp-pgbouncer DB_HOST)" "dokku.postgres.otherdb"

# --- 16. service names dokku-postgres allows ---------------------------------
# dokku-postgres builds the host with `tr ._ -`, so an underscore in the service
# name becomes a dash in DATABASE_URL. Underscores are legal in service names.
setup "service name containing an underscore"
printf 'postgres://postgres:secret123@dokku-postgres-my-db:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
printf 'postgres:16.2' >"$STATE/container_dokku.postgres.my_db"
run pgbouncer:connect myapp my_db
check "exits 0" eq "$RC" "0"
check "no mismatch complaint" hasnt "$OUT" "different postgres service"
check "no mismatch warning" hasnt "$OUT" "does not look like"
check "host points at the service" eq "$(cfg myapp-pgbouncer DB_HOST)" "dokku.postgres.my_db"

# The container-name form of the host has to fail hard on a mismatch too, or the
# guard only catches whichever spelling it happens to recognise.
setup "wrong service argument, container-name host form"
printf 'postgres://postgres:secret123@dokku.postgres.otherdb:5432/otherdb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "explains mismatch" has "$OUT" "different postgres service"
check "app untouched" eq "$(cfg myapp PGBOUNCER_URL)" ""

# --- 17. port validation ----------------------------------------------------
setup "non-numeric port"
printf 'postgres://postgres:secret123@dokku-postgres-mydb:54 32/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "names the problem" has "$OUT" "non-numeric port"
check "nothing configured" eq "$(cfg myapp-pgbouncer DB_PORT)" ""

# --- 18. disconnect finishes the teardown even if the app cannot restart -----
setup "disconnect continues when the app cannot restart"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp" "$STATE/fail_ps_restart_myapp"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-myapp' >"$STATE/apc_myapp"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
printf 'x' >"$STATE/cfg_myapp_PGBOUNCER_URL"
run pgbouncer:disconnect myapp
check "exits 0" eq "$RC" "0"
check "warns about the restart" has "$OUT" "Failed to restart myapp"
check "url removed" eq "$(cfg myapp PGBOUNCER_URL)" ""
check "service released" eq "$(psn mydb)" ""
check "bouncer app destroyed" gone "app_myapp-pgbouncer"
check "network destroyed" gone "net_pgbouncer-myapp"

setup "disconnect after the app was destroyed by hand"
rm -f "$STATE/app_myapp"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
run pgbouncer:disconnect myapp
check "exits 0" eq "$RC" "0"
check "says so" has "$OUT" "only tearing down the pgbouncer side"
check "service released" eq "$(psn mydb)" ""
check "bouncer app destroyed" gone "app_myapp-pgbouncer"
check "network destroyed" gone "net_pgbouncer-myapp"

# --- 19. disconnect after apps:rename ---------------------------------------
# Every name is derived from the app name, but PGBOUNCER_HOST recorded on the
# app itself survives the rename and still points at the real bouncer app.
setup "disconnect finds the bouncer app of a renamed app"
touch "$STATE/app_newname" "$STATE/app_oldname-pgbouncer" "$STATE/net_pgbouncer-oldname"
printf 'oldname-pgbouncer.web' >"$STATE/cfg_newname_PGBOUNCER_HOST"
printf 'x' >"$STATE/cfg_newname_PGBOUNCER_URL"
printf 'mydb' >"$STATE/cfg_oldname-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-oldname' >"$STATE/cfg_oldname-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-oldname' >"$STATE/apc_newname"
printf 'pgbouncer-oldname' >"$STATE/psn_mydb"
run pgbouncer:disconnect newname
check "exits 0" eq "$RC" "0"
check "notices the rename" has "$OUT" "records its pgbouncer as 'oldname-pgbouncer'"
check "url removed" eq "$(cfg newname PGBOUNCER_URL)" ""
check "network detached" eq "$(apc newname)" ""
check "old bouncer destroyed" gone "app_oldname-pgbouncer"
check "old network destroyed" gone "net_pgbouncer-oldname"
check "service released" eq "$(psn mydb)" ""

# --- 20. post-delete cleans up after apps:destroy ---------------------------
setup "post-delete releases everything the app left behind"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
printf 'dokku.postgres.mydb\n' >"$STATE/netmembers_pgbouncer-myapp"
rm -f "$STATE/app_myapp" # dokku has already destroyed it
run_hook post-delete myapp
check "exits 0" eq "$RC" "0"
check "bouncer app destroyed" gone "app_myapp-pgbouncer"
check "service released" eq "$(psn mydb)" ""
check "container detached" hasnt "$(members pgbouncer-myapp)" "dokku.postgres.mydb"
check "network destroyed" gone "net_pgbouncer-myapp"

setup "post-delete ignores apps this plugin does not own"
touch "$STATE/app_myapp-pgbouncer"
printf 'someone-elses-secret' >"$STATE/cfg_myapp-pgbouncer_IMPORTANT"
run_hook post-delete myapp
check "exits 0" eq "$RC" "0"
check "foreign app kept" kept "app_myapp-pgbouncer"
check "foreign config intact" eq "$(cfg myapp-pgbouncer IMPORTANT)" "someone-elses-secret"

# Destroying our own bouncer app must not make the hook recurse.
setup "post-delete is a no-op for the bouncer app itself"
run_hook post-delete myapp-pgbouncer
check "exits 0" eq "$RC" "0"
check "did nothing" eq "$(cat "$CALLS")" "dokku config:get myapp-pgbouncer-pgbouncer DOKKU_PGBOUNCER_DB_SERVICE"

# --- 20b. destroying a renamed app ------------------------------------------
# post-delete can only derive '<app>-pgbouncer', which is not the name of the
# pgbouncer app of an app that has been renamed — and by then PGBOUNCER_HOST,
# the pointer that survives a rename, is gone with the app. pre-delete resolves
# it while the app still exists.
setup "post-delete cleans up after destroying a renamed app"
touch "$STATE/app_newname" "$STATE/app_oldname-pgbouncer" "$STATE/net_pgbouncer-oldname"
printf 'oldname-pgbouncer.web' >"$STATE/cfg_newname_PGBOUNCER_HOST"
printf 'mydb' >"$STATE/cfg_oldname-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-oldname' >"$STATE/cfg_oldname-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-oldname' >"$STATE/psn_mydb"
printf 'dokku.postgres.mydb\n' >"$STATE/netmembers_pgbouncer-oldname"
run_hook pre-delete newname some-image-tag
check "pre-delete exits 0" eq "$RC" "0"
check "note written" note newname
rm -f "$STATE/app_newname" # dokku destroys the app between the two hooks
run_hook post-delete newname
check "post-delete exits 0" eq "$RC" "0"
check "follows the note" has "$OUT" "recorded its pgbouncer as 'oldname-pgbouncer'"
check "bouncer app destroyed" gone "app_oldname-pgbouncer"
check "service released" eq "$(psn mydb)" ""
check "container detached" hasnt "$(members pgbouncer-oldname)" "dokku.postgres.mydb"
check "network destroyed" gone "net_pgbouncer-oldname"
check "note consumed" not note newname

setup "pre-delete writes no note when the derived name is still right"
touch "$STATE/app_myapp-pgbouncer"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
run_hook pre-delete myapp some-image-tag
check "exits 0" eq "$RC" "0"
check "no note" not note myapp

# dokku aborts the destroy if any pre-delete trigger returns non-zero, and
# post-delete — the only thing that consumes a note — then never runs. A note
# left behind that way must not be believed by the next destroy: it names the
# pgbouncer app the setup used to have, so post-delete would find no marker on it
# and skip the teardown for the pooler that really is there.
setup "a stale delete note does not disable the next teardown"
touch "$STATE/app_newname" "$STATE/app_oldname-pgbouncer"
printf 'oldname-pgbouncer.web' >"$STATE/cfg_newname_PGBOUNCER_HOST"
printf 'mydb' >"$STATE/cfg_oldname-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
run_hook pre-delete newname some-image-tag
check "note written" note newname
# The destroy is aborted. The operator then brings the names back in line, which
# is what post-app-rename tells them to do, so the app owns 'newname-pgbouncer'.
rm -f "$STATE/app_oldname-pgbouncer" "$STATE/cfg_oldname-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
touch "$STATE/app_newname-pgbouncer" "$STATE/net_pgbouncer-newname"
printf 'newname-pgbouncer.web' >"$STATE/cfg_newname_PGBOUNCER_HOST"
printf 'mydb' >"$STATE/cfg_newname-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-newname' >"$STATE/cfg_newname-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-newname' >"$STATE/psn_mydb"
run_hook pre-delete newname some-image-tag
check "stale note cleared" not note newname
rm -f "$STATE/app_newname" # dokku destroys the app between the two hooks
run_hook post-delete newname
check "post-delete exits 0" eq "$RC" "0"
check "the pooler it really has is destroyed" gone "app_newname-pgbouncer"
check "service released" eq "$(psn mydb)" ""
check "network destroyed" gone "net_pgbouncer-newname"

setup "pre-delete is a no-op for an app without pgbouncer"
run_hook pre-delete myapp some-image-tag
check "exits 0" eq "$RC" "0"
check "no note" not note myapp

# Renaming an app that was already renamed once must still be recognised as a
# rename, or the delete note would point post-delete at a live setup.
setup "renaming an already-renamed app keeps its setup"
touch "$STATE/app_newname" "$STATE/app_oldname-pgbouncer" "$STATE/net_pgbouncer-oldname"
printf 'oldname-pgbouncer.web' >"$STATE/cfg_newname_PGBOUNCER_HOST"
printf 'mydb' >"$STATE/cfg_oldname-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-oldname' >"$STATE/cfg_oldname-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-oldname' >"$STATE/psn_mydb"
run_hook post-app-rename-setup newname newname2
check "setup hook exits 0" eq "$RC" "0"
check "marker written for the current name" marker newname
run_hook pre-delete newname some-image-tag
run_hook post-delete newname
check "post-delete exits 0" eq "$RC" "0"
check "says it is a rename" has "$OUT" "being renamed"
check "bouncer app kept" kept "app_oldname-pgbouncer"
check "service still claimed" eq "$(psn mydb)" "pgbouncer-oldname"
check "network kept" kept "net_pgbouncer-oldname"
check "marker consumed" not marker newname
check "note cleared too" not note newname

# --- 20c. destroying the pooler itself --------------------------------------
setup "pre-delete warns when the pgbouncer app itself is destroyed"
touch "$STATE/app_myapp-pgbouncer"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'myapp-pgbouncer.web' >"$STATE/cfg_myapp_PGBOUNCER_HOST"
run_hook pre-delete myapp-pgbouncer some-image-tag
check "exits 0" eq "$RC" "0"
check "names the app it serves" has "$OUT" "pgbouncer app of myapp"
check "points at the supported teardown" has "$OUT" "pgbouncer:disconnect myapp"
check "no note for the pooler" not note myapp-pgbouncer

# pgbouncer:disconnect unsets PGBOUNCER_HOST before destroying the pgbouncer
# app, so the warning above must not fire on its way through.
setup "pre-delete stays quiet when nothing points at the pooler any more"
touch "$STATE/app_myapp-pgbouncer"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
run_hook pre-delete myapp-pgbouncer some-image-tag
check "exits 0" eq "$RC" "0"
check "says nothing" hasnt "$OUT" "pgbouncer app of"

# --- 20d. two commands at once ------------------------------------------------
# connect decides a postgres service is free and only then claims it; two runs
# racing through that window would both decide it, and the loser's app would be
# detached from its network on the next postgres restart.
if command -v flock >/dev/null 2>&1; then
  setup "connect refuses to race another pgbouncer command"
  mkdir -p "$STATE/data/pgbouncer"
  (flock 9 && sleep 5) 9>"$STATE/data/pgbouncer/plugin.lock" &
  HOLDER=$!
  sleep 0.3
  export PGBOUNCER_LOCK_WAIT=1
  run pgbouncer:connect myapp mydb
  unset PGBOUNCER_LOCK_WAIT
  kill "$HOLDER" 2>/dev/null
  wait "$HOLDER" 2>/dev/null
  check "fails instead of racing" eq "$RC" "1"
  check "names the other command" has "$OUT" "holding"
  check "service not claimed" eq "$(psn mydb)" ""
  check "app untouched" eq "$(cfg myapp PGBOUNCER_URL)" ""
else
  setup "connect says it cannot serialise itself without flock"
  run pgbouncer:connect myapp mydb
  check "exits 0" eq "$RC" "0"
  check "warns" has "$OUT" "cannot be serialised"
fi

# --- 21. bare command shows usage -------------------------------------------
setup "bare pgbouncer command"
run pgbouncer
check "exits 0" eq "$RC" "0"
check "shows usage" has "$OUT" "Usage: dokku pgbouncer"
check "lists connect" has "$OUT" "pgbouncer:connect"

# --- 22. re-running connect ---------------------------------------------------
# 'dokku git:from-image' returns non-zero when the committed "FROM <image>" is
# unchanged, which is exactly what a re-run against a pinned image produces.
# Treating that as a deploy failure rolled the working setup back onto direct
# postgres — and re-running is the documented way to apply rotated credentials.
setup "re-running connect keeps the setup and applies new credentials"
run pgbouncer:connect myapp mydb
check "first connect succeeds" eq "$RC" "0"
printf 'postgres://postgres:rotated456@dokku-postgres-mydb:5432/mydb' >"$STATE/cfg_myapp_DATABASE_URL"
: >"$CALLS"
run pgbouncer:connect myapp mydb
check "second connect succeeds" eq "$RC" "0"
check "no redundant image deploy" hasnt "$(cat "$CALLS")" "git:from-image"
check "bouncer restarted instead" has "$(cat "$CALLS")" "ps:restart myapp-pgbouncer"
check "new password applied" eq "$(cfg myapp-pgbouncer DB_PASSWORD)" "rotated456"
check "app still pooled" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://postgres:rotated456@myapp-pgbouncer.web:6432/mydb"
check "service still claimed" eq "$(psn mydb)" "pgbouncer-myapp"
check "app still on the network" has "$(members pgbouncer-myapp)" "myapp.web.1"

setup "an operator's tuning override survives a re-run"
run pgbouncer:connect myapp mydb
check "first connect succeeds" eq "$RC" "0"
printf 'session' >"$STATE/cfg_myapp-pgbouncer_POOL_MODE"
run pgbouncer:connect myapp mydb
check "second connect succeeds" eq "$RC" "0"
check "override kept" eq "$(cfg myapp-pgbouncer POOL_MODE)" "session"
check "other defaults kept" eq "$(cfg myapp-pgbouncer DEFAULT_POOL_SIZE)" "20"
check "nothing to warn about" hasnt "$OUT" "default of session pooling"

# An app deployed by a version of this plugin that recorded no image still has
# to survive a re-run, via the "No changes detected" fallback.
setup "re-run of an app with no recorded image"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp"
printf 'true' >"$STATE/deployed_myapp-pgbouncer"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'edoburu/pgbouncer:v1.25.2-p0' >"$STATE/fromimage_myapp-pgbouncer"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
printf 'pgbouncer-myapp' >"$STATE/apc_myapp"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "tolerated the no-op deploy" has "$OUT" "already runs edoburu/pgbouncer"
check "image now recorded" eq "$(cfg myapp-pgbouncer DOKKU_PGBOUNCER_IMAGE)" "edoburu/pgbouncer:v1.25.2-p0"

setup "a changed image pin redeploys"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp"
printf 'true' >"$STATE/deployed_myapp-pgbouncer"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer/pgbouncer:1.15.0' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_IMAGE"
printf 'pgbouncer/pgbouncer:1.15.0' >"$STATE/fromimage_myapp-pgbouncer"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
printf 'pgbouncer-myapp' >"$STATE/apc_myapp"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "redeployed" has "$(cat "$CALLS")" "git:from-image myapp-pgbouncer edoburu/pgbouncer:v1.25.2-p0"
check "record updated" eq "$(cfg myapp-pgbouncer DOKKU_PGBOUNCER_IMAGE)" "edoburu/pgbouncer:v1.25.2-p0"

# A pooler of ours with no POOL_MODE was set up by 0.1.x, i.e. session pooling.
# Moving it to transaction pooling is a change of behaviour whose cost only shows
# up at runtime in the app, so it cannot pass silently.
setup "upgrading a pooler that had no POOL_MODE says what changes"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp"
printf 'true' >"$STATE/deployed_myapp-pgbouncer"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
printf 'pgbouncer-myapp' >"$STATE/apc_myapp"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "names what it was" has "$OUT" "default of session pooling"
check "names what breaks" has "$OUT" "LISTEN/NOTIFY"
check "says how to keep it" has "$OUT" "POOL_MODE=session"
check "transaction pooling applied" eq "$(cfg myapp-pgbouncer POOL_MODE)" "transaction"

setup "a first connect does not warn about pool mode"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "no warning" hasnt "$OUT" "default of session pooling"

# The plaintext password the old image needed must not be left in config:show.
setup "connect clears the legacy DATABASES_* config"
touch "$STATE/app_myapp-pgbouncer"
printf 'false' >"$STATE/deployed_myapp-pgbouncer"
printf 'oldsecret' >"$STATE/cfg_myapp-pgbouncer_DATABASES_PASSWORD"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DATABASES_DBNAME"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "legacy password gone" eq "$(cfg myapp-pgbouncer DATABASES_PASSWORD)" ""
check "legacy dbname gone" eq "$(cfg myapp-pgbouncer DATABASES_DBNAME)" ""

# --- 23. apps with nothing running -------------------------------------------
# dokku's ps:restart succeeds without doing anything on an undeployed app, so
# the network check three steps later would fail and blame the network.
setup "connect refuses an app that was never deployed"
printf 'false' >"$STATE/deployed_myapp"
run pgbouncer:connect myapp mydb
check "fails" eq "$RC" "1"
check "blames the missing deploy" has "$OUT" "no deployment yet"
check "nothing created" eq "$(apc myapp)" ""
check "service untouched" eq "$(psn mydb)" ""

setup "connect warns rather than rolls back when the app is scaled to zero"
printf 'false' >"$STATE/running_myapp"
touch "$STATE/nojoin"
run pgbouncer:connect myapp mydb
check "exits 0" eq "$RC" "0"
check "says why nothing attached" has "$OUT" "scaled to zero"
check "app still pointed at pgbouncer" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://postgres:secret123@myapp-pgbouncer.web:6432/mydb"
check "network still attached for next scale-up" eq "$(apc myapp)" "pgbouncer-myapp"

# --- 24. apps:rename must not tear the setup down ----------------------------
# dokku implements apps:rename as create-new + destroy-old, so post-delete
# fires for the old name mid-rename. Without the marker it destroys the
# pgbouncer app, releases the postgres service and removes the network, leaving
# the renamed app pointing at a host that no longer resolves.
setup "rename leaves the pgbouncer setup intact"
touch "$STATE/app_newname" "$STATE/app_oldname-pgbouncer" "$STATE/net_pgbouncer-oldname"
printf 'oldname-pgbouncer.web' >"$STATE/cfg_newname_PGBOUNCER_HOST"
printf 'mydb' >"$STATE/cfg_oldname-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-oldname' >"$STATE/cfg_oldname-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-oldname' >"$STATE/psn_mydb"
printf 'dokku.postgres.mydb\n' >"$STATE/netmembers_pgbouncer-oldname"
run_hook post-app-rename-setup oldname newname
check "setup hook exits 0" eq "$RC" "0"
check "marker written" marker oldname
run_hook post-delete oldname
check "post-delete exits 0" eq "$RC" "0"
check "says it is a rename" has "$OUT" "being renamed"
check "bouncer app kept" kept "app_oldname-pgbouncer"
check "service still claimed" eq "$(psn mydb)" "pgbouncer-oldname"
check "network kept" kept "net_pgbouncer-oldname"
check "postgres still attached" has "$(members pgbouncer-oldname)" "dokku.postgres.mydb"
check "marker consumed" not marker oldname
run_hook post-app-rename oldname newname
check "rename hook exits 0" eq "$RC" "0"
check "warns about the stale names" has "$OUT" "still uses the pgbouncer app 'oldname-pgbouncer'"
check "prints the fix" has "$OUT" "dokku pgbouncer:connect newname mydb"

# A real destroy after a rename must still clean up, i.e. the marker is
# consumed rather than left behind to disable the hook for good.
setup "a real destroy after a rename still cleans up"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
run_hook post-app-rename-setup myapp renamed
run_hook post-delete myapp # the rename's destroy
run_hook post-delete myapp # a later, genuine apps:destroy
check "exits 0" eq "$RC" "0"
check "bouncer app destroyed" gone "app_myapp-pgbouncer"
check "service released" eq "$(psn mydb)" ""

# dokku aborts the rename if a post-app-rename-setup trigger fails, and skips
# post-app-rename if the destroy fails — in both cases the marker survives with
# nothing left to clear it. Taken at face value it would disable the teardown for
# the next genuine apps:destroy, so it expires.
setup "an aborted rename does not disable the next destroy"
touch "$STATE/app_myapp-pgbouncer" "$STATE/net_pgbouncer-myapp"
printf 'mydb' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-myapp' >"$STATE/psn_mydb"
run_hook post-app-rename-setup myapp renamed
check "marker written" marker myapp
touch -t 200001010000 "$STATE/data/pgbouncer/renaming.myapp"
run_hook post-delete myapp
check "exits 0" eq "$RC" "0"
check "names the cause" has "$OUT" "aborted rename"
check "bouncer app destroyed" gone "app_myapp-pgbouncer"
check "service released" eq "$(psn mydb)" ""
check "network destroyed" gone "net_pgbouncer-myapp"

setup "rename hook clears a marker left by an aborted rename"
touch "$STATE/app_newname" "$STATE/app_oldname-pgbouncer"
printf 'mydb' >"$STATE/cfg_oldname-pgbouncer_DOKKU_PGBOUNCER_DB_SERVICE"
run_hook post-app-rename-setup oldname newname
run_hook post-app-rename oldname newname
check "exits 0" eq "$RC" "0"
check "marker cleared" not marker oldname

setup "rename of an app without pgbouncer writes no marker"
run_hook post-app-rename-setup myapp renamed
check "exits 0" eq "$RC" "0"
check "no marker" not marker myapp

# --- 25. apps:clone must not inherit another app's pgbouncer -----------------
setup "clone drops the inherited pgbouncer connection"
touch "$STATE/app_clone" "$STATE/app_myapp-pgbouncer"
printf 'myapp-pgbouncer.web' >"$STATE/cfg_clone_PGBOUNCER_HOST"
printf 'postgres://postgres:secret123@myapp-pgbouncer.web:6432/mydb' >"$STATE/cfg_clone_PGBOUNCER_URL"
printf '6432' >"$STATE/cfg_clone_PGBOUNCER_PORT"
printf 'pgbouncer-myapp' >"$STATE/cfg_myapp-pgbouncer_DOKKU_PGBOUNCER_NETWORK"
printf 'pgbouncer-myapp othernet' >"$STATE/apc_clone"
run_hook post-app-clone-setup myapp clone
check "exits 0" eq "$RC" "0"
check "url dropped" eq "$(cfg clone PGBOUNCER_URL)" ""
check "host dropped" eq "$(cfg clone PGBOUNCER_HOST)" ""
check "port dropped" eq "$(cfg clone PGBOUNCER_PORT)" ""
check "off the source app's private network" eq "$(apc clone)" "othernet"
check "unset quietly" has "$(cat "$CALLS")" "dokku [quiet] config:unset"

# Only an app that owns a pooler names it as '<itself>-pgbouncer'; a clone always
# inherits some other app's. So this is the signature of a hook that has not been
# handed (source, clone), and stripping the variables would break a working app.
setup "clone hook leaves an app that owns its pgbouncer alone"
touch "$STATE/app_clone" "$STATE/app_myapp-pgbouncer"
printf 'myapp-pgbouncer.web' >"$STATE/cfg_myapp_PGBOUNCER_HOST"
printf 'postgres://postgres:secret123@myapp-pgbouncer.web:6432/mydb' >"$STATE/cfg_myapp_PGBOUNCER_URL"
printf 'pgbouncer-myapp' >"$STATE/apc_myapp"
run_hook post-app-clone-setup clone myapp
check "exits 0" eq "$RC" "0"
check "says why" has "$OUT" "does not look like an inherited setup"
check "url kept" eq "$(cfg myapp PGBOUNCER_URL)" "postgres://postgres:secret123@myapp-pgbouncer.web:6432/mydb"
check "network kept" eq "$(apc myapp)" "pgbouncer-myapp"

# The hook reads the clone's copy of the config, which dokku's config plugin
# makes first only because 'pgbouncer' sorts after 'config'.
setup "clone hook speaks up when the clone has no config yet"
touch "$STATE/app_clone" "$STATE/app_myapp-pgbouncer"
printf 'myapp-pgbouncer.web' >"$STATE/cfg_myapp_PGBOUNCER_HOST"
printf 'othernet' >"$STATE/apc_clone"
run_hook post-app-clone-setup myapp clone
check "exits 0" eq "$RC" "0"
check "warns" has "$OUT" "has not been given its copy of the config"
check "networks untouched" eq "$(apc clone)" "othernet"

setup "clone of an app without pgbouncer is a no-op"
touch "$STATE/app_clone"
printf 'othernet' >"$STATE/apc_clone"
run_hook post-app-clone-setup myapp clone
check "exits 0" eq "$RC" "0"
check "networks untouched" eq "$(apc clone)" "othernet"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
