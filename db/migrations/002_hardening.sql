-- 002: per-user auth, richer scan record, comparisons, meals, constraints, RLS.
ALTER TABLE users ADD COLUMN IF NOT EXISTS token_hash TEXT UNIQUE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();

-- meals (PRD F8 Food Compatibility Diary)
CREATE TABLE IF NOT EXISTS meals (
    meal_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id   UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    name      VARCHAR(120) NOT NULL,
    perceived_load SMALLINT CHECK (perceived_load BETWEEN 1 AND 5),
    eaten_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- scans: provenance + quality + idempotency
ALTER TABLE scans ADD COLUMN IF NOT EXISTS client_scan_id UUID;
ALTER TABLE scans ADD COLUMN IF NOT EXISTS context_tags   JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE scans ADD COLUMN IF NOT EXISTS meal_id        UUID REFERENCES meals(meal_id) ON DELETE SET NULL;
ALTER TABLE scans ADD COLUMN IF NOT EXISTS raw_timestamps JSONB;
ALTER TABLE scans ADD COLUMN IF NOT EXISTS effective_fs   FLOAT;
ALTER TABLE scans ADD COLUMN IF NOT EXISTS duration_s     FLOAT;
ALTER TABLE scans ADD COLUMN IF NOT EXISTS channel        VARCHAR(8);
ALTER TABLE scans ADD COLUMN IF NOT EXISTS features       JSONB;
ALTER TABLE scans ADD COLUMN IF NOT EXISTS sqi_report     JSONB;
ALTER TABLE scans ADD COLUMN IF NOT EXISTS processing_ms  FLOAT;
ALTER TABLE scans ADD COLUMN IF NOT EXISTS algo_version   VARCHAR(16);
ALTER TABLE scans ADD COLUMN IF NOT EXISTS template       JSONB;
CREATE UNIQUE INDEX IF NOT EXISTS uq_scans_user_client ON scans (user_id, client_scan_id) WHERE client_scan_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_scans_user_time ON scans (user_id, timestamp DESC);

-- interventions: ownership + audit
ALTER TABLE interventions ADD COLUMN IF NOT EXISTS user_id    UUID REFERENCES users(user_id) ON DELETE CASCADE;
ALTER TABLE interventions ADD COLUMN IF NOT EXISTS created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();
CREATE UNIQUE INDEX IF NOT EXISTS uq_interventions_pair ON interventions (pre_scan_id, post_scan_id, type);

-- comparisons (persisted PRD formulas)
CREATE TABLE IF NOT EXISTS comparisons (
    comparison_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                 UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    baseline_scan_id        UUID NOT NULL REFERENCES scans(scan_id) ON DELETE CASCADE,
    test_scan_id            UUID NOT NULL REFERENCES scans(scan_id) ON DELETE CASCADE,
    delta_vascular_tone_pct FLOAT NOT NULL,
    hrv_ratio               FLOAT NOT NULL,
    compatibility_pct       FLOAT,
    verdict                 VARCHAR(32),
    interpretation          JSONB,
    created_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE (baseline_scan_id, test_scan_id)
);
CREATE INDEX IF NOT EXISTS idx_comparisons_user ON comparisons (user_id, created_at DESC);

DO $$ BEGIN
  ALTER TABLE scans ADD CONSTRAINT chk_scans_fs CHECK (sampling_rate > 0) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE scans ADD CONSTRAINT chk_scans_tag CHECK (tag_event IN
   ('Baseline','Post-Meal','Post-Vajrasana','Caffeine','Stress','Poor-Sleep','Pre-Yoga')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Row-level security: the app must never read these tables with the anon key.
-- The API connects with a server-side role (DATABASE_URL).
ALTER TABLE users         ENABLE ROW LEVEL SECURITY;
ALTER TABLE scans         ENABLE ROW LEVEL SECURITY;
ALTER TABLE interventions ENABLE ROW LEVEL SECURITY;
ALTER TABLE comparisons   ENABLE ROW LEVEL SECURITY;
ALTER TABLE meals         ENABLE ROW LEVEL SECURITY;
