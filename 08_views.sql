/* =====================================================================
   08_views.sql  |  BI-ready reporting views
   ---------------------------------------------------------------------
   These views are the contract between the warehouse and any BI tool
   (Looker / Metabase / Tableau). Business logic lives here, not in the
   dashboard, so a metric cannot be redefined by whoever builds the chart.

   Naming: vw_<grain>_<subject>
   Every view carries the same 1% take-rate revenue proxy used in
   07_kpis.sql. Change it here and in 07 together, or better, replace it
   with a real fee table when one exists.
   ===================================================================== */

USE crypto_app;

/* ---------- Executive headline, one row ---------- */
DROP VIEW IF EXISTS vw_exec_summary;
CREATE VIEW vw_exec_summary AS
SELECT
    COUNT(*)                                            AS total_users,
    SUM(is_kyc_completed)                               AS kyc_completed_users,
    SUM(is_activated)                                   AS funded_users,
    SUM(is_trader)                                      AS trading_users,
    ROUND(100*AVG(is_kyc_completed),2)                  AS kyc_pass_rate_pct,
    ROUND(100*AVG(is_activated),2)                      AS activation_rate_pct,
    ROUND(SUM(total_deposit_eur),0)                     AS total_deposits_eur,
    ROUND(SUM(total_trade_eur),0)                       AS total_trade_volume_eur,
    ROUND(0.01*SUM(total_trade_eur),0)                  AS est_revenue_eur,
    ROUND(SUM(acquisition_cost_eur),0)                  AS acquisition_spend_eur,
    ROUND(0.01*SUM(total_trade_eur)/NULLIF(SUM(acquisition_cost_eur),0),3) AS blended_roas,
    ROUND(0.01*SUM(total_trade_eur)/COUNT(*),2)         AS arpu_eur
FROM mart_user_360;

/* ---------- Funnel, reported both ways (see 05_funnel.sql) ---------- */
DROP VIEW IF EXISTS vw_funnel_stages;
CREATE VIEW vw_funnel_stages AS
SELECT 'penetration' AS funnel_type, '1. Signup' AS stage, COUNT(*) AS users,
       100.00 AS pct_of_signups FROM mart_user_360
UNION ALL SELECT 'penetration','2. KYC completed', SUM(is_kyc_completed),
       ROUND(100*AVG(is_kyc_completed),2) FROM mart_user_360
UNION ALL SELECT 'penetration','3. Funded', SUM(is_activated),
       ROUND(100*AVG(is_activated),2) FROM mart_user_360
UNION ALL SELECT 'penetration','4. Traded', SUM(is_trader),
       ROUND(100*AVG(is_trader),2) FROM mart_user_360
UNION ALL SELECT 'strict','1. Signup', COUNT(*), 100.00 FROM mart_user_360
UNION ALL SELECT 'strict','2. KYC completed', SUM(is_kyc_completed),
       ROUND(100*AVG(is_kyc_completed),2) FROM mart_user_360
UNION ALL SELECT 'strict','3. + Funded',
       SUM(is_kyc_completed=1 AND is_activated=1),
       ROUND(100*AVG(is_kyc_completed=1 AND is_activated=1),2) FROM mart_user_360
UNION ALL SELECT 'strict','4. + Traded',
       SUM(is_kyc_completed=1 AND is_activated=1 AND is_trader=1),
       ROUND(100*AVG(is_kyc_completed=1 AND is_activated=1 AND is_trader=1),2) FROM mart_user_360;

