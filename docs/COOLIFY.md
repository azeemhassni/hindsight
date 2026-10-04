# Coolify, as it actually is

Everything here was read off a running Coolify **v4.3.23** in a local OrbStack
VM on 2026-10-04, not from documentation or memory. Where it contradicts
`ARCHITECTURE.md` §13 or the original brief, this document wins and those have
been corrected.

How it was produced: `orbctl create ubuntu coolify`, then Coolify's own
`install.sh`, then a project, environment and Postgres resource created through
the API, then `docker inspect`, `psql` against `coolify-db`, and the filesystem.

---

## 1. What the install puts on disk

```
/data/coolify
├── applications/          one directory per application, named by resource uuid
├── backups/               Coolify's own scheduled database backups
├── databases/<uuid>/      docker-compose.yml, README.md, docker-entrypoint-initdb.d/
├── images/                avatars/, project-icons/   (uploaded assets)
├── proxy/
│   ├── acme.json          Let's Encrypt account key and issued certificates
│   ├── backups/
│   ├── docker-compose.yml the proxy's own compose file
│   └── dynamic/           Traefik dynamic configuration
├── sentinel/              metrics.sqlite (+ -wal, -shm)
├── services/              one directory per service, named by resource uuid
├── source/
│   ├── .env               APP_KEY lives here. Root-owned, mode 644.
│   ├── .env.production
│   ├── docker-compose.yml, docker-compose.prod.yml
│   ├── upgrade.sh, upgrade-postgres.sh
│   └── installation-*.log, upgrade-*.log
├── ssh/
│   ├── keys/              private keys Coolify uses to reach its servers
│   └── mux/               ssh multiplexing sockets
└── ssl/
    └── coolify-ca.crt
```

### Corrections to the brief

| Claim | Reality |
|---|---|
| Coolify's Postgres data lives under `/data/coolify/database` | **No such directory.** `coolify-db` stores `PGDATA=/var/lib/postgresql/data` in a Docker **named volume** called `coolify-db`, so the bytes are under `/var/lib/docker/volumes/coolify-db/_data`. A filesystem backup that covers `/var/lib/docker/volumes` picks it up, but only crash-consistently — the `pg_dump` is the real backup. |
| not mentioned | `/data/coolify/proxy/acme.json` holds the Let's Encrypt **account key and certificates**. Losing it means re-issuing every certificate, with rate limits waiting. It is now treated as critical, alongside `APP_KEY`. |
| not mentioned | `/data/coolify/ssl/coolify-ca.crt` exists and is captured. |
| not mentioned | `/data/coolify/sentinel/metrics.sqlite` is monitoring data, regenerable, and excluded by default — it is also written constantly, so including it would add churn to every backup for no benefit. |

---

## 2. Containers

A default install runs six:

| Container | Image |
|---|---|
| `coolify` | `coollabsio/coolify:4.3.23` |
| `coolify-db` | `postgres:15-alpine` |
| `coolify-redis` | `redis:7-alpine` |
| `coolify-realtime` | `coollabsio/coolify-realtime:1.0.19` |
| `coolify-proxy` | **`traefik:v3.6`** |
| `coolify-sentinel` | `coollabsio/sentinel:1.0.1` |

`coolify-proxy` is Traefik, not Caddy, on a default install. Caddy is
selectable per server in Coolify, so the proxy flavour must be detected rather
than assumed — the image name of `coolify-proxy` is the reliable signal.

`coolify-db` credentials come from the container's own environment:
`POSTGRES_USER=coolify`, `POSTGRES_DB=coolify`, and a generated
`POSTGRES_PASSWORD`. So the instance dump is:

```
docker exec coolify-db pg_dump --format=custom --no-owner --no-privileges \
  --username=coolify --dbname=coolify
```

running as the container's own user, with no password needed from outside
because `PGUSER` is set inside.

---

## 3. Resource labels — the brief and the source were both wrong

Coolify's source contains the string `coolify.databaseUuid`, which is what made
the brief's label list plausible. A deployed Postgres resource actually carries:

```
coolify.managed=true
coolify.type=database
coolify.databaseId=1                          ← numeric id, not a uuid
coolify.database.subType=standalone-postgresql
coolify.resourceName=acme-db
coolify.serviceName=acme-db
coolify.projectName=acme
coolify.environmentName=production
```

**There is no `coolify.resourceUUID` label, and no uuid in the labels at all.**

The resource uuid is recoverable three ways, all present on the container:

