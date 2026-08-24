-- ============================================================
-- 010_import_staging.sql
-- Import batches, raw rows and review queue for controlled loads.
-- ============================================================

CREATE TABLE import_batch (
    id_import_batch        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    source_name            TEXT        NOT NULL,
    source_path            TEXT        NOT NULL,
    source_sha256          TEXT        NOT NULL,
    source_row_count       INTEGER,
    import_status          TEXT        NOT NULL DEFAULT 'CREATED'
                           CHECK (import_status IN (
                               'CREATED','RUNNING','COMPLETED','FAILED','ROLLED_BACK'
                           )),
    started_at             TIMESTAMPTZ,
    finished_at            TIMESTAMPTZ,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE import_batch ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON import_batch
    AS RESTRICTIVE FOR ALL USING (false);

CREATE UNIQUE INDEX uq_import_batch_sha256 ON import_batch (source_name, source_sha256);
CREATE INDEX idx_import_batch_status ON import_batch (import_status);
CREATE INDEX idx_import_batch_source ON import_batch (source_name);

CREATE TABLE import_raw_row (
    id_import_raw_row      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_import_batch        UUID        NOT NULL REFERENCES import_batch(id_import_batch),
    row_number             INTEGER     NOT NULL,
    raw_payload            JSONB       NOT NULL,
    normalized_payload     JSONB       NOT NULL DEFAULT '{}',
    entity_kind            TEXT        NOT NULL DEFAULT 'ORGANIZATION'
                           CHECK (entity_kind IN ('ORGANIZATION','PERSON','SUPPLIER_PRODUCT','OTHER')),
    match_status           TEXT        NOT NULL DEFAULT 'PENDING'
                           CHECK (match_status IN (
                               'PENDING','MATCH_CONFIRMED','POSSIBLE_MATCH',
                               'POSSIBLE_DUPLICATE','NEW_RECORD','REJECTED','IMPORTED'
                           )),
    target_table           TEXT,
    target_id              UUID,
    error_message          TEXT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_import_raw_row UNIQUE (id_import_batch, row_number)
);

ALTER TABLE import_raw_row ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON import_raw_row
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_import_raw_batch  ON import_raw_row (id_import_batch);
CREATE INDEX idx_import_raw_status ON import_raw_row (match_status);
CREATE INDEX idx_import_raw_target ON import_raw_row (target_table, target_id);

CREATE TABLE import_review_item (
    id_import_review_item  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_import_raw_row      UUID        NOT NULL REFERENCES import_raw_row(id_import_raw_row),
    review_reason          TEXT        NOT NULL,
    severity               TEXT        NOT NULL DEFAULT 'MEDIUM'
                           CHECK (severity IN ('LOW','MEDIUM','HIGH')),
    resolution_status      TEXT        NOT NULL DEFAULT 'OPEN'
                           CHECK (resolution_status IN ('OPEN','APPROVED','REJECTED','MERGED','IGNORED')),
    resolution_notes       TEXT,
    resolved_at            TIMESTAMPTZ,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE import_review_item ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON import_review_item
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_import_review_raw    ON import_review_item (id_import_raw_row);
CREATE INDEX idx_import_review_status ON import_review_item (resolution_status);
