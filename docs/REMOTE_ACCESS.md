# Using Agni-Pulse from anywhere (no USB, no shared Wi-Fi)

The phone only needs an **https address** for the API. Pick one:

| Option | Always on? | Cost | Setup time | Use it for |
|---|---|---|---|---|
| **A. Cloud: Render + Supabase** (recommended) | yes (sleeps when idle, wakes in ~30-60 s) | free tiers | ~20 min, once | daily use, the faculty demo |
| B. Cloudflare quick tunnel from your laptop | only while the laptop runs it | free | 2 min | a quick test from mobile data |
| C. Same Wi-Fi (LAN IP) | while the laptop runs | free | 5 min | development only (plain http) |

Your database is the same in all three if you point `DATABASE_URL` at Supabase, so accounts and history do not
depend on which option the phone used.

---

## A. Cloud deployment (Render web service + Supabase Postgres)

### 1. Database (Supabase)
1. supabase.com → your project (or *New project*, region **Mumbai / ap-south-1**).
2. **Connect** → *Connection string* → **Session pooler** (port **5432**, IPv4-compatible). It looks like
   `postgresql://postgres.<ref>:<PASSWORD>@aws-0-ap-south-1.pooler.supabase.com:5432/postgres`
3. Append `?sslmode=require`. Keep this string secret (never commit it, never put it in the app).
4. Migrations run automatically when the API starts (`migrate.py`). Running them by hand is also fine:
   `cd backend && DATABASE_URL="..." python migrate.py` → `applied 003_accounts_analytics.sql`.

> Free Supabase projects **pause after 7 days without activity**. Open the dashboard and press *Restore* if
> `/ready` reports "database unreachable".

### 2. Put the code on GitHub
Render deploys from a Git repository. Create a **private** repository and push this folder:
```bash
cd agni-pulse
git init && git add . && git commit -m "Agni-Pulse 1.0"
git branch -M main
git remote add origin https://github.com/<you>/agni-pulse.git
git push -u origin main
```
`.gitignore` already excludes `.env`, virtualenvs and build output. Check `git status` shows no `.env` file.

### 3. API (Render)
1. render.com → **New → Blueprint** → choose the repository. Render reads `render.yaml`
   (Docker web service `agni-pulse-api`, free plan, Singapore region, health check `/health`).
2. It asks for the secret values:
   * `DATABASE_URL` = the Supabase string from step 1.
   * `AGNI_REGISTRATION_KEY` = any long random text. **Recommended**: a public URL lets anyone create an
     account otherwise. Give the key only to people who should sign up (faculty, testers). Leave empty to
     allow open sign-up.
   * `AGNI_SMTP_*`: leave empty unless you want e-mailed reset codes (see below). Recovery codes work without.
3. **Apply**. The first build takes ~5 min. Then open `https://agni-pulse-api.onrender.com/ready`
   (your exact name is on the Render dashboard). Expect `{"ok":true,"database":true,...}`.

> Free Render services **sleep after ~15 min idle**; the next request takes 30-60 s while it wakes. The app shows
> "Waking up the server…" and waits up to 90 s. Before a demo, open the app (or `/health` in a browser) a
> minute early. Optional: a free uptime monitor (e.g. UptimeRobot) pinging `/health` every 10 minutes keeps
> it awake; one free service fits Render's monthly free hours.

### 4. Verify the whole system from your laptop
```bash
cd agni-pulse
python -m pip install -r backend/requirements-dev.txt
python scripts/smoke_remote.py https://agni-pulse-api.onrender.com  <registration-key-if-set>
```
It signs up a throw-away account, uploads synthetic scans, checks history, analytics, second-device login,
logout, recovery and isolation, then deletes the account. Expect `20/20 checks passed`.

### 5. Build the app with the server built in and install it without a cable
```bash
cd app
flutter build apk --release --dart-define=API_BASE_URL=https://agni-pulse-api.onrender.com
```
The APK is `app/build/app/outputs/flutter-apk/app-release.apk`. Copy it to the phone any way you like
(Google Drive, e-mail, Telegram/WhatsApp "document", Nearby Share) and open it; allow "install unknown apps"
for that app when Android asks. Or install once over USB with `flutter install --release`; after that no cable is
needed.

Any build can also be pointed at a server at run time: **Welcome screen → Server** (before sign-in) or
**Profile → Server & camera**. If the server needs an invitation key, enter it there or on the sign-up form.

### Optional: e-mailed password-reset codes
Set on Render: `AGNI_SMTP_HOST` (e.g. `smtp.gmail.com`), `AGNI_SMTP_PORT=587`, `AGNI_SMTP_USER`,
`AGNI_SMTP_PASSWORD` (for Gmail: an *App password*, needs 2-step verification), `AGNI_SMTP_FROM`.
The app then offers "E-mail code" next to "Recovery code" on the reset screen.

---

## B. Quick tunnel from your laptop (no account, URL changes each time)
```powershell
.\scripts\run_dev.ps1 -DatabaseUrl "postgresql://...supabase...:5432/postgres?sslmode=require"   # terminal 1
.\scripts\tunnel.ps1                                                                              # terminal 2
```
`tunnel.ps1` installs `cloudflared` with winget if needed and prints `https://<random>.trycloudflare.com`.
Enter that in the app (Server settings). The laptop must stay on and connected; the address changes every run.
macOS/Linux: `./scripts/tunnel.sh`.

## C. Same Wi-Fi (development)
`.\scripts\run_dev.ps1 -DatabaseUrl "..." -Lan`, allow port 8000 with `.\scripts\windows_firewall.ps1`, and
enter `http://<laptop-IP>:8000` in the app. Plain http: do not use this on public networks.

---

## Troubleshooting
| Symptom in the app | Check |
|---|---|
| "Waking up the server…" then a timeout | Render dashboard → Logs. A failed deploy or a paused Supabase project. |
| Server reachable, *Database* fails | `/ready` in a browser. Supabase paused, wrong password, or the *transaction* pooler (6543) instead of the *session* pooler (5432). |
| "registration key required" | The server has `AGNI_REGISTRATION_KEY`; enter it on the sign-up form. |
| Release APK cannot connect at all | Rebuild after `flutter pub get`: the plugin adds the INTERNET permission that Flutter only gives debug builds. |
