"""Personal analytics: baselines, trends, responses to meals / interventions / contexts, quality and insights.

Pure functions over the caller's own rows (scans, comparisons, interventions, meals): nothing here touches
storage, so the same code is unit-tested on synthetic histories and run by the API.

Statistical stance (stated to the user in every response):
  * A "personal baseline" is the mean of the user's good-quality Baseline scans. Its spread (SD) is the
    user's normal day-to-day variation. With fewer than 3 baselines the range is not estimated.
  * A change is called "clear" when it exceeds 2 x the baseline SD, "possible" above 1 x SD, otherwise
    "within normal variation". Without an SD the PRD thresholds are used (b/a +-10 %, RMSSD ratio 0.7 / 1.2)
    and the result is marked lower-confidence.
  * Confidence of a grouped finding comes from the number of scans behind it (1 low, 2-3 medium, >=4 high).
None of these numbers are clinically validated; they describe the user's own measurements.
"""
from __future__ import annotations

import math
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from statistics import mean, median, stdev
from typing import Any, Iterable, Optional

from biofeedback import HRV_CALMER_RATIO, HRV_INCOMPATIBLE_RATIO, TONE_SOFTER_PCT, TONE_STIFFER_PCT

METRICS = ("ba_ratio", "rmssd", "avg_bpm")
METRIC_INFO = {
    "ba_ratio": {"label": "b/a ratio", "unit": "", "better": "lower",
                 "explain": "Shape of the pulse wave's second derivative. More negative usually means more "
                            "elastic (compliant) arteries; moving toward zero suggests higher vascular tone."},
    "rmssd": {"label": "HRV (RMSSD)", "unit": "ms", "better": "higher",
              "explain": "Beat-to-beat variation of the heart rhythm. Higher values usually mean a calmer, "
                         "more recovered nervous system; drops follow stress, caffeine, heavy meals or poor sleep."},
    "avg_bpm": {"label": "Heart rate", "unit": "bpm", "better": "context",
                "explain": "Average pulse during the scan. Rises after meals, exercise, caffeine and stress."},
}
INTERVENTION_TAGS = {"Post-Vajrasana": "Vajrasana"}
PAIR_WINDOW_MIN = 120          # a pre-intervention scan must be at most this long before the post scan
MEAL_WINDOW_MIN = 240          # a post-meal scan is linked to the meal if within 4 h

PRAKRITI_GUIDANCE = {
    "Vata": {"focus": "steadiness and warmth",
             "meals": "Warm, cooked, moist meals at regular times; limit raw, cold and dry foods.",
             "routine": "Keep a regular sleep and meal schedule; calm breathing before scans.",
             "watch": "HRV dips after irregular meals, travel or poor sleep."},
    "Pitta": {"focus": "cooling and moderation",
              "meals": "Cooling, less spicy, less oily food; avoid skipping meals.",
              "routine": "Sitali (cooling) breath after intense work; avoid scanning when overheated.",
              "watch": "Heart-rate and HRV response to spicy, fried or very sour meals."},
    "Kapha": {"focus": "lightness and activity",
              "meals": "Light, warm, less sweet and less heavy meals; avoid large late dinners.",
              "routine": "A short walk after meals; morning activity.",
              "watch": "Vascular-tone response to heavy, sweet or dairy-rich meals."},
}


# ----------------------------------------------------------------------------- helpers
def _ts(s: str) -> datetime:
    d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def _r(v: Optional[float], n: int = 3) -> Optional[float]:
    return None if v is None or (isinstance(v, float) and not math.isfinite(v)) else round(float(v), n)


def _ok(s: dict) -> bool:
    return bool(s.get("sqi_passed")) and all(s.get(m) is not None for m in METRICS)


def _confidence(n: int) -> str:
    return "high" if n >= 4 else "medium" if n >= 2 else "low"


def _sd(xs: list[float]) -> Optional[float]:
    return stdev(xs) if len(xs) >= 2 else None


def tone_pct(test_ba: float, base_ba: float) -> Optional[float]:
    """+ = b/a moved toward zero (stiffer); same convention as dsp_engine.percent_change_vascular_tone."""
    return None if not base_ba else (test_ba - base_ba) / abs(base_ba) * 100.0


