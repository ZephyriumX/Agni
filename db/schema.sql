-- Agni-Pulse Supabase (PostgreSQL) schema
-- gen_random_uuid() is built in on PG13+ (Supabase default).

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
    tag_event     VARCHAR(50), -- 'Baseline', 'Post-Meal', 'Post-Vajrasana', 'Caffeine'
    raw_signal    JSONB,       -- Array of intensity values
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
    type                   VARCHAR(50), -- 'Vajrasana', 'Sitali Pranayama'
    improvement_percentage FLOAT
);

-- Additions beyond the PRD (safe, non-breaking):
CREATE INDEX IF NOT EXISTS idx_scans_user_time ON scans (user_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_interventions_pre  ON interventions (pre_scan_id);
CREATE INDEX IF NOT EXISTS idx_interventions_post ON interventions (post_scan_id);

-- Health data: lock tables down. The backend uses the service-role key (bypasses RLS);
-- the mobile app must never talk to these tables directly with the anon key.
ALTER TABLE users         ENABLE ROW LEVEL SECURITY;
ALTER TABLE scans         ENABLE ROW LEVEL SECURITY;
ALTER TABLE interventions ENABLE ROW LEVEL SECURITY;
