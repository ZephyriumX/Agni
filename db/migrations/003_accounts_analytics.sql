-- 003: user accounts (email + password), sessions, account recovery, personalisation profile,
--      richer scan / meal context for analytics. Additive and idempotent; existing rows keep working.

-- ---------------------------------------------------------------- accounts
ALTER TABLE users ADD COLUMN IF NOT EXISTS email                   TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash           TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS recovery_hash           TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS display_name            VARCHAR(80);
ALTER TABLE users ADD COLUMN IF NOT EXISTS profile                 JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE users ADD COLUMN IF NOT EXISTS prakriti_scores         JSONB;
ALTER TABLE users ADD COLUMN IF NOT EXISTS onboarding_completed_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS failed_logins           INT NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS locked_until            TIMESTAMP WITH TIME ZONE;
-- one account per e-mail address, case-insensitive
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_email ON users (lower(email)) WHERE email IS NOT NULL;

-- Login sessions: one row per signed-in device. Only the SHA-256 of the bearer token is stored.
CREATE TABLE IF NOT EXISTS sessions (
    session_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    token_hash   TEXT NOT NULL UNIQUE,
    device_name  VARCHAR(80),
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    expires_at   TIMESTAMP WITH TIME ZONE NOT NULL,
    revoked_at   TIMESTAMP WITH TIME ZONE
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions (user_id);

-- E-mailed one-time reset codes (only used when SMTP is configured). Code stored hashed.
CREATE TABLE IF NOT EXISTS password_resets (
    reset_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    code_hash  TEXT NOT NULL,
    attempts   INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    used_at    TIMESTAMP WITH TIME ZONE
);
CREATE INDEX IF NOT EXISTS idx_password_resets_user ON password_resets (user_id, created_at DESC);

-- ---------------------------------------------------------------- scan / meal context
ALTER TABLE scans ADD COLUMN IF NOT EXISTS intervention VARCHAR(50);
ALTER TABLE scans ADD COLUMN IF NOT EXISTS notes        VARCHAR(500);
ALTER TABLE scans DROP CONSTRAINT IF EXISTS chk_scans_tag;
ALTER TABLE scans ADD CONSTRAINT chk_scans_tag CHECK (tag_event IN
   ('Baseline','Post-Meal','Post-Vajrasana','Post-Intervention','Post-Exercise',
    'Caffeine','Stress','Poor-Sleep','Pre-Yoga')) NOT VALID;

ALTER TABLE meals ADD COLUMN IF NOT EXISTS meal_type   VARCHAR(16);
ALTER TABLE meals ADD COLUMN IF NOT EXISTS notes       VARCHAR(500);
ALTER TABLE meals ADD COLUMN IF NOT EXISTS descriptors JSONB NOT NULL DEFAULT '[]'::jsonb;
CREATE INDEX IF NOT EXISTS idx_meals_user_time ON meals (user_id, eaten_at DESC);

-- Deleting a scan or an account must remove what depends on it (001 created these without CASCADE).
ALTER TABLE scans DROP CONSTRAINT IF EXISTS scans_user_id_fkey;
ALTER TABLE scans ADD CONSTRAINT scans_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE;
ALTER TABLE interventions DROP CONSTRAINT IF EXISTS interventions_pre_scan_id_fkey;
ALTER TABLE interventions ADD CONSTRAINT interventions_pre_scan_id_fkey
    FOREIGN KEY (pre_scan_id) REFERENCES scans(scan_id) ON DELETE CASCADE;
ALTER TABLE interventions DROP CONSTRAINT IF EXISTS interventions_post_scan_id_fkey;
ALTER TABLE interventions ADD CONSTRAINT interventions_post_scan_id_fkey
    FOREIGN KEY (post_scan_id) REFERENCES scans(scan_id) ON DELETE CASCADE;

-- The API connects with a server-side role; anon/public clients never read these tables.
ALTER TABLE sessions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE password_resets ENABLE ROW LEVEL SECURITY;
