# dokku-pgbouncer

A [Dokku](https://dokku.com/) plugin that inserts [PgBouncer](https://www.pgbouncer.org/) between your app and its PostgreSQL database. It handles all the plumbing: parsing credentials, deploying the pgbouncer container, and rewriting environment variables so your app connects through the connection pooler transparently.

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
| `pgbouncer:intercept-db <app> <service>` | Intercept an app's db connection through pgbouncer |
| `pgbouncer:remove-intercept-db <app>` | Remove pgbouncer and restore direct db connection |
| `pgbouncer:info <app>` | Show pgbouncer config for an app |

## Usage

### Add pgbouncer to an app

```bash
dokku pgbouncer:intercept-db myapp my-database
```

This will:

1. Parse `DATABASE_URL` from your app to extract connection credentials
2. Create a new dokku app (`myapp-pgbouncer`) running the pgbouncer docker image
3. Unlink the postgres service from your app
4. Set `DATABASE_URL` and all `DOKKU_POSTGRES_*` environment variables on your app to route through pgbouncer

Your app will be redeployed automatically with the new configuration.

**Note:** This operation unlinks postgres and rewrites your app's database environment variables. This will cause a redeploy and may cause brief downtime.

### Remove pgbouncer from an app

```bash
dokku pgbouncer:remove-intercept-db myapp
```

This destroys the pgbouncer app and re-links the postgres service directly, restoring all environment variables to their original values.

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

## How it works

The plugin deploys pgbouncer as a separate dokku app using the official `pgbouncer/pgbouncer` docker image. It takes over ownership of the database environment variables from the dokku-postgres plugin (by unlinking the postgres service) so there's no conflict over who controls `DATABASE_URL` and the `DOKKU_POSTGRES_*` vars. The connectivity variables are rewritten to point at the pgbouncer container, while metadata variables (PG_VERSION, LANG, etc.) are preserved as-is.

## License

MIT
