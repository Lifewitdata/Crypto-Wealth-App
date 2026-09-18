# Findings & Recommendations

**Dataset:** 50,000 users, 2025-01-01 → 2026-08-31 (cut-off = max event date)
**Revenue basis:** 1% take rate on completed trade volume — a stated proxy, not a
measured fee. Break-even for the blended portfolio is 1.08%.

---

## 1. Paid acquisition is losing money

€485,226 of acquisition spend has produced an estimated €449,184 of revenue —
a **blended ROAS of 0.93**, roughly €0.07 lost per euro spent. This is measured
against *all* revenue accumulated to date, not a truncated window, so it is not a
payback-period artefact.

| Channel | Signups | Spend | Effective CAC | Est. revenue | ROAS |
|---|---|---|---|---|---|
| Email | 3,975 | €20,439 | €8.29 | €35,676 | **1.75** |
| Referral | 7,583 | €70,576 | €15.13 | €66,917 | 0.95 |
| Social | 7,976 | €115,596 | €23.77 | €71,008 | 0.61 |
| Paid Search | 8,919 | €165,353 | €30.00 | €80,807 | 0.49 |
| Affiliate | 4,995 | €113,262 | €36.09 | €45,871 | 0.40 |
| Organic | 12,035 | €0 | €0 | €109,560 | — |
| Direct | 4,517 | €0 | €0 | €39,345 | — |

The important structural point: **activation rates are statistically identical
across all channels** (§5). Paid channels are not buying better users — they are
buying the same users at very different prices. So the difference in ROAS is
almost entirely CAC, which makes the lever unambiguous.

**Recommendations**
- Cut or renegotiate **Affiliate** (€36.09 effective CAC for a user worth ~€9.18)
  and **Paid Search**. Together they consume €278,615 — 57% of total spend — at a
  blended ROAS of 0.46.
- Scale **Email** aggressively. It is the only paid channel clearly above
  break-even and has the lowest effective CAC by a factor of two.
- **Organic and Direct deliver 16,552 users at zero recorded cost** and activate
  at the same rate as everything paid. Fund the content/SEO and referral loops
  ahead of the auction channels.
- Before any of this ships, confirm the real take rate. Every figure above scales
  linearly with it, though the *ranking* does not change.

---

## 2. 15,962 verified users never funded — the largest leak

**31.9% of all signups pass KYC and then stop.** In the strict funnel:

| Stage | Users | % of signups | Step conversion |
|---|---|---|---|
| Signup | 50,000 | 100% | — |
| KYC completed | 42,051 | 84.1% | 84.1% |
| + Funded | 26,089 | 52.2% | **62.0%** |
| + Traded | 22,461 | 44.9% | 86.1% |

These users cleared the highest-friction step in the whole journey — they
submitted identity documents and waited an average of 3.5 days — and then did not
deposit. They are the most qualified population in the base, and the drop happens
at the funding step, not at verification.

Worth noting what is *not* the cause: KYC turnaround speed has **no significant
effect** on activation (ANOVA p = 0.09; 62.8% activation for 0–1 day approvals vs
62.0% for 4–7 days). Speeding up verification will not fix this. The friction is
in the deposit experience itself.

**Recommendations**
- Instrument the deposit screen properly — the current data cannot distinguish
  "never attempted" from "attempted and abandoned". This is the single highest-value
  gap in the tracking.
- Target the 15,962 with a funding-specific re-engagement flow, not generic
  onboarding nudges.
- Deposit *attempt* failure is a separate, smaller leak: 2,289 failed and 3,017
  pending deposits represent €2.25m of value not landing, at a uniform ~3.9%
  failure rate across all four payment methods (chi-square p = 0.19 — no single
  provider is at fault).

---

## 3. €2.97m sits idle with users who have never traded

4,354 users have funded accounts and zero completed trades. Median balance €409.
They generate no revenue at all under a volume-based model.

**Recommendation:** a first-trade activation flow for this segment. At the median
trade size of €223 a single trade each would generate only ~€9.7k, so the case for
this is habit formation and retention rather than immediate revenue — but idle
capital is also a competitive risk, since it can be withdrawn to a rival.

---

## 4. Revenue is heavily concentrated

| Trader decile | Share of volume |
|---|---|
| Top 10% | **36.5%** |
| Top 30% | 68.2% |
| Bottom 50% | 14.5% |

**Recommendation:** weight retention, support SLAs and churn alerting by value
decile rather than treating the base uniformly. Losing one top-decile trader is
worth roughly 40 bottom-decile traders.

Note that asset mix gives no differentiation to work with — all eight assets sit
within 12.2–12.8% of volume with near-identical average trade sizes and failure
rates. There is no product story in the asset data.

---

## 5. Three findings that look like signal and are not

This section exists because each of these would otherwise reach a dashboard and
drive a decision.

### 5.1 Segment differences in activation are noise

