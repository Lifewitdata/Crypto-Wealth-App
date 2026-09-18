# Crypto Wealth App — Product & Growth Analytics

End-to-end data analyst project on a 468,000-row consumer crypto app dataset:
50,000 users, their onboarding, app sessions, deposits and trades over
**2025-01-01 → 2026-08-31**.

The brief was product/user engagement, onboarding funnel, business KPIs, data
quality and actionable insight. A fair amount of the value here turned out to be
in **disproving** things that look like insight — three of the most quotable
findings in the raw data do not survive a significance test or a confounder check.

---

## Pipeline

```
CSV datasets
     ↓
MySQL  ──  staging (stg_*)  →  data-quality audit  →  clean (clean_*)  →  mart_user_360
     ↓
SQL cleaning + analysis  (funnel · engagement · KPIs · BI views)
     ↓
Jupyter Notebook
     ↓
Python EDA + statistical testing  (significance · confounding · censoring · distributions)
     ↓
Findings + recommendations
```

**Two-layer warehouse design.** `stg_*` is a permissive landing zone where nothing
is rejected, so defects stay visible and auditable. `clean_*` is typed, constrained,
indexed and analysis-ready. `mart_user_360` is a one-row-per-user join of
onboarding, engagement and monetisation — it is the single table the notebook
reads, so **SQL and Python cannot disagree about a definition**.

---

## Repository

```
swissborg_analytics/
├── sql/
│   ├── 01_schema.sql        Database, staging DDL, dq_audit_log table
│   ├── 02_load.sql          LOAD DATA LOCAL INFILE with NULLIF empty-string handling
│   ├── 03_data_quality.sql  23 checks across 7 DQ dimensions, logged not printed
│   ├── 04_cleaning.sql      stg → clean → mart, with quarantine table
│   ├── 05_funnel.sql        Onboarding funnel + right-censoring correction
│   ├── 06_engagement.sql    Sessions, DAU/MAU, cohort retention, churn proxy
│   ├── 07_kpis.sql          Unit economics, ROAS, concentration, asset mix
│   └── 08_views.sql         BI-ready views (the warehouse/BI contract)
├── notebooks/
│   └── 01_eda_and_analysis.ipynb    45 cells, executed with outputs
├── outputs/
│   ├── figures/             10 charts
│   └── tables/              5 exported CSVs
├── data/raw/                Source CSVs
└── reports/
    └── INSIGHTS.md          Stakeholder-facing findings and recommendations
```

---

## Reproducing

Requires MySQL 8.0 or MariaDB 10.11+ and Python 3.11+.

```bash
# 1. Build the warehouse (run from the project root — paths in 02_load.sql are relative)
mysql -u root < sql/01_schema.sql
mysql --local-infile=1 -u root crypto_app < sql/02_load.sql

# 2. Create the analytics user the notebook connects as
mysql -u root -e "CREATE USER 'analyst'@'%' IDENTIFIED BY 'analyst_pw';
                  GRANT ALL PRIVILEGES ON crypto_app.* TO 'analyst'@'%';"

# 3. Clean, then audit (03 includes business-rule checks that read the mart,
#    so 04 must exist before the full audit will run)
mysql -u root crypto_app < sql/04_cleaning.sql
mysql -u root crypto_app < sql/03_data_quality.sql

# 4. Analysis + views
for f in 05_funnel 06_engagement 07_kpis 08_views; do
    mysql -u root --table crypto_app < sql/$f.sql
done

# 5. Notebook
pip install pandas numpy scipy matplotlib seaborn sqlalchemy pymysql jupyter
jupyter notebook notebooks/01_eda_and_analysis.ipynb
```

Indexes on the staging tables matter — several DQ checks join 196k-row sessions
against 50k users, and without indexes the audit takes minutes instead of seconds.

---

## Data quality

23 checks across **Completeness, Uniqueness, Validity, Consistency, Referential
Integrity, Timeliness and Business Rules**, each scored HIGH/MEDIUM/LOW and written
to `dq_audit_log` with a stated resolution. 14 pass, 9 fail.

Referential integrity is clean: zero orphan foreign keys, zero users missing a KYC
or marketing record, zero events dated before signup, zero cross-table
contradictions on channel or signup date.

**Row-level defects and their treatment**

| Defect | Scale | Treatment | Why not delete |
|---|---|---|---|
| Duplicate `transaction_id` | 100 rows | De-duplicated via `ROW_NUMBER()` | Left in, they double-count trade volume |
| Negative `amount_eur` | 120 rows | Quarantined to a side table | Direction lives in `transaction_type`; a negative magnitude is corrupt, but the excluded value stays auditable |
| NULL `age_group` | 100 users | Relabelled `Unknown` | Dropping users biases funnel denominators |
| NULL `session_duration_sec` | 250 rows | Row kept, duration left NULL | The session happened (`screens_viewed` populated); only duration averages should exclude it |

Guiding principle: **never silently delete a user**. Deleting rows to make a metric
tidy biases the denominator.

Reconciliation is exact: 112,307 staged transactions − 100 duplicates − 120
quarantined = **112,087** clean.

**The serious failures are the business-rule ones** — not typos, but evidence that
the event tables were not generated in product order. See `reports/INSIGHTS.md`.

---

## Headline numbers

| Metric | Value |
|---|---|
| Users | 50,000 |
| KYC pass rate | 84.10% |
| Activation (funded) rate | 62.02% |
| Total deposits | €23,235,699 |
| Trade volume | €44,918,412 |
| Est. revenue @ 1% take rate | €449,184 |
| Acquisition spend | €485,226 |
| **Blended ROAS** | **0.93** |
| ARPU | €8.98 |
| Median deposit | €247 (mean €425 — log-normal) |

**Revenue assumption:** the dataset contains trade *volume*, not revenue. A flat
**1% take rate** on completed trade volume is used as a proxy, isolated in one place
so it can be re-parameterised. Break-even for the blended portfolio is a take rate
of **1.08%**. The assumption scales every channel identically, so the ROAS *ranking*
is unaffected by it.

---

## Method notes

Three results in this dataset look like strong signal and are not. Each is
documented in the notebook with the test that kills it:

- **Segment differences are noise.** Activation by channel, device, age, country
  and campaign all fail chi-square (p > 0.18) with Cramér's V ≈ 0.01. The 1.8pp
  channel spread is sampling variation across ~5,000-user groups.
- **Engagement → monetisation is tenure confounding.** Correlation falls from 0.28
  to **0.04** under partial correlation on tenure, and inverts in the 365d+ cohort.
- **The cohort conversion collapse is right-censoring.** A fixed 30-day window does
  not rescue it either — mean time-to-deposit scales with tenure (28 → 115 days),
  so time-to-event metrics are unusable for behavioural claims.

Deposits are cleanly log-normal (raw skew 8.7, excess kurtosis 257, log skew 0.00),
so the mean sits near the 70th percentile and the median is the honest headline.
Value-based testing should run on `log(amount)` or use non-parametric methods.