def sd_floor(metric: str, base_mean: float) -> float:
    """Smallest spread treated as real variation (measurement noise of a 35 s smartphone scan), so a few very
    similar baselines cannot make every small difference look 'clear'. ASSUMPTION, tune on real data."""
    return {"ba_ratio": 0.03 * abs(base_mean), "rmssd": 0.10 * abs(base_mean), "avg_bpm": 3.0}.get(metric, 0.0)


def significance(metric: str, value: float, base_mean: float, base_sd: Optional[float]) -> dict:
    """Classify a single reading against the personal baseline."""
    diff = value - base_mean
    if base_sd and base_sd > 0:
        z = diff / max(base_sd, sd_floor(metric, base_mean))
        level = "clear" if abs(z) >= 2 else "possible" if abs(z) >= 1 else "normal"
        return {"z": _r(z, 2), "level": level, "method": "personal_sd"}
    # fallback: PRD thresholds
    if metric == "ba_ratio":
        t = tone_pct(value, base_mean) or 0.0
        level = "clear" if (t > TONE_STIFFER_PCT or t < TONE_SOFTER_PCT) else "normal"
    elif metric == "rmssd":
        ratio = value / base_mean if base_mean else 1.0
        level = "clear" if (ratio < HRV_INCOMPATIBLE_RATIO or ratio > HRV_CALMER_RATIO) else "normal"
    else:
        level = "clear" if abs(diff) >= 10 else "possible" if abs(diff) >= 5 else "normal"
    return {"z": None, "level": level, "method": "fixed_threshold"}


def _direction(metric: str, diff: float) -> str:
    """'better' / 'worse' / 'neutral' from the user's point of view."""
    if abs(diff) < 1e-9:
        return "neutral"
    if metric == "ba_ratio":
        return "better" if diff < 0 else "worse"
    if metric == "rmssd":
        return "better" if diff > 0 else "worse"
    return "neutral"


