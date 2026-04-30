# Setup Existing TimescaleDB

This guide starts from an already-running TimescaleDB/PostgreSQL server. It does not use Docker.

## Prerequisites

You need:

- a running PostgreSQL server with TimescaleDB support
- a target database for MQTT ingest data
- `psql` installed on the machine where you run this repository
- a PostgreSQL admin connection, or another role allowed to create extensions, create roles, and manage privileges

The bootstrap expects these extensions to be available on the server:

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS timescaledb_toolkit;
```

The repository's apply script checks extension availability before applying the ordered SQL files.

## 1. Create Or Choose The Database

Create a database if you do not already have one:

```sql
CREATE DATABASE mqtt;
```

Connect to the target database as the PostgreSQL admin:

```bash
psql "postgres://postgres:change-me@127.0.0.1:5432/mqtt"
```

Confirm the TimescaleDB extensions can be created in that database:

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS timescaledb_toolkit;

SELECT extname
FROM pg_extension
WHERE extname IN ('timescaledb', 'timescaledb_toolkit')
ORDER BY extname;
```

You should see both extension names.

## 2. Apply The SQL Bootstrap

From the repository root, run the bootstrap with an admin-capable database connection:

```bash
DATABASE_URL=postgres://postgres:change-me@127.0.0.1:5432/mqtt ./scripts/apply-sql.sh
```

You can also use standard PostgreSQL environment variables instead of `DATABASE_URL`:

```bash
PGHOST=127.0.0.1 \
PGPORT=5432 \
PGDATABASE=mqtt \
PGUSER=postgres \
PGPASSWORD=change-me \
./scripts/apply-sql.sh
```

If you use a GUI client such as the VS Code PostgreSQL extension, run the same root-level
`NN_*.sql` files in lexical order instead. That is equivalent to `scripts/apply-sql.sh`
after you have confirmed these extensions are available in the target database:

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS timescaledb_toolkit;
```

The script applies all root-level `NN_*.sql` files in lexical order. These files create:

- schema `mqtt_ingest`
- raw message hypertable
- topic overview table
- aggregate and reconciliation tables
- ingest and refresh functions
- TimescaleDB background jobs
- least-privilege role `mqtt_ingest_writer`

## 3. Verify The Bootstrap

Run the env-based verifier against the same database:

```bash
DATABASE_URL=postgres://postgres:change-me@127.0.0.1:5432/mqtt ./scripts/verify-postgres.sh
```

For a GUI client, open and run `docs/sql/verify-postgres-bootstrap.sql`.
With `psql`, you can run the same file from the repository root with:

```sql
\i docs/sql/verify-postgres-bootstrap.sql
```

The verifier checks the core objects, the `mqtt_ingest_writer` role, function grants, lack of direct table privileges for that role, and `SECURITY DEFINER` on the ingest entry points. The SQL file returns failed check names, or an empty result set when verification passes.

## 4. Create MQTT Subscriber Login Users

The bootstrap creates `mqtt_ingest_writer` as a shared `NOLOGIN` group role. Create one
login role per subscriber process and grant only this group role. Subscriber roles should
not receive direct table privileges.

For password-based logins, create login roles with passwords:

```sql
CREATE ROLE mqtt_ingest_user1 LOGIN INHERIT PASSWORD 'change-me';
GRANT mqtt_ingest_writer TO mqtt_ingest_user1;

CREATE ROLE mqtt_ingest_user2 LOGIN INHERIT PASSWORD 'change-me';
GRANT mqtt_ingest_writer TO mqtt_ingest_user2;
```

For certificate-based logins, create login roles without passwords:

```sql
CREATE ROLE mqtt_ingest_user1 LOGIN INHERIT;
GRANT mqtt_ingest_writer TO mqtt_ingest_user1;

CREATE ROLE mqtt_ingest_user2 LOGIN INHERIT;
GRANT mqtt_ingest_writer TO mqtt_ingest_user2;
```

Use one authentication mode for a deployment, not both. For certificate auth, SQL only
creates PostgreSQL roles and grants `mqtt_ingest_writer`; certificate enforcement and
certificate-to-role mapping still happen in PostgreSQL server config such as
`pg_hba.conf` and optionally `pg_ident.conf`.

The examples create `mqtt_ingest_user1` and `mqtt_ingest_user2`. These users inherit
`mqtt_ingest_writer` and write through the public ingest functions only.

## 5. Test Subscriber Access

Connect as a subscriber user:

```bash
psql "postgres://mqtt_ingest_user1:change-me@127.0.0.1:5432/mqtt"
```

This call should succeed:

```sql
SELECT mqtt_ingest.ingest_message(
    'sensors/demo/temperature',
    '{"value":"21.5","event_id":"manual-test-1"}',
    now(),
    '{"source":"manual"}'::jsonb
);
```

This direct table write should fail:

```sql
INSERT INTO mqtt_ingest.messages (received_at, topic, payload)
VALUES (now(), 'sensors/demo/temperature', '21.5');
```

That failure is expected. Subscriber users are intended to call only:

- `mqtt_ingest.ingest_message(text,text,timestamp with time zone,jsonb)`
- `mqtt_ingest.ingest_topics(text,text,timestamp with time zone,jsonb)`

## 6. Operational Checks

As an admin, inspect recent data:

```sql
SELECT received_at, topic, payload
FROM mqtt_ingest.messages
ORDER BY received_at DESC
LIMIT 20;
```

Check TimescaleDB jobs:

```sql
SELECT job_id, proc_schema, proc_name, schedule_interval
FROM timescaledb_information.jobs
WHERE proc_schema = 'mqtt_ingest'
ORDER BY proc_name;
```

Check subscriber privileges:

```sql
SELECT
    has_schema_privilege('mqtt_ingest_writer', 'mqtt_ingest', 'USAGE') AS schema_usage,
    has_function_privilege(
        'mqtt_ingest_writer',
        'mqtt_ingest.ingest_message(text,text,timestamp with time zone,jsonb)',
        'EXECUTE'
    ) AS can_ingest_messages,
    has_function_privilege(
        'mqtt_ingest_writer',
        'mqtt_ingest.ingest_topics(text,text,timestamp with time zone,jsonb)',
        'EXECUTE'
    ) AS can_ingest_topics;
```

## 7. Reapplying Changes

After pulling SQL changes, rerun:

```bash
DATABASE_URL=postgres://postgres:change-me@127.0.0.1:5432/mqtt ./scripts/apply-sql.sh
DATABASE_URL=postgres://postgres:change-me@127.0.0.1:5432/mqtt ./scripts/verify-postgres.sh
```

The bootstrap is written to be reapplied for normal object updates. Use the admin connection because the security bootstrap manages roles and grants.