/* ---------- Channel unit economics ---------- */
DROP VIEW IF EXISTS vw_channel_economics;
CREATE VIEW vw_channel_economics AS
SELECT acquisition_channel,
       COUNT(*)                            AS signups,
       ROUND(SUM(acquisition_cost_eur),0)  AS spend_eur,
       ROUND(AVG(acquisition_cost_eur),2)  AS cac_per_signup_eur,
       SUM(is_activated)                   AS funded_users,
       ROUND(SUM(acquisition_cost_eur)/NULLIF(SUM(is_activated),0),2) AS effective_cac_eur,
       ROUND(100*AVG(is_activated),2)      AS activation_rate_pct,
       ROUND(0.01*SUM(total_trade_eur),0)  AS est_revenue_eur,
       ROUND(0.01*SUM(total_trade_eur)/NULLIF(SUM(acquisition_cost_eur),0),3) AS roas,
       CASE WHEN SUM(acquisition_cost_eur)=0 THEN 'unpaid'
            WHEN 0.01*SUM(total_trade_eur) >= SUM(acquisition_cost_eur) THEN 'profitable'
            ELSE 'loss-making' END         AS verdict
FROM mart_user_360 GROUP BY acquisition_channel;

/* ---------- Monthly business trend ---------- */
DROP VIEW IF EXISTS vw_monthly_trend;
CREATE VIEW vw_monthly_trend AS
SELECT s.m AS month, s.new_signups,
       COALESCE(d.deposit_value_eur,0) AS deposit_value_eur,
       COALESCE(t.trade_volume_eur,0)  AS trade_volume_eur,
       ROUND(0.01*COALESCE(t.trade_volume_eur,0),0) AS est_revenue_eur,
       COALESCE(a.mau,0) AS mau
FROM      (SELECT signup_month AS m, COUNT(*) AS new_signups FROM clean_users GROUP BY 1) s
LEFT JOIN (SELECT deposit_month AS m, ROUND(SUM(CASE WHEN is_completed=1 THEN amount_eur ELSE 0 END),0)
             AS deposit_value_eur FROM clean_deposits GROUP BY 1) d ON d.m=s.m
LEFT JOIN (SELECT transaction_month AS m, ROUND(SUM(CASE WHEN is_completed=1 THEN amount_eur ELSE 0 END),0)
             AS trade_volume_eur FROM clean_transactions GROUP BY 1) t ON t.m=s.m
LEFT JOIN (SELECT session_month AS m, COUNT(DISTINCT user_id) AS mau
             FROM clean_sessions GROUP BY 1) a ON a.m=s.m;

/* ---------- Actionable target segments ---------- */
DROP VIEW IF EXISTS vw_target_segments;
CREATE VIEW vw_target_segments AS
SELECT 'Verified, never funded' AS segment, COUNT(*) AS users,
       0 AS capital_eur,
       'Passed KYC but no deposit - largest leak, most qualified audience' AS action
FROM mart_user_360 WHERE is_kyc_completed=1 AND is_activated=0
UNION ALL
SELECT 'Funded, never traded', COUNT(*), ROUND(SUM(total_deposit_eur),0),
       'Idle balances - money in, zero product usage and zero revenue'
FROM mart_user_360 WHERE is_activated=1 AND is_trader=0
UNION ALL
SELECT 'KYC pending', COUNT(*), 0,
       'Stuck mid-verification - recoverable with a nudge'
FROM mart_user_360 WHERE kyc_status='Pending'
UNION ALL
SELECT 'KYC rejected', COUNT(*), 0,
       'Re-submission flow: 49% of rejections are document quality or expiry'
FROM mart_user_360 WHERE kyc_status='Rejected'
UNION ALL
SELECT 'Top-decile traders', COUNT(*), ROUND(SUM(total_deposit_eur),0),
       'Drive 36.5% of volume - weight retention and support here'
FROM (SELECT total_deposit_eur, NTILE(10) OVER (ORDER BY total_trade_eur DESC) AS d
      FROM mart_user_360 WHERE is_trader=1) x WHERE d=1;

/* ---------- Data-quality scorecard for monitoring ---------- */
DROP VIEW IF EXISTS vw_dq_scorecard;
CREATE VIEW vw_dq_scorecard AS
SELECT dimension, severity, table_name, check_name,
       rows_affected, rows_total, pct_affected,
       CASE WHEN rows_affected=0 THEN 'PASS' ELSE 'FAIL' END AS result,
       resolution
FROM dq_audit_log;

/* ---------- Verify ---------- */
SELECT * FROM vw_exec_summary;
SELECT * FROM vw_target_segments;