def _linreg(xs: list[float], ys: list[float]) -> tuple[float, float]:
    mx, my = mean(xs), mean(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return 0.0, my
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    return b, my - b * mx


def _part_of_day(dt_local: datetime) -> str:
    h = dt_local.hour
    return "morning" if 5 <= h < 12 else "afternoon" if 12 <= h < 17 else "evening" if 17 <= h < 22 else "night"


# ----------------------------------------------------------------------------- building blocks
def baseline_stats(scans: list[dict]) -> dict:
    """Personal baseline from good-quality Baseline scans (all given scans are assumed to be the user's)."""
    base = [s for s in scans if s["tag_event"] == "Baseline" and _ok(s)]
    n = len(base)
    out: dict[str, Any] = {"n": n, "reliability": ("none" if n == 0 else "preliminary" if n < 3 else
                                                   "established" if n < 7 else "strong"),
                           "first_at": base[0]["timestamp"] if base else None,
                           "last_at": base[-1]["timestamp"] if base else None, "metrics": {}}
    for m in METRICS:
        xs = [float(s[m]) for s in base]
        if not xs:
            out["metrics"][m] = None
            continue
        sd = _sd(xs)
        out["metrics"][m] = {
            "mean": _r(mean(xs)), "sd": _r(sd), "median": _r(median(xs)), "min": _r(min(xs)), "max": _r(max(xs)),
            "latest": _r(xs[-1]), "cv_pct": _r(sd / abs(mean(xs)) * 100, 1) if sd and mean(xs) else None,
            "normal_range": [_r(mean(xs) - sd), _r(mean(xs) + sd)] if (sd is not None and n >= 3) else None}
    return out


def trend(scans: list[dict], metric: str, base: dict) -> Optional[dict]:
    """Linear trend of the metric over BASELINE scans (same conditions -> comparable over time)."""
    pts = [(_ts(s["timestamp"]), float(s[metric])) for s in scans if s["tag_event"] == "Baseline" and _ok(s)]
    if len(pts) < 4:
        return {"n": len(pts), "status": "insufficient", "per_week": None, "total_change": None, "meaningful": False}
    t0 = pts[0][0]
    days = [(t - t0).total_seconds() / 86400 for t, _ in pts]
    span = days[-1] - days[0]
    if span < 5:
        return {"n": len(pts), "status": "insufficient", "per_week": None, "total_change": None,
                "meaningful": False, "span_days": _r(span, 1)}
    slope, _ = _linreg(days, [v for _, v in pts])
    total = slope * span
    bm = (base.get("metrics") or {}).get(metric) or {}
    sd = bm.get("sd")
    meaningful = bool(sd) and abs(total) > max(sd, sd_floor(metric, bm.get("mean") or 0.0))
    direction = _direction(metric, total) if meaningful else "stable"
    return {"n": len(pts), "status": "ok", "per_week": _r(slope * 7), "total_change": _r(total),
            "span_days": _r(span, 1), "meaningful": meaningful, "direction": direction}


def _rolling(points: list[tuple[datetime, float]], days: int = 7) -> list[Optional[float]]:
    out = []
    for i, (t, _) in enumerate(points):
        win = [v for (u, v) in points[: i + 1] if (t - u) <= timedelta(days=days)]
        out.append(_r(mean(win)) if win else None)
    return out


def scan_response(s: dict, base: dict) -> Optional[dict]:
    """How one good scan differs from the personal baseline."""
    if not _ok(s) or base["n"] == 0:
        return None
    bm = base["metrics"]
    out: dict[str, Any] = {}
    for m in METRICS:
        b = bm[m]
        v = float(s[m])
        out[m] = {"value": _r(v), "baseline": b["mean"], "diff": _r(v - b["mean"]),
                  "direction": _direction(m, v - b["mean"]), **significance(m, v, b["mean"], b["sd"])}
    out["tone_pct"] = _r(tone_pct(float(s["ba_ratio"]), bm["ba_ratio"]["mean"]), 1)
    out["hrv_ratio"] = _r(float(s["rmssd"]) / bm["rmssd"]["mean"], 3) if bm["rmssd"]["mean"] else None
    out["compatibility_pct"] = _r(max(0.0, min(100.0, (out["hrv_ratio"] or 0) * 100)), 1)
    return out


def _agg(rows: list[dict]) -> dict:
    """Aggregate a list of scan_response dicts."""
    tones = [r["tone_pct"] for r in rows if r.get("tone_pct") is not None]
    ratios = [r["hrv_ratio"] for r in rows if r.get("hrv_ratio") is not None]
    bpm = [r["avg_bpm"]["diff"] for r in rows if r.get("avg_bpm")]
    n = len(rows)
    return {"n": n, "confidence": _confidence(n),
            "tone_pct_mean": _r(mean(tones), 1) if tones else None,
            "hrv_ratio_mean": _r(mean(ratios), 3) if ratios else None,
            "bpm_diff_mean": _r(mean(bpm), 1) if bpm else None,
            "compatibility_pct": _r(max(0.0, min(100.0, mean(ratios) * 100)), 1) if ratios else None}


def _label_effect(a: dict) -> str:
    """Plain-language label for an aggregated response."""
    if not a.get("n"):
        return "no data"
    r, t = a.get("hrv_ratio_mean"), a.get("tone_pct_mean")
    stress = r is not None and r < HRV_INCOMPATIBLE_RATIO
    calmer = r is not None and r > HRV_CALMER_RATIO
    stiffer = t is not None and t > TONE_STIFFER_PCT
    softer = t is not None and t < TONE_SOFTER_PCT
    if stress and stiffer:
        return "strong stress response"
    if stress:
        return "lower HRV (stress response)"
    if stiffer:
        return "higher vascular tone"
    if calmer or softer:
        return "favourable response"
    return "close to your baseline"


# ----------------------------------------------------------------------------- main entry point
def build(user: dict, scans: list[dict], meals: list[dict], interventions: list[dict],
          days: int = 90, tz_offset_min: int = 0, now: Optional[datetime] = None) -> dict:
    now = now or datetime.now(timezone.utc)
    tz = timezone(timedelta(minutes=tz_offset_min))
    since = now - timedelta(days=days)
    scans = sorted(scans, key=lambda s: s["timestamp"])
    win = [s for s in scans if _ts(s["timestamp"]) >= since]
    good = [s for s in win if _ok(s)]
    meal_by_id = {m["meal_id"]: m for m in meals}

    # baseline: window first, all-time fallback so a short window still has a reference
    base = baseline_stats(win)
    base_scope = f"last {days} days"
    if base["n"] == 0:
        base = baseline_stats(scans)
        base_scope = "all time"
    base["scope"] = base_scope

    # ---- overview
    local_days = sorted({_ts(s["timestamp"]).astimezone(tz).date() for s in good})
    streak = 0
    if local_days:
        today = now.astimezone(tz).date()
        d = today if today in local_days else today - timedelta(days=1)
        ds = set(local_days)
        while d in ds:
            streak += 1
            d -= timedelta(days=1)
    overview = {
        "total_scans": len(win), "good_scans": len(good),
        "quality_rate": _r(len(good) / len(win), 3) if win else None,
        "first_scan_at": scans[0]["timestamp"] if scans else None,
        "last_scan_at": scans[-1]["timestamp"] if scans else None,
        "days_active": len(local_days), "streak_days": streak,
        "scans_last_7d": sum(1 for s in scans if _ts(s["timestamp"]) >= now - timedelta(days=7)),
        "all_time_scans": len(scans)}

    # ---- trend series (all good scans) + baseline rolling mean
    series = {}
    for m in METRICS:
        pts = [{"t": s["timestamp"], "v": _r(float(s[m])), "tag": s["tag_event"], "scan_id": s["scan_id"]}
               for s in good]
        bpts = [(_ts(s["timestamp"]), float(s[m])) for s in good if s["tag_event"] == "Baseline"]
        roll = _rolling(bpts)
        series[m] = {"points": pts,
                     "baseline_rolling": [{"t": t.isoformat(), "v": v} for (t, _), v in zip(bpts, roll)],
                     "trend": trend(win, m, base), "info": METRIC_INFO[m]}

    # ---- responses to every non-baseline good scan
    responses = []
    for s in good:
        if s["tag_event"] == "Baseline":
            continue
        r = scan_response(s, base)
        if r is None:
            continue
        meal = meal_by_id.get(s.get("meal_id")) if s.get("meal_id") else None
        mins = None
        if meal:
            mins = _r((_ts(s["timestamp"]) - _ts(meal["eaten_at"])).total_seconds() / 60, 0)
        responses.append({"scan_id": s["scan_id"], "t": s["timestamp"], "tag": s["tag_event"],
                          "context": list(s.get("context_tags") or []),
                          "intervention": s.get("intervention") or INTERVENTION_TAGS.get(s["tag_event"]),
                          "meal": meal["name"] if meal else None, "minutes_after_meal": mins, **r})
    resp_by_scan = {r["scan_id"]: r for r in responses}

    # ---- by scan type and by context tag
    by_tag: dict[str, list] = defaultdict(list)
    for r in responses:
        by_tag[r["tag"]].append(r)
    by_tag_out = [{"tag": k, **_agg(v), "effect": _label_effect(_agg(v))} for k, v in sorted(by_tag.items())]

    ctx_out = []
    for c in sorted({c for r in responses for c in r["context"]}):
        with_c = [r for r in responses if c in r["context"]]
        without = [r for r in responses if c not in r["context"]]
        a, b = _agg(with_c), _agg(without)
        ctx_out.append({"context": c, "with": a, "without": b, "effect": _label_effect(a)})

    # ---- meals
    meal_groups: dict[str, list] = defaultdict(list)
    meal_names: dict[str, str] = {}
    for r in responses:
        if r["meal"]:
            key = r["meal"].strip().lower()
            meal_groups[key].append(r)
            meal_names.setdefault(key, r["meal"].strip())
    meals_out = []
    for key, rows in meal_groups.items():
        a = _agg(rows)
        mins = [r["minutes_after_meal"] for r in rows if r["minutes_after_meal"] is not None]
        meals_out.append({"name": meal_names[key], **a, "effect": _label_effect(a),
                          "minutes_after_meal_median": _r(median(mins), 0) if mins else None,
                          "scan_ids": [r["scan_id"] for r in rows]})
    meals_out.sort(key=lambda x: (-(x["compatibility_pct"] or 0), x["name"]))
    by_desc: dict[str, list] = defaultdict(list)
    by_type: dict[str, list] = defaultdict(list)
    for s in good:
        meal = meal_by_id.get(s.get("meal_id")) if s.get("meal_id") else None
        r = resp_by_scan.get(s["scan_id"])
        if not meal or not r:
            continue
        for d in meal.get("descriptors") or []:
            by_desc[d].append(r)
        if meal.get("meal_type"):
            by_type[meal["meal_type"]].append(r)
    meal_desc_out = [{"descriptor": k, **_agg(v), "effect": _label_effect(_agg(v))} for k, v in sorted(by_desc.items())]
    meal_type_out = [{"meal_type": k, **_agg(v), "effect": _label_effect(_agg(v))} for k, v in sorted(by_type.items())]
    unscanned = [m["name"] for m in meals if _ts(m["eaten_at"]) >= since and not any(
        s.get("meal_id") == m["meal_id"] and _ok(s) for s in scans)]

    # ---- interventions: paired with the closest good scan within PAIR_WINDOW_MIN before it
    iv_groups: dict[str, list] = defaultdict(list)
    for s in good:
        itype = s.get("intervention") or INTERVENTION_TAGS.get(s["tag_event"])
        if not itype:
            continue
        t = _ts(s["timestamp"])
        pre = [p for p in good if p["scan_id"] != s["scan_id"] and timedelta(0) < t - _ts(p["timestamp"])
               <= timedelta(minutes=PAIR_WINDOW_MIN) and not (p.get("intervention") or
                                                             INTERVENTION_TAGS.get(p["tag_event"]))]
        row = {"post_scan_id": s["scan_id"], "t": s["timestamp"]}
        if pre:
            p = pre[-1]
            row.update(pre_scan_id=p["scan_id"], paired=True,
                       tone_pct=_r(tone_pct(float(s["ba_ratio"]), float(p["ba_ratio"])), 1),
                       hrv_ratio=_r(float(s["rmssd"]) / float(p["rmssd"]), 3) if p["rmssd"] else None,
                       bpm_diff=_r(float(s["avg_bpm"]) - float(p["avg_bpm"]), 1))
        elif s["scan_id"] in resp_by_scan:
            r = resp_by_scan[s["scan_id"]]
            row.update(pre_scan_id=None, paired=False, tone_pct=r["tone_pct"], hrv_ratio=r["hrv_ratio"],
                       bpm_diff=r["avg_bpm"]["diff"])
        else:
            continue
        iv_groups[itype].append(row)
    iv_out = []
    for k, rows in sorted(iv_groups.items()):
        tones = [x["tone_pct"] for x in rows if x["tone_pct"] is not None]
        ratios = [x["hrv_ratio"] for x in rows if x["hrv_ratio"] is not None]
        improved = sum(1 for x in rows if (x["tone_pct"] or 0) < 0)
        n = len(rows)
        a = {"n": n, "tone_pct_mean": _r(mean(tones), 1) if tones else None,
             "hrv_ratio_mean": _r(mean(ratios), 3) if ratios else None}
        iv_out.append({"type": k, **a, "confidence": _confidence(n), "paired": sum(1 for x in rows if x["paired"]),
                       "improved_count": improved, "improvement_pct_mean": _r(-mean(tones), 1) if tones else None,
                       "effect": _label_effect(a), "sessions": rows[-10:]})

    # ---- time of day (all good scans, local time)
    tod: dict[str, list] = defaultdict(list)
    for s in good:
        tod[_part_of_day(_ts(s["timestamp"]).astimezone(tz))].append(s)
    tod_out = [{"part": k, "n": len(v), **{m: _r(mean(float(x[m]) for x in v)) for m in METRICS}}
               for k, v in tod.items()]
    order = ["morning", "afternoon", "evening", "night"]
    tod_out.sort(key=lambda x: order.index(x["part"]))

    # ---- signal / capture quality
    reasons: dict[str, int] = defaultdict(int)
    fps, statuses = [], defaultdict(int)
    for s in win:
        for rr in ((s.get("sqi_report") or {}).get("reasons") or []):
            reasons[str(rr).split(":")[0][:80]] += 1
        acq = (s.get("features") or {}).get("acquisition") or {}
        if acq.get("fs_mean"):
            fps.append(float(acq["fs_mean"]))
        if acq.get("status"):
            statuses[acq["status"]] += 1
    quality = {"pass_rate": overview["quality_rate"], "failed": len(win) - len(good),
               "top_reasons": sorted(({"reason": k, "count": v} for k, v in reasons.items()),
                                     key=lambda x: -x["count"])[:5],
               "mean_fps": _r(mean(fps), 1) if fps else None, "capture_status": dict(statuses)}

    analytics = {
        "generated_at": now.isoformat(), "window_days": days, "tz_offset_min": tz_offset_min,
        "overview": overview, "baseline": base, "series": series, "responses": responses[-60:],
        "by_tag": by_tag_out, "contexts": ctx_out, "meals": meals_out, "meal_descriptors": meal_desc_out,
        "meal_types": meal_type_out, "meals_without_scan": unscanned[-10:], "interventions": iv_out,
        "time_of_day": tod_out, "quality": quality, "metric_info": METRIC_INFO,
        "method": {"baseline": "mean of good-quality Baseline scans",
                   "significance": "clear >= 2 SD, possible >= 1 SD of your baseline (SD at least 3 % of b/a, "
                                   "10 % of RMSSD, 3 bpm); PRD thresholds when SD unknown",
                   "confidence": "low = 1 scan, medium = 2-3, high = 4+",
                   "limits": "Smartphone PPG is a wellness measurement, not a diagnosis. Single scans vary; "
                             "look for patterns repeated over several days."},
    }
    analytics["prakriti"] = _prakriti_block(user)
    analytics["insights"] = insights(analytics, user)
    return analytics


def _prakriti_block(user: dict) -> Optional[dict]:
    p = user.get("prakriti_type")
    if not p:
        return None
    parts = [x for x in p.split("-") if x in PRAKRITI_GUIDANCE]
    if p == "Tridosha":
        parts = list(PRAKRITI_GUIDANCE)
    return {"type": p, "scores": user.get("prakriti_scores"),
            "guidance": {k: PRAKRITI_GUIDANCE[k] for k in parts},
            "note": "Traditional Ayurvedic lifestyle guidance for context; not medical advice."}


# ----------------------------------------------------------------------------- insights
def _ins(kind: str, title: str, body: str, confidence: str, n: int, tone: str = "info", **extra) -> dict:
    return {"kind": kind, "title": title, "body": body, "confidence": confidence, "evidence_n": n,
            "tone": tone, **extra}


def insights(a: dict, user: dict) -> list[dict]:
    out: list[dict] = []
    base, ov = a["baseline"], a["overview"]

    # 1. getting started / baseline reliability
    if ov["all_time_scans"] == 0:
        out.append(_ins("action", "Record your first baseline",
                        "Sit quietly for 2 minutes, then scan with the 'Baseline' type. Mornings before food "
                        "and coffee give the most comparable readings.", "high", 0, "action"))
        return out
    if base["n"] == 0:
        out.append(_ins("action", "No good baseline yet",
                        "Comparisons need at least one good-quality Baseline scan. Rest, then scan with the "
                        "'Baseline' type.", "high", 0, "action"))
    elif base["n"] < 3:
        out.append(_ins("action", "Add more baseline scans",
                        f"You have {base['n']} baseline scan(s). Three or more on different days let the app "
                        "learn your normal range, so real changes can be told apart from day-to-day noise.",
                        "high", base["n"], "action"))
    else:
        b = base["metrics"]
        out.append(_ins("baseline", "Your normal range",
                        f"From {base['n']} baselines: HRV {b['rmssd']['mean']:.0f} ms (±{b['rmssd']['sd']:.0f}), "
                        f"heart rate {b['avg_bpm']['mean']:.0f} bpm, b/a {b['ba_ratio']['mean']:.2f}. "
                        "Changes larger than this spread are flagged as real changes.",
                        _confidence(base["n"]), base["n"]))

    # 2. trends
    for m in ("rmssd", "ba_ratio"):
        t = a["series"][m]["trend"]
        if t and t.get("status") == "ok" and t.get("meaningful"):
            good = t["direction"] == "better"
            label = METRIC_INFO[m]["label"]
            out.append(_ins("trend", f"{label} is {'improving' if good else 'worsening'}",
                            f"Across {t['n']} baselines over {t['span_days']:.0f} days your {label} changed by "
                            f"{t['total_change']:+.2f}{' ' + METRIC_INFO[m]['unit'] if METRIC_INFO[m]['unit'] else ''}"
                            ", more than your usual day-to-day variation.",
                            _confidence(t["n"]), t["n"], "good" if good else "warn", metric=m))

    # 3. meals
    meals = [m for m in a["meals"] if m["compatibility_pct"] is not None]
    if meals:
        best, worst = meals[0], meals[-1]
        if len(meals) >= 2 and best["compatibility_pct"] - worst["compatibility_pct"] >= 15:
            out.append(_ins("meal", f"'{best['name']}' suits you better than '{worst['name']}'",
                            f"After '{best['name']}' your HRV stayed at {best['compatibility_pct']:.0f}% of baseline "
                            f"(n={best['n']}); after '{worst['name']}' it fell to {worst['compatibility_pct']:.0f}% "
                            f"(n={worst['n']}). Repeat each meal a few times to confirm.",
                            _confidence(min(best["n"], worst["n"])), best["n"] + worst["n"], "info"))
        for m in meals:
            if m["hrv_ratio_mean"] is not None and m["hrv_ratio_mean"] < HRV_INCOMPATIBLE_RATIO:
                out.append(_ins("meal", f"Stress response after '{m['name']}'",
                                f"HRV averaged {m['hrv_ratio_mean'] * 100:.0f}% of your baseline after this meal "
                                f"(below the 70% threshold){'' if m['n'] > 1 else ' in a single scan'}.",
                                m["confidence"], m["n"], "warn"))
                break
    for d in a["meal_descriptors"]:
        if d["n"] >= 2 and d["hrv_ratio_mean"] is not None and d["hrv_ratio_mean"] < 0.85:
            out.append(_ins("meal", f"{d['descriptor'].capitalize()} meals lower your HRV",
                            f"Across {d['n']} scans after {d['descriptor']} meals HRV averaged "
                            f"{d['hrv_ratio_mean'] * 100:.0f}% of baseline.", d["confidence"], d["n"], "warn"))

    # 4. interventions
    for iv in a["interventions"]:
        if iv["improvement_pct_mean"] is None:
            continue
        helped = iv["improvement_pct_mean"] > 0
        hrv_txt = "" if iv["hrv_ratio_mean"] is None else ", HRV x%.2f" % iv["hrv_ratio_mean"]
        out.append(_ins("intervention", f"{iv['type']}: {'helps' if helped else 'no clear benefit yet'}",
                        f"{iv['improved_count']} of {iv['n']} sessions moved b/a in the improving direction "
                        f"(average {iv['improvement_pct_mean']:+.1f}%{hrv_txt}). "
                        f"{iv['paired']} compared with a scan taken just before.",
                        iv["confidence"], iv["n"], "good" if helped else "info"))

    # 5. contexts
    for c in a["contexts"]:
        w, wo = c["with"], c["without"]
        if w["hrv_ratio_mean"] is not None and wo["hrv_ratio_mean"] is not None and \
                wo["hrv_ratio_mean"] - w["hrv_ratio_mean"] >= 0.15:
            out.append(_ins("context", f"{c['context']} lowers your HRV",
                            f"Scans tagged {c['context']} averaged {w['hrv_ratio_mean'] * 100:.0f}% of baseline HRV "
                            f"versus {wo['hrv_ratio_mean'] * 100:.0f}% without it.", w["confidence"], w["n"], "warn"))

    # 6. time of day
    tod = [x for x in a["time_of_day"] if x["n"] >= 2]
    if len(tod) >= 2 and base["n"] >= 3 and base["metrics"]["rmssd"]["sd"]:
        hi, lo = max(tod, key=lambda x: x["rmssd"]), min(tod, key=lambda x: x["rmssd"])
        if hi["rmssd"] - lo["rmssd"] > base["metrics"]["rmssd"]["sd"]:
            out.append(_ins("pattern", f"HRV is highest in the {hi['part']}",
                            f"{hi['part'].capitalize()} scans average {hi['rmssd']:.0f} ms vs {lo['rmssd']:.0f} ms "
                            f"in the {lo['part']}. Scan at a consistent time for fair comparisons.",
                            _confidence(min(hi["n"], lo["n"])), hi["n"] + lo["n"]))

    # 7. quality
    q = a["quality"]
    if q["pass_rate"] is not None and ov["total_scans"] >= 3 and q["pass_rate"] < 0.7:
        reason = q["top_reasons"][0]["reason"] if q["top_reasons"] else "signal quality"
        out.append(_ins("quality", "Many scans fail the quality check",
                        f"Only {q['pass_rate'] * 100:.0f}% of recent scans passed (most common issue: {reason}). "
                        "Rest your hand on a table, cover lens and flash fully with light pressure, keep still.",
                        "high", ov["total_scans"], "warn"))

    # 8. personalisation
    p = a.get("prakriti")
    if p and p["guidance"]:
        k, g = next(iter(p["guidance"].items()))
        out.append(_ins("prakriti", f"For your {p['type']} constitution",
                        f"Focus on {g['focus']}. {g['meals']} Watch: {g['watch']}", "medium", 0, "info",
                        note=p["note"]))

    if ov["streak_days"] >= 3:
        out.append(_ins("habit", f"{ov['streak_days']}-day scanning streak",
                        "Regular scans make your baseline and trends more reliable.", "high", ov["streak_days"],
                        "good"))
    return out


def export_rows(rows: Iterable[dict]) -> list[dict]:
    return [dict(r) for r in rows]