1. the container **name** is the uuid (`q78pdwdw3qpsm2zdmyqfu6wf`);
2. `com.docker.compose.project` is the uuid;
3. `com.docker.compose.project.working_dir` is
   `/data/coolify/databases/<uuid>`, which also tells you the resource kind.

Hindsight uses the compose project label, falling back to the container name,
because Coolify deploys every resource through Docker Compose with the project
set to the resource uuid. The `coolify.*` labels are used for the human-readable
project, environment and resource names, and for the resource kind — not for
identity.

`coolify.databaseId` and `coolify.applicationId` are primary keys in Coolify's
own database. They are useful only for joining against that database, and they
are not stable across a Coolify restore into a fresh instance, so they are not
used as identity either.

---

## 4. Volumes and generated files

For the Postgres resource above:

- Volume: `postgres-data-q78pdwdw3qpsm2zdmyqfu6wf`, a Docker **named** volume
  mounted at `/var/lib/postgresql/data`. Named volumes, not host binds, are the
  default — which is what makes blue/green restore into a new volume possible.
- `/data/coolify/databases/<uuid>/docker-compose.yml` is generated by Coolify
  and contains the database **password in plain text**. It is both sensitive and
  exactly what a restore needs, so it is captured and the UI says so.
- `/data/coolify/databases/<uuid>/docker-entrypoint-initdb.d/` holds any
  initialisation scripts.

---

## 5. The API

- Base path `/api/v1`, bearer token, Sanctum abilities `read` and `write`.
  Hindsight asks for **read** only.
- **The API is disabled by default.** A fresh install answers every endpoint
  with `{"success":true,"message":"API is disabled."}` and HTTP 200 — note the
  `success: true`, which makes a careless client think it worked. It is enabled
  per instance in settings (`is_api_enabled`). Discovery therefore cannot treat
  a token as sufficient: the label path is the common case, not the fallback.
- A token belongs to a **team**, and only sees that team's servers. The
  `localhost` server created by the installer belongs to team 0 ("Root Team"),
  and a token minted for team 0 is rejected as invalid. A token for a normal
  team sees nothing until a server is assigned to it. So an empty `/servers`
  does not mean "no servers" — it means "none for this token's team", and the
  UI must say that rather than reporting an empty instance.
- `GET /version` returns a **bare string** (`4.3.23`), not a JSON object.
- `GET /databases` omits passwords. Creation responses include an
  `internal_db_url` with credentials, but a read-only client never sees it, so
  per-resource database credentials come from the container's environment or
  the generated compose file — not from the API.
- `GET /{type}/{uuid}/storages` is authoritative for volumes:

  ```json
  { "persistent_storages": [ {
      "name": "postgres-data-q78pdwdw3qpsm2zdmyqfu6wf",
      "mount_path": "/var/lib/postgresql/data",
      "host_path": null,
      "resource_type": "App\\Models\\StandalonePostgresql",
      "uuid": "sqfw9f5nkrxbjoxqymris9tp"
  } ], "file_storages": [] }
  ```

  `host_path` is null for a named volume and set for a bind mount, which is the
  signal the restore planner needs to decide whether an atomic swap is possible.
- Resources reference their environment by numeric `environment_id`, and
  projects expose their environments with uuids, so the tree is assembled from
  `/projects` plus `/projects/{uuid}`.

---

## 6. Coolify's own database

`coolify-db` is `postgres:15-alpine`, database `coolify`, user `coolify`.
Tables used for read-only discovery when there is no API token:

- `teams(id, name)`
- `servers(id, uuid, name, team_id)` — the installer's own server has `id = 0`
- `projects(id, uuid, name, team_id)`
- `environments(id, uuid, name, project_id)`
- `applications`, `standalone_postgresqls`, `standalone_mysqls`,
  `standalone_mariadbs`, `standalone_mongodbs`, `standalone_redis`, `services`
- `local_persistent_volumes` — volumes per resource
- `personal_access_tokens(..., team_id, abilities)` — tokens are team-scoped

This is a private interface. Hindsight reads it only as a last resort, never
writes it, and treats a schema change as "fall back to labels" rather than an
error.

---

## 7. What this means for Hindsight

1. Identity comes from the compose project label or the container name, never
   from a `coolify.*` uuid label, because there isn't one.
2. Discovery must work with no API token at all, and must say which source
   produced the tree.
3. An empty API result is reported as "nothing visible to this token", not as
   an empty instance.
