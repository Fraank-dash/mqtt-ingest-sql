CREATE SCHEMA IF NOT EXISTS mqtt_migration;

CREATE TABLE IF NOT EXISTS mqtt_migration.import_batches (
    batch_id          BIGSERIAL PRIMARY KEY,
    dump_name         TEXT NOT NULL,
    source_timezone   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('TimeZone', TRUE), ''), 'UTC'),
    source_min_at     TIMESTAMPTZ,
    source_max_at     TIMESTAMPTZ,
    status            TEXT NOT NULL DEFAULT 'created',
    staged_row_count  BIGINT NOT NULL DEFAULT 0,
    mapped_row_count  BIGINT NOT NULL DEFAULT 0,
    skipped_row_count BIGINT NOT NULL DEFAULT 0,
    inserted_row_count BIGINT NOT NULL DEFAULT 0,
    metadata          JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT import_batches_status_check
        CHECK (status IN ('created', 'staged', 'mapped', 'loaded', 'refreshed', 'failed'))
);

CREATE TABLE IF NOT EXISTS mqtt_migration.topic_mapping (
    mapping_id     BIGSERIAL PRIMARY KEY,
    priority       INTEGER NOT NULL DEFAULT 1000,
    enabled        BOOLEAN NOT NULL DEFAULT TRUE,
    source_table   TEXT,
    rule_type      TEXT NOT NULL,
    source_pattern TEXT NOT NULL,
    target_topic   TEXT,
    target_kind    TEXT NOT NULL,
    notes          TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT topic_mapping_rule_type_check
        CHECK (rule_type IN ('exact', 'prefix', 'regex')),
    CONSTRAINT topic_mapping_target_kind_check
        CHECK (target_kind IN ('measurement', 'status', 'topic_inventory', 'skip')),
    CONSTRAINT topic_mapping_target_required_check
        CHECK (target_kind = 'skip' OR target_topic IS NOT NULL)
);

ALTER TABLE mqtt_migration.topic_mapping
    ADD COLUMN IF NOT EXISTS source_table TEXT;

CREATE INDEX IF NOT EXISTS topic_mapping_enabled_priority_idx
    ON mqtt_migration.topic_mapping (enabled, priority, mapping_id);

CREATE TABLE IF NOT EXISTS mqtt_migration.staged_messages (
    staged_message_id    BIGSERIAL PRIMARY KEY,
    batch_id             BIGINT NOT NULL REFERENCES mqtt_migration.import_batches(batch_id) ON DELETE CASCADE,
    source_table         TEXT NOT NULL,
    source_created_at    TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    source_topic         TEXT NOT NULL,
    source_unit          TEXT,
    source_payload       TEXT,
    mapping_id           BIGINT REFERENCES mqtt_migration.topic_mapping(mapping_id),
    mapped_topic         TEXT,
    mapped_kind          TEXT,
    validation_status    TEXT NOT NULL DEFAULT 'staged',
    validation_error     TEXT,
    production_received_at TIMESTAMPTZ,
    inserted             BOOLEAN NOT NULL DEFAULT FALSE,
    relay_inserted       BOOLEAN NOT NULL DEFAULT FALSE,
    metadata             JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    inserted_at          TIMESTAMPTZ,
    CONSTRAINT staged_messages_status_check
        CHECK (validation_status IN ('staged', 'mapped', 'skipped', 'unmapped', 'inserted', 'failed')),
    CONSTRAINT staged_messages_kind_check
        CHECK (mapped_kind IS NULL OR mapped_kind IN ('measurement', 'status', 'topic_inventory', 'skip'))
);

CREATE INDEX IF NOT EXISTS staged_messages_batch_status_idx
    ON mqtt_migration.staged_messages (batch_id, validation_status);

CREATE INDEX IF NOT EXISTS staged_messages_batch_inserted_idx
    ON mqtt_migration.staged_messages (batch_id, inserted);

CREATE INDEX IF NOT EXISTS staged_messages_source_topic_idx
    ON mqtt_migration.staged_messages (source_topic);

CREATE INDEX IF NOT EXISTS staged_messages_mapped_topic_idx
    ON mqtt_migration.staged_messages (mapped_topic);

CREATE TABLE IF NOT EXISTS mqtt_migration.staged_topics (
    staged_topic_id   BIGSERIAL PRIMARY KEY,
    batch_id          BIGINT NOT NULL REFERENCES mqtt_migration.import_batches(batch_id) ON DELETE CASCADE,
    source_topic      TEXT NOT NULL,
    source_payload    TEXT,
    mapping_id        BIGINT REFERENCES mqtt_migration.topic_mapping(mapping_id),
    mapped_topic      TEXT,
    mapped_kind       TEXT,
    validation_status TEXT NOT NULL DEFAULT 'staged',
    validation_error  TEXT,
    inserted          BOOLEAN NOT NULL DEFAULT FALSE,
    metadata          JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    inserted_at       TIMESTAMPTZ,
    CONSTRAINT staged_topics_status_check
        CHECK (validation_status IN ('staged', 'mapped', 'skipped', 'unmapped', 'inserted', 'failed')),
    CONSTRAINT staged_topics_kind_check
        CHECK (mapped_kind IS NULL OR mapped_kind IN ('measurement', 'status', 'topic_inventory', 'skip'))
);

CREATE INDEX IF NOT EXISTS staged_topics_batch_status_idx
    ON mqtt_migration.staged_topics (batch_id, validation_status);

CREATE INDEX IF NOT EXISTS staged_topics_source_topic_idx
    ON mqtt_migration.staged_topics (source_topic);

CREATE TABLE IF NOT EXISTS mqtt_migration.rejected_messages (
    rejected_message_id BIGSERIAL PRIMARY KEY,
    batch_id            BIGINT NOT NULL REFERENCES mqtt_migration.import_batches(batch_id) ON DELETE CASCADE,
    staged_message_id   BIGINT UNIQUE REFERENCES mqtt_migration.staged_messages(staged_message_id) ON DELETE CASCADE,
    staged_topic_id     BIGINT UNIQUE REFERENCES mqtt_migration.staged_topics(staged_topic_id) ON DELETE CASCADE,
    source_table        TEXT NOT NULL,
    source_topic        TEXT NOT NULL,
    source_payload      TEXT,
    reason              TEXT NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT rejected_messages_one_source_check
        CHECK (
            (staged_message_id IS NOT NULL AND staged_topic_id IS NULL)
            OR (staged_message_id IS NULL AND staged_topic_id IS NOT NULL)
        )
);

CREATE INDEX IF NOT EXISTS rejected_messages_batch_reason_idx
    ON mqtt_migration.rejected_messages (batch_id, reason);

COMMENT ON SCHEMA mqtt_migration IS
    'Reusable staging and audit schema for migrating historical MQTT dump tables into mqtt_ingest.';

COMMENT ON TABLE mqtt_migration.topic_mapping IS
    'Ordered topic mapping rules. source_table may qualify a rule to one legacy table. For prefix rules, target_topic is the replacement prefix. For regex rules, target_topic is the regexp_replace replacement.';
