-- Every write takes the next value. Because pushes are serialized with an
-- advisory lock, values commit in increasing order and a pull cursor never skips rows.
CREATE SEQUENCE change_seq;

CREATE TABLE records (
    id             uuid        PRIMARY KEY,           -- generated on the device, so records can be created offline
    type           text        NOT NULL,
    fields         jsonb       NOT NULL DEFAULT '{}',
    field_versions jsonb       NOT NULL DEFAULT '{}', -- field name -> change_seq value of its last write
    version        bigint      NOT NULL,              -- change_seq value of the last write to any field
    deleted        boolean     NOT NULL DEFAULT false, -- tombstone, so other devices learn about deletes
    updated_by     text        NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX records_version_idx ON records (version);

-- Makes push idempotent: a retried mutation returns its original result.
CREATE TABLE applied_mutations (
    mutation_id uuid        PRIMARY KEY,
    device_id   text        NOT NULL,
    record_id   uuid        NOT NULL,
    result      jsonb       NOT NULL,
    applied_at  timestamptz NOT NULL DEFAULT now()
);

-- Audit trail of field-level conflicts, resolved in favour of the server value.
CREATE TABLE sync_conflicts (
    id           bigserial   PRIMARY KEY,
    mutation_id  uuid        NOT NULL,
    record_id    uuid        NOT NULL,
    device_id    text        NOT NULL,
    field        text,
    client_value jsonb,
    server_value jsonb,
    reason       text        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX sync_conflicts_record_idx ON sync_conflicts (record_id);
