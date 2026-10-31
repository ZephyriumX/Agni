"""Comparison interpretation: Metabolic Mirror, Context Gate, Reaction Report, Digital Cure.

Every threshold below is traceable to the PRD or flagged as an ASSUMPTION. None of this is validated
clinical logic; "Metabolic Overload" is an experimental heuristic, not a glucose measurement.
"""
from __future__ import annotations

DISCLAIMER = ("Agni-Pulse is a wellness tool, not a medical device. Smartphone PPG measures pulse-wave "
              "changes, not blood glucose, and nothing here is a diagnosis. Consult a clinician for health "
              "concerns.")

HRV_INCOMPATIBLE_RATIO = 0.7   # PRD Pillar I: RMSSD_post < 0.7 x RMSSD_pre => "Incompatible"
TONE_STIFFER_PCT = 10.0        # ASSUMPTION: PRD says b/a "increases significantly"; 10% chosen, tune on data
TONE_SOFTER_PCT = -10.0        # ASSUMPTION (mirror of the above)
HRV_CALMER_RATIO = 1.2         # ASSUMPTION
YOGA_TAGS = {"Post-Vajrasana"}


def compatibility(hrv_ratio: float) -> tuple[float, str]:
    """Compatibility % = clamp(100 x RMSSD ratio, 0, 100)  [ASSUMPTION: PRD gives only the 0.7 cut-off]."""
    pct = max(0.0, min(100.0, hrv_ratio * 100.0))
    return round(pct, 1), ("Incompatible" if hrv_ratio < HRV_INCOMPATIBLE_RATIO else "Compatible")


def _grade(good: bool, bad: bool) -> str:
    return "Good" if good else ("Bad" if bad else "Warning")


def interpret(tag: str, context: list[str], tone_change_pct: float, hrv_ratio: float) -> dict:
    stiffer = tone_change_pct > TONE_STIFFER_PCT
    softer = tone_change_pct < TONE_SOFTER_PCT
    hrv_low = hrv_ratio < HRV_INCOMPATIBLE_RATIO
    calmer = hrv_ratio > HRV_CALMER_RATIO
    caffeine = tag == "Caffeine" or "Caffeine" in context
    mental = "Stress" in context or "Poor-Sleep" in context

    # ---- Context Gate (PRD 2.D)
    if hrv_low and (caffeine or mental) and not stiffer:
        gate = ("Caffeine/Mental Stress", "HRV is low, vascular stiffness is normal and a stress context was "
                "tagged: likely caffeine or mental stress, not a metabolic load.")
    elif hrv_low and not stiffer:
        gate = ("Caffeine/Mental Stress", "HRV is low but vascular stiffness is normal: pattern fits "
                "caffeine or mental stress rather than a metabolic load.")
    elif hrv_low and stiffer:
        gate = ("Metabolic Overload", "HRV is low AND vascular stiffness rose: experimental pattern for "
                "high metabolic/glycemic stress (not a glucose reading).")
    else:
        gate = ("Normal", "No HRV drop beyond the PRD threshold.")

    findings = []
    findings.append("Vascular tone rose (b/a moved toward zero = stiffer)." if stiffer else
                    "Vascular tone eased (b/a more negative = more compliant)." if softer else
                    "Vascular tone is close to baseline.")
    findings.append("HRV (RMSSD) fell below 70% of baseline: higher autonomic stress load." if hrv_low else
                    "HRV (RMSSD) rose: stronger parasympathetic recovery." if calmer else
                    "HRV is within the normal range of your baseline.")
    findings.append(gate[1])

    # ---- Digital Cure (PRD 1 / View 3)
    actions = []
    if hrv_low and gate[0] != "Metabolic Overload":
        actions.append({"type": "Sitali Pranayama", "how": "5 minutes of cooling breath (curled-tongue inhale, "
                        "slow nasal exhale), then re-scan.", "reason": "HRV shows heat/stress load"})
    if stiffer:
        actions.append({"type": "Vajrasana", "how": "Sit in Vajrasana for 10 minutes, then re-scan "
                        "(tag the scan Post-Vajrasana).", "reason": "vascular tone is high (weak Agni proxy)"})
    if gate[0] == "Metabolic Overload":
        actions.append({"type": "Sitali Pranayama", "how": "5 minutes of cooling breath, then re-scan.",
                        "reason": "autonomic stress"})
        actions.append({"type": "Ginger Water / Pawanmuktasana", "how": "Warm ginger water and Pawanmuktasana "
                        "for a few minutes, then re-scan.", "reason": "experimental metabolic-overload pattern"})
    if not actions:
        actions.append({"type": "Maintain", "how": "Readings are stable - keep your routine and re-scan at "
                        "the same time of day.", "reason": "no trigger"})

    # ---- Reaction Report (PRD View 5): three dials
    dials = {
        "metabolic_load": {"grade": _grade(gate[0] == "Normal", gate[0] == "Metabolic Overload"),
                           "label": gate[0]},
        "digestive_fire": {"grade": _grade(not stiffer, stiffer and hrv_low),
                           "label": "vascular tone " + ("high" if stiffer else "low" if softer else "steady")},
        "stability": {"grade": _grade(not hrv_low, hrv_low and hrv_ratio < 0.5),
                      "label": "HRV ratio %.2f" % hrv_ratio},
    }
    grades = [d["grade"] for d in dials.values()]
    status = "attention" if "Bad" in grades else "watch" if "Warning" in grades else "balanced"

    directional = None
    if tag in YOGA_TAGS:       # PRD F5 / success metric: b/a should decrease (more negative) after Vajrasana
        directional = tone_change_pct < 0
        findings.append("b/a moved in the improving direction after Vajrasana." if directional else
                        "No improvement in b/a after Vajrasana this time (single scans vary; repeat).")
    return {"status": status, "gate": gate[0], "dials": dials, "findings": findings,
            "recommendations": actions, "directional_improvement": directional, "disclaimer": DISCLAIMER}
