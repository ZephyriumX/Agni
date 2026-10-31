-- 001: PRD base schema (Supabase / PostgreSQL 13+). Idempotent.
CREATE TABLE IF NOT EXISTS users (
    user_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at        TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    prakriti_type     VARCHAR(20),
    baseline_rmssd    FLOAT,
    baseline_ba_ratio FLOAT
);

CREATE TABLE IF NOT EXISTS scans (
    scan_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID REFERENCES users(user_id),
    timestamp     TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    tag_event     VARCHAR(50),
    raw_signal    JSONB,
    sampling_rate INT DEFAULT 60,
    avg_bpm       FLOAT,
    rmssd         FLOAT,
    ba_ratio      FLOAT,
    sqi_passed    BOOLEAN
);

CREATE TABLE IF NOT EXISTS interventions (
    intervention_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pre_scan_id            UUID REFERENCES scans(scan_id),
    post_scan_id           UUID REFERENCES scans(scan_id),
    type                   VARCHAR(50),
    improvement_percentage FLOAT
);