4. The Coolify instance backup covers: the environment file under
   `/data/coolify/source/` (`APP_KEY`), a `pg_dump` of `coolify-db`,
   `/data/coolify/ssh`, `/data/coolify/proxy` including `acme.json`,
   `/data/coolify/ssl`, and the per-resource directories under
   `applications/`, `databases/` and `services/`. It excludes
   `sentinel/metrics.sqlite*` and the installation logs.
5. The proxy is Traefik here, so blue/green routing work starts from Traefik's
   dynamic configuration in `/data/coolify/proxy/dynamic` — but the flavour is
   detected per server, not assumed.

## 8. Coolify's own containers carry the managed label

`coolify-proxy`, `coolify-sentinel` and `coolify-realtime` all have
`coolify.managed=true`, so filtering on that label alone finds Coolify's own
infrastructure alongside real resources. They have **no `coolify.type`**, which
is what distinguishes them, and Hindsight requires a recognised `coolify.type`
before treating a container as a backup target. There is a test for exactly
this, because backing up the proxy as if it were someone's application would be
both wrong and confusing.

## 9. Coolify's rolling update, and why zero-downtime data restore is not offered

The brief asked for this to be researched and reported before any blue/green
code was written. Read from `app/Jobs/ApplicationDeploymentJob.php` on `main`.

**What Coolify does natively.** `rolling_update()` is real blue/green, for
**applications only** — databases and services do not go through the
deployment job at all:

- On Docker Swarm: `docker stack deploy`, and Swarm handles the rollover.
- Otherwise: `start_by_compose_file()` → `health_check()` →
  `stop_running_container()`. The new container is started, waited on until
  healthy, and only then is the old one gracefully shut down.

**When Coolify refuses to roll.** It force-stops first, accepting downtime, if
any of these hold: the application maps ports to the host; the "consistent
container name" setting is on; a custom internal name is set; it is a pull
request deployment; or custom docker run options set `--ip`/`--ip6`.

**Why that does not give a zero-downtime data restore.** The new container is
built from the same compose file, and `generate_local_persistent_volumes()`
reads the volume list out of Coolify's own database. Both the old and the new
container therefore mount **the same named volume**. Coolify's rolling update
replaces the container and the image; it never replaces the data underneath.

So restoring a resource's data without interruption would mean restoring into a
*new* volume and then pointing the resource at it — and the volume list lives
in Coolify's `local_persistent_volumes` table. Doing that means writing to
Coolify's private database, which Hindsight will not do: it is a private
interface, it would fight Coolify's own state, and getting it wrong would break
a resource in a way the person did not ask for.

**The conclusion, and what Hindsight does instead.**

1. Zero downtime is **not offered** for restoring data, and the UI says why in
   those terms. Claiming it while a shared volume is being overwritten
   underneath a running container would be the dishonest kind of
   zero-downtime — no interruption to requests, while the application reads
   data changing beneath it.
2. **Minimal downtime** is offered and real: stage the restore beside the live
   data, then stop, swap with renames, start. The transfer happens while the
   resource is up; the outage is the stop and start.
3. **Clone** is offered and genuinely has no impact: restore into a new volume
   under a new name, for inspection or for recovering a few files, without
   touching the live resource at all.

If Coolify later exposes volume rewiring through its API, zero-downtime data
restore becomes possible without touching its database, and this decision
should be revisited.

## 10. Still unverified

Honest gaps, to be closed before the features that depend on them:

- **Application and service resources.** Only a database resource was
  deployed, so application labels are inferred from the database case plus
  Coolify's source — `coolify.type=application`,
  `coolify.applicationId=<numeric>`, identity via the compose project — and not
  observed.

  An attempt to close this failed for a reason worth recording: deploying an
  application needs the `localhost` server to have a private key, and this
  install has none, because the first user was created through `artisan`
  instead of Coolify's web onboarding, which is what generates it. The
  deployment fails inside Coolify with
  `Call to a member function storeInFileSystem() on null`.

  To finish this verification, complete Coolify's web onboarding in the VM
  first (`http://<vm>:8000`), then deploy a Docker-image application through
  the API — `POST /applications/dockerimage` works and needs no git build.
  Creating the key row directly in Coolify's database was deliberately not
  done: its `private_key` column is encrypted with `APP_KEY`, and writing
  Coolify's private schema is exactly what Hindsight refuses to do elsewhere.
- **Restoring a Coolify instance** end to end into a fresh VM.
- Whether `coolify-proxy` is absent until a resource needs it: it was running
  here after the first deploy, but a brand-new install may not have it.
