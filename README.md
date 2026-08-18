# dokku-pgbouncer

A [Dokku](https://dokku.com/) plugin that runs [PgBouncer](https://www.pgbouncer.org/) between your app and its PostgreSQL database. It handles the plumbing: parsing credentials, deploying the pgbouncer container, wiring up a private docker network, and publishing a `PGBOUNCER_URL` your app can opt into.

## Requirements

- Dokku
- [dokku-postgres](https://github.com/dokku/dokku-postgres) plugin
- A postgres service already linked to your app via `dokku postgres:link`
- The app deployed at least once (its containers have to be recreated to join the pgbouncer network)

## Installation

```bash
dokku plugin:install https://github.com/boxed/dokku-pgbouncer.git pgbouncer
```

## Commands

| Command | Description |
|---|---|
| `pgbouncer:connect <app> <service>` | Deploy pgbouncer for a postgres service and publish `PGBOUNCER_URL` on the app |
| `pgbouncer:disconnect <app> [<service>]` | Remove pgbouncer; the app falls back to `DATABASE_URL` |
| `pgbouncer:info <app>` | Show pgbouncer config for an app (password redacted) |

## Usage

### Add pgbouncer to an app

```bash
dokku pgbouncer:connect myapp my-database
```

This will:

1. Parse `DATABASE_URL` on your app to extract connection credentials
2. Create a private docker network (`pgbouncer-myapp`) shared by your app, pgbouncer, and the postgres service
3. Create a new dokku app (`myapp-pgbouncer`) running a pinned `edoburu/pgbouncer` image, with its http proxy disabled
4. Verify the database is actually usable through pgbouncer — a real `SELECT 1` from a throwaway container — **before** touching your app
5. Set `PGBOUNCER_URL`, `PGBOUNCER_HOST`, and `PGBOUNCER_PORT` on your app and restart it

`DATABASE_URL` is left untouched — your app decides which connection to use, so make it prefer `PGBOUNCER_URL` when that variable is set. If anything fails, every change this command made is rolled back — the env vars, the network attachment, the postgres service's `post-start-network` and network attachment, and the configuration of an existing pgbouncer app it had already rewritten, including any tuning default it filled in on that run — and the app keeps running on direct postgres. Interrupting the command with Ctrl-C rolls it back too.

Rolling back restarts your app whenever it was already pooled when the command started, because its running containers hold `PGBOUNCER_URL` in their environment: removing the variable moves the *next* deploy back to direct postgres, but not the containers that are serving traffic right now.

A plain TCP check would not be enough here: pgbouncer accepts clients as soon as it starts listening and only dials postgres on the first query, so wrong credentials or an unreachable postgres would pass a port check and then break your app at query time.

**Note:** the connect step restarts your app so its containers join the shared network, which means a brief interruption. It is a restart from the existing image rather than a rebuild, so it cannot fail on an unrelated build problem.

Re-running `pgbouncer:connect` is safe and is the supported way to apply changed credentials (e.g. after rotating the database password): the pgbouncer app is restarted with the current values parsed from `DATABASE_URL`, and the image is only redeployed when the pinned version actually changed. Re-running it against a *different* postgres service also releases the previous one (its `post-start-network` is cleared and its container detached), so the old service is not left permanently blocked from backing another pgbouncer. That release happens only after the new service has been checked for conflicts, and it is undone if a later step fails, so a rejected or failed repoint leaves your current setup running.

The service you name must be the one `DATABASE_URL` points at. Credentials come from the URL while the postgres hostname comes from the service argument, so naming the wrong service would otherwise hand pgbouncer one service's hostname with another's credentials; the plugin refuses when the two disagree.

### Remove pgbouncer from an app

```bash
dokku pgbouncer:disconnect myapp
```

The postgres service name is remembered from `pgbouncer:connect`; you only need to pass it explicitly if the pgbouncer app was already destroyed by hand. This removes the `PGBOUNCER_*` variables and restarts your app (back on direct `DATABASE_URL`), then destroys the pgbouncer app and the shared network.

The teardown always runs to completion. If your app cannot be restarted — scaled to zero, never deployed, no longer building — the command warns and carries on rather than aborting, because the remaining steps are the only thing that releases the postgres service's `post-start-network`. It also works when the app itself is already gone, and it follows `PGBOUNCER_HOST` rather than the `<app>-pgbouncer` naming convention, so it still finds the right pgbouncer app after an `apps:rename`.

### Destroying, renaming and cloning an app

`dokku apps:destroy <app>` cleans up on its own: a `post-delete` hook destroys the pgbouncer app, clears the postgres service's `post-start-network`, and removes the shared network. Without it, that single-valued property would keep pointing at a network nobody uses and permanently bar the service from backing another pgbouncer. A `pre-delete` hook runs first, while the app still exists, and writes down which pgbouncer app it actually owns — otherwise destroying a *renamed* app would find nothing under `<app>-pgbouncer` and orphan the lot. That hook also warns if you destroy the pgbouncer app itself while the app it serves is still routing through it.

`dokku apps:rename` keeps the setup running. Dokku implements a rename as create-new plus destroy-old, and that destroy fires the same `post-delete` hook for the old name — so a `post-app-rename-setup` hook marks the rename in progress and the teardown is skipped. The marker expires after ten minutes: a rename destroys the old app within seconds of writing it, so an older one is the leftover of a rename that failed in between, and honouring that would silently skip the teardown for a real `apps:destroy` later on. The pgbouncer app, network and `PGBOUNCER_URL` host keep their old names, which is harmless: `connect`, `disconnect` and `info` all follow `PGBOUNCER_HOST` rather than the naming convention, so re-running `pgbouncer:connect` after a rename reuses the pooler and network the app already has instead of building a second set beside them. The plugin therefore only prints the two commands that bring the names back in line. It will not do that for you, because renaming the pgbouncer app means destroying and redeploying it, dropping every pooled connection.

`dokku apps:clone` strips the inherited `PGBOUNCER_*` variables and the source app's private network from the clone, so it starts on direct `DATABASE_URL` instead of quietly routing through another app's pooler. Run `pgbouncer:connect` on the clone to give it its own. That hook reads the config dokku has just copied onto the clone, and dokku runs plugin hooks in plugin-name order — so install the plugin as `pgbouncer` (as above) or under some other name that sorts after `config`. Install it under an earlier name and the hook runs before there is anything to strip; it warns when it notices that.

### View pgbouncer configuration

```bash
dokku pgbouncer:info myapp
```

## Configuring PgBouncer

The plugin sets these defaults on first connect, and then never touches them again — so an override survives later `pgbouncer:connect` runs:

| Variable | Default | Why |
|---|---|---|
| `POOL_MODE` | `transaction` | The mode that actually multiplexes. See below. |
| `MAX_PREPARED_STATEMENTS` | `100` | Keeps prepared statements working in transaction mode |
| `MAX_CLIENT_CONN` | `1000` | pgbouncer's own default of 100 caps the app well below what pooling is for |
| `DEFAULT_POOL_SIZE` | `20` | Server connections per user/database pair |

```bash
dokku config:set myapp-pgbouncer DEFAULT_POOL_SIZE=40
```

Any other [pgbouncer setting](https://www.pgbouncer.org/config.html) the image supports can be set the same way, as the un-prefixed upper-case name (`QUERY_TIMEOUT`, `SERVER_IDLE_TIMEOUT`, `LOG_CONNECTIONS`, …).

Do **not** override `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` or `LISTEN_PORT`: `pgbouncer:connect` owns those, rewrites them on every run, and builds `PGBOUNCER_URL` from them.

### About transaction pooling

`POOL_MODE=transaction` is the default because session pooling — pgbouncer's own default — holds one postgres backend per client connection for that connection's entire life, which multiplexes nothing and makes the whole pooler close to pointless for a typical long-lived app.

Transaction pooling gives up session-scoped state, which breaks:

- `LISTEN` / `NOTIFY`
- session-level advisory locks (transaction-level ones are fine)
- `WITH HOLD` cursors
- `SET` outside a transaction, and other session-level configuration
- plain `WITH HOLD`-style server-side cursors (Django's `QuerySet.iterator()` on psycopg2)

Prepared statements are handled — that is what `MAX_PREPARED_STATEMENTS` is for — but the rest are not. If your app needs any of them, switch back before it matters:

```bash
dokku config:set myapp-pgbouncer POOL_MODE=session
```

One more thing to know: pgbouncer rejects clients that send startup parameters it does not track, and by default it only tolerates `extra_float_digits`. If your client passes libpq's `options` (for example Django's `OPTIONS: {'options': '-c search_path=myschema'}`) the connection will fail with `unsupported startup parameter: options`. The plugin does **not** widen `IGNORE_STARTUP_PARAMETERS` for you, because ignoring that parameter would silently drop your `search_path` and point queries at the wrong schema — a failed connection is easier to diagnose than that. Opt in only if you know what your client is sending:

```bash
dokku config:set myapp-pgbouncer IGNORE_STARTUP_PARAMETERS=extra_float_digits,options
```

## Limitations

- A postgres service can only back **one** pgbouncer at a time: dokku-postgres's `post-start-network` property is single-valued, so a second app's `pgbouncer:connect` against the same service would silently break the first one on the next postgres restart. The plugin refuses to connect if the service's `post-start-network` is already set to another network, or if it cannot read the property at all — an unreadable value is not the same as an unset one, and only one of those two readings is safe to act on. `pgbouncer:disconnect` makes the opposite call for the same reason: it only clears the property if it still points at its own network, and tells you when it left something behind.
- `pgbouncer:connect` and `pgbouncer:disconnect` serialise against each other with a lock file under `/var/lib/dokku/data/pgbouncer`, because checking that a postgres service is free and claiming it are two separate steps and two runs could otherwise interleave between them. A command waits up to five minutes for another to finish, then gives up rather than racing it. If `flock` is not installed it says so and runs unserialised.
- The database user and database name must match `[A-Za-z0-9_.-]+`. The image builds its config with a shell `printf` whose format string contains these values and greps `userlist.txt` with the user as a regex, so `%`, `\` and regex metacharacters are as dangerous there as quotes. The port must be numeric for the same reason. The password is less restricted — it only has to avoid quotes, whitespace and `\`, because it is written to `userlist.txt` rather than into the config. Values generated by dokku-postgres are always safe.
- App names are limited to 53 characters, because `<app>-pgbouncer` is used as a docker network alias and DNS labels stop at 63.
- A query string on `DATABASE_URL` (e.g. `?sslmode=require`) is not carried over to the pgbouncer connection; the plugin warns when it sees one. Traffic on both legs is plaintext within the private docker network.
- The pgbouncer app is named `<app>-pgbouncer` by convention. If an app of that name already exists with something deployed to it and was not created by this plugin, `connect` refuses to overwrite it and `disconnect` refuses to destroy it.

## Security notes

- Clients must authenticate: the plugin sets `AUTH_TYPE=scram-sha-256`, and the image writes the database credentials to a `userlist.txt` rather than into `pgbouncer.ini`. Nothing on the shared network can connect to your database without the password.
- pgbouncer's admin console is closed off by pointing `ADMIN_USERS` at a user that does not exist. The image would default it to `postgres`, which is the user dokku-postgres creates — that would let anything holding the app's own credentials (including the app) run `SHUTDOWN` or `PAUSE` against the pooler.
- The database password is kept out of the generated pgbouncer config (the image writes it to `userlist.txt` instead) and out of the plugin's own output: every `dokku config:set` that carries it runs with `DOKKU_QUIET_OUTPUT=1`, because dokku otherwise echoes the values it sets, and `pgbouncer:info` redacts it. It is still visible to root via `docker inspect` and `dokku config:show`, the same as `DATABASE_URL`.
- It is **not** kept out of process arguments. `dokku config:set <app> DB_PASSWORD=…` carries it in its argv, where any local user can read it from `ps` for as long as that command runs; dokku offers no other way to set a config variable, and `dokku postgres:link` exposes `DATABASE_URL` the same way. The one place this plugin has a choice — the `psql` probe, which runs for seconds in a container — passes the password through the environment instead.
- `PGBOUNCER_URL` includes the database password, same as `DATABASE_URL`.
- The pgbouncer app's http proxy is disabled so nginx never routes outside traffic to it.

## How it works

The plugin deploys pgbouncer as a separate dokku app using a pinned `edoburu/pgbouncer` image, configured entirely through environment variables. The image is pinned rather than tracking `latest`, and is published for both amd64 and arm64.

The credentials are passed as discrete `DB_*` variables rather than as a URL: the image can parse a `DATABASE_URL` itself, but does it with `cut -d:`, which silently truncates any password containing a colon.

A dedicated docker network connects the three parties: the app and pgbouncer join it via dokku's `attach-post-create` (merged with any networks the app already uses), and the postgres container is connected directly plus via `post-start-network` so it rejoins after restarts. The app keeps its original `DATABASE_URL`; pgbouncer is offered alongside it as `PGBOUNCER_URL`, so switching is an app-level decision and disconnecting is always safe.

The plugin is seven files: `commands` (the three subcommands), `functions` (helpers shared with the hooks), and the `pre-delete`, `post-delete`, `post-app-rename-setup`, `post-app-rename` and `post-app-clone-setup` triggers.

## Upgrading from 0.1.x

0.1.x ran `pgbouncer/pgbouncer:1.15.0`, an amd64-only image last built in 2020, with no client authentication and in session-pooling mode. Re-run `pgbouncer:connect` for each app to move it across:

```bash
dokku pgbouncer:connect myapp my-database
```

That redeploys the new image, switches the app to authenticated transaction pooling, and clears the old `DATABASES_*` config — including the plaintext `DATABASES_PASSWORD` that 0.1.x left in `dokku config:show`. Read the transaction-pooling caveats above first; add `dokku config:set myapp-pgbouncer POOL_MODE=session` beforehand to keep the old behaviour. `pgbouncer:connect` also warns as it makes that switch, since what it costs only shows up later, inside your app.

## Tests

`tests/run.sh` runs the plugin against stubbed `dokku` and `docker` CLIs (in `tests/bin`), so the whole thing is exercised without a dokku host:

```bash
bash tests/run.sh
```

The `dokku` stub reproduces the real CLI's quirks where the plugin depends on them — notably that `git:from-image` *fails* when the image is unchanged, and that `ps:restart` succeeds without doing anything on an app that was never deployed.

## License

MIT
