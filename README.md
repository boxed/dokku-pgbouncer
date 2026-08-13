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
| `pgbouncer:info <app>` | Show pgbouncer config for an app |

## Usage

### Add pgbouncer to an app

```bash
dokku pgbouncer:connect myapp my-database
```

This will:

1. Parse `DATABASE_URL` on your app to extract connection credentials
2. Create a private docker network (`pgbouncer-myapp`) shared by your app, pgbouncer, and the postgres service
3. Create a new dokku app (`myapp-pgbouncer`) running the `pgbouncer/pgbouncer` docker image, with its http proxy disabled
4. Verify pgbouncer is reachable on the network **before** touching your app
5. Set `PGBOUNCER_URL`, `PGBOUNCER_HOST`, and `PGBOUNCER_PORT` on your app and rebuild it

`DATABASE_URL` is left untouched — your app decides which connection to use, so make it prefer `PGBOUNCER_URL` when that variable is set. If verification fails at any point, the env vars are rolled back and the app keeps running on direct postgres.

**Note:** the connect step rebuilds your app (to join the shared network), which may cause a brief redeploy.

### Remove pgbouncer from an app

```bash
dokku pgbouncer:disconnect myapp
```

The postgres service name is remembered from `pgbouncer:connect`; you only need to pass it explicitly if the pgbouncer app was already destroyed by hand. This removes the `PGBOUNCER_*` variables and rebuilds your app (back on direct `DATABASE_URL`), then destroys the pgbouncer app and the shared network.

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

## Security notes

- The pgbouncer image defaults to `auth_type = any`, meaning clients on the shared docker network connect without password authentication. The network only contains your app, pgbouncer, and the postgres service, but keep this in mind before attaching anything else to it.
- `PGBOUNCER_URL` includes the database password (same as `DATABASE_URL`), so it keeps working if you tighten `PGBOUNCER_AUTH_TYPE` later — though `md5`/`scram` also require mounting a `userlist.txt` into the pgbouncer container, which this plugin does not do for you.
- The pgbouncer app's http proxy is disabled so nginx never routes outside traffic to it.

## How it works

The plugin deploys pgbouncer as a separate dokku app using a pinned `pgbouncer/pgbouncer` docker image, configured entirely through `DATABASES_*` environment variables. A dedicated docker network connects the three parties: the app and pgbouncer join it via dokku's `attach-post-create` (merged with any networks the app already uses), and the postgres container is connected directly plus via `post-start-network` so it rejoins after restarts. The app keeps its original `DATABASE_URL`; pgbouncer is offered alongside it as `PGBOUNCER_URL`, so switching is an app-level decision and disconnecting is always safe.

## License

MIT
