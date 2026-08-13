# dokku-pgbouncer

A [Dokku](https://dokku.com/) plugin that runs [PgBouncer](https://www.pgbouncer.org/) between your app and its PostgreSQL database. It handles the plumbing: parsing credentials, deploying the pgbouncer container, wiring up a private docker network, and publishing a `PGBOUNCER_URL` your app can opt into.

## Requirements

- Dokku
- [dokku-postgres](https://github.com/dokku/dokku-postgres) plugin
- A postgres service already linked to your app via `dokku postgres:link`

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
3. Create a new dokku app (`myapp-pgbouncer`) running the `pgbouncer/pgbouncer` docker image, with its http proxy disabled
4. Verify the database is actually usable through pgbouncer — a real `SELECT 1` from a throwaway container — **before** touching your app
5. Set `PGBOUNCER_URL`, `PGBOUNCER_HOST`, and `PGBOUNCER_PORT` on your app and restart it

`DATABASE_URL` is left untouched — your app decides which connection to use, so make it prefer `PGBOUNCER_URL` when that variable is set. If anything fails, every change this command made is rolled back — the env vars, the network attachment, and the postgres service's `post-start-network` and network attachment — and the app keeps running on direct postgres.

A plain TCP check would not be enough here: pgbouncer accepts clients as soon as it starts listening and only dials postgres on the first query, so wrong credentials or an unreachable postgres would pass a port check and then break your app at query time.

**Note:** the connect step restarts your app so its containers join the shared network, which means a brief interruption. It is a restart from the existing image rather than a rebuild, so it cannot fail on an unrelated build problem.

Re-running `pgbouncer:connect` is safe and is the supported way to apply changed credentials (e.g. after rotating the database password): the pgbouncer app is restarted with the current values parsed from `DATABASE_URL`. Re-running it against a *different* postgres service also releases the previous one (its `post-start-network` is cleared and its container detached), so the old service is not left permanently blocked from backing another pgbouncer. That release happens only after the new service has been checked for conflicts, and it is undone if a later step fails, so a rejected or failed repoint leaves your current setup running.

The service you name must be the one `DATABASE_URL` points at. Credentials come from the URL while the postgres hostname comes from the service argument, so naming the wrong service would otherwise hand pgbouncer one service's hostname with another's credentials; the plugin refuses when the two disagree.

### Remove pgbouncer from an app

```bash
dokku pgbouncer:disconnect myapp
```

The postgres service name is remembered from `pgbouncer:connect`; you only need to pass it explicitly if the pgbouncer app was already destroyed by hand. This removes the `PGBOUNCER_*` variables and restarts your app (back on direct `DATABASE_URL`), then destroys the pgbouncer app and the shared network.

The teardown always runs to completion. If your app cannot be restarted — scaled to zero, never deployed, no longer building — the command warns and carries on rather than aborting, because the remaining steps are the only thing that releases the postgres service's `post-start-network`. It also works when the app itself is already gone, and it follows `PGBOUNCER_HOST` rather than the `<app>-pgbouncer` naming convention, so it still finds the right pgbouncer app after an `apps:rename`.

### Destroying an app

`dokku apps:destroy <app>` cleans up on its own: a `post-delete` hook destroys the pgbouncer app, clears the postgres service's `post-start-network`, and removes the shared network. Without it, that single-valued property would keep pointing at a network nobody uses and permanently bar the service from backing another pgbouncer.

`dokku apps:rename` is not handled automatically — renaming the pgbouncer app would mean destroying and redeploying it, dropping every pooled connection. The plugin warns and prints the two commands that bring the names back in line.

### View pgbouncer configuration

```bash
dokku pgbouncer:info myapp
```

## Configuring PgBouncer

You can tune pgbouncer by setting environment variables on the pgbouncer app directly:

```bash
dokku config:set myapp-pgbouncer PGBOUNCER_DEFAULT_POOL_SIZE=40
dokku config:set myapp-pgbouncer PGBOUNCER_MAX_CLIENT_CONN=200
```

See the [pgbouncer documentation](https://www.pgbouncer.org/config.html) for available settings.

## Limitations

- A postgres service can only back **one** pgbouncer at a time: dokku-postgres's `post-start-network` property is single-valued, so a second app's `pgbouncer:connect` against the same service would silently break the first one on the next postgres restart. The plugin refuses to connect if the service's `post-start-network` is already set to another network, and `pgbouncer:disconnect` only clears the property if it still points at its own network.
- The database user, name, and password may not contain quotes, whitespace, `=` or `\`, because the pgbouncer image writes all three unquoted into its generated `pgbouncer.ini`. The port must be numeric, for the same reason. Values generated by dokku-postgres are always safe.
- App names are limited to 49 characters, because `<app>-pgbouncer.web` is used as a docker network alias and DNS labels stop at 63.
- A query string on `DATABASE_URL` (e.g. `?sslmode=require`) is not carried over to the pgbouncer connection; the plugin warns when it sees one. Traffic on both legs is plaintext within the private docker network.
- The pgbouncer app is named `<app>-pgbouncer` by convention. If an app of that name already exists with something deployed to it and was not created by this plugin, `connect` refuses to overwrite it and `disconnect` refuses to destroy it.

## Security notes

- The pgbouncer image defaults to `auth_type = any`, meaning clients on the shared docker network connect without password authentication. The network only contains your app, pgbouncer, and the postgres service, but keep this in mind before attaching anything else to it.
- `PGBOUNCER_URL` includes the database password (same as `DATABASE_URL`), so it keeps working if you tighten `PGBOUNCER_AUTH_TYPE` later — though `md5`/`scram` also require mounting a `userlist.txt` into the pgbouncer container, which this plugin does not do for you.
- The pgbouncer app's http proxy is disabled so nginx never routes outside traffic to it.

## How it works

The plugin deploys pgbouncer as a separate dokku app using a pinned `pgbouncer/pgbouncer` docker image, configured entirely through `DATABASES_*` environment variables. A dedicated docker network connects the three parties: the app and pgbouncer join it via dokku's `attach-post-create` (merged with any networks the app already uses), and the postgres container is connected directly plus via `post-start-network` so it rejoins after restarts. The app keeps its original `DATABASE_URL`; pgbouncer is offered alongside it as `PGBOUNCER_URL`, so switching is an app-level decision and disconnecting is always safe.

The plugin is four files: `commands` (the three subcommands), `functions` (helpers shared with the hooks), and the `post-delete` and `post-app-rename` triggers.

## Tests

`tests/run.sh` runs the plugin against stubbed `dokku` and `docker` CLIs (in `tests/bin`), so the whole thing is exercised without a dokku host:

```bash
bash tests/run.sh
```

## License

MIT