| Attribute | Observed spread | p-value | Cramér's V | Verdict |
|---|---|---|---|---|
| Acquisition channel | 1.84pp | 0.189 | 0.013 | noise |
| Device type | 0.37pp | 0.741 | 0.004 | noise |
| Age group | 5.14pp* | 0.924 | 0.005 | noise |
| Country | 1.59pp | 0.994 | 0.009 | noise |
| Campaign | 1.14pp | 0.851 | 0.008 | noise |

\* driven entirely by the 100-user `Unknown` age bucket.

Every confidence interval overlaps the overall mean. **Do not reallocate budget on
the basis of these conversion differences** — the ROAS case in §1 rests on cost,
which is real, not on conversion, which is not.

### 5.2 The engagement-to-revenue link is tenure confounding

The raw cut is compelling: activation rises from 24% (0 sessions) to 76% (6–9
sessions). It does not survive a control.

| | Pearson r |
|---|---|
| sessions ↔ activation | 0.282 |
| tenure ↔ sessions | 0.689 |
| tenure ↔ activation | 0.369 |
| **partial: sessions ↔ activation \| tenure** | **0.041** |

Within the 365d+ cohort the relationship actually **inverts** — 84.6% activation
at zero sessions versus 74.0% at 10+. Older accounts simply accumulate both more
sessions and more opportunities to deposit.

**Recommendation:** do not fund a "drive sessions to drive deposits" initiative on
this evidence. Establishing that link requires an experiment, or at minimum a
same-cohort fixed-window comparison.

### 5.3 The cohort conversion "collapse" is right-censoring

Naive monthly conversion appears to fall from 77% to 7%. It tracks the observation
window almost exactly. The standard fix — a fixed 30-day conversion window on
mature cohorts — produces the *opposite* artefact, rising from 17% to 65%, because
mean time-to-deposit scales with tenure (28 days for <90d users, 115 days for
365d+ users).

**Recommendation:** report no cohort trend from this data. The fix is upstream
instrumentation, not a smarter query.

---

## 6. Escalate: sequence integrity is broken

| Violation | Users | % of base |
|---|---|---|
| Traded without any completed deposit | 11,802 | 23.6% |
| Traded without completing KYC | 6,058 | 12.1% |
| Deposited without completing KYC | 4,922 | 9.8% |
| First trade before first deposit | 13,712 | 51.4% of dual-action users |

In a regulated crypto product none of these should be possible. The diagnostic
detail: KYC pass rate is **84.26%** among funded traders and **84.22%** among
unfunded traders — statistically indistinguishable. If unfunded trading were a
real product path (crypto transferred in rather than fiat deposited), those two
populations would differ on something. They do not, which points to the event
tables having been generated independently of the funnel.

**Two possible causes, and they need different owners:**
1. The `deposits` table captures only fiat funding and is missing crypto
   transfers-in — a **data completeness** problem for the data platform team.
2. Event ordering is not enforced — a **pipeline correctness** problem.

**Recommendations**
- The funnel must not be used for external, board or regulatory reporting until
  this is resolved. Internal directional use is defensible with the caveat attached.
- **Route the 6,058 unverified-trading accounts to Compliance for review.** Whether
  or not it is a data artefact, that is the correct handling.

---

## 7. Two further instrumentation gaps

**`account_status` carries no behavioural signal.** Active, Inactive and Suspended
users have statistically indistinguishable session counts (3.94 / 3.90 / 3.92),
deposit rates (62.1% / 61.6% / 62.9%) and average balances. Suspended users behave
exactly like active ones. The field is not derived from activity and **should not
be used as an engagement or churn proxy anywhere**.

**Engagement metrics are weak and should be verified before use.** DAU/MAU
stickiness sits at ~4% (healthy consumer fintech is typically 10–20%), and cohort
retention is *flat* at ~35% from month 1 through month 6 with no decay. Real
retention curves decay. A flat curve is a strong indicator that sessions were
sampled uniformly over each user's lifetime rather than reflecting behaviour —
consistent with the timing artefacts in §5.3. Treat both numbers as unvalidated.

---

## Priority summary

| # | Action | Owner | Confidence |
|---|---|---|---|
| 1 | Cut/renegotiate Affiliate + Paid Search; scale Email | Growth | High — cost data is reliable |
| 2 | Compliance review of 6,058 unverified trading accounts | Compliance | High — escalate regardless of cause |
| 3 | Resolve deposit-table completeness / event ordering | Data Platform | High |
| 4 | Funding-step re-engagement for 15,962 verified non-funders | Lifecycle | High |
| 5 | Instrument deposit-screen attempts and real event timestamps | Product/Eng | High |
| 6 | Value-weighted retention for top-decile traders | CRM | Medium — concentration is real, churn proxy is not |
| 7 | First-trade flow for 4,354 idle-balance users | Product | Medium |
| 8 | Stop using `account_status` as an engagement signal | Analytics | High |

**Not recommended:** channel-level targeting changes based on conversion,
session-driving campaigns justified by the engagement correlation, or any
initiative premised on the cohort conversion trend.
