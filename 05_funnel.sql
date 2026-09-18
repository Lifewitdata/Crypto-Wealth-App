/* =====================================================================
   05_funnel.sql  |  ONBOARDING FUNNEL
   ---------------------------------------------------------------------
   Funnel definition (each stage is a strict subset of the previous):
     1 Signup        - account created
     2 KYC started   - verification attempted
     3 KYC completed - verification passed
     4 First deposit - at least one Completed deposit
     5 First trade   - at least one Completed transaction
   Value is only ever counted on Completed events; attempts are counted
   separately so failure is measurable rather than invisible.
   ===================================================================== */

USE crypto_app;

/* ---------------------------------------------------------------------
   IMPORTANT CAVEAT (found during analysis, logged in dq_audit_log):
   The event tables do NOT respect the product sequence. 23.6% of users
   have a completed trade with no completed deposit, and 12.1% traded
   without passing KYC. A classic nested funnel would therefore report a
   step conversion above 100% and be misleading.
   We report TWO views:
     5.1a Stage penetration - each stage measured independently vs signups.
          This is the defensible headline view given the data.
     5.1b Strict nested funnel - restricted to users who satisfy every
          prior stage. This is the view to use ONCE the upstream ordering
          issue is fixed; shown here for comparison.
   --------------------------------------------------------------------- */

SELECT '=== 5.1a STAGE PENETRATION (independent, % of all signups) ===' AS section;

WITH f AS (
    SELECT COUNT(*)                          AS signups,
           SUM(kyc_started_date IS NOT NULL) AS kyc_started,
           SUM(is_kyc_completed)             AS kyc_completed,
           SUM(is_activated)                 AS deposited,
           SUM(is_trader)                    AS traded
    FROM mart_user_360
)
SELECT '1. Signup'        AS stage, signups       AS users, 100.00 AS pct_of_signups FROM f
UNION ALL SELECT '2. KYC started',   kyc_started,   ROUND(100*kyc_started/signups,2)   FROM f
UNION ALL SELECT '3. KYC completed', kyc_completed, ROUND(100*kyc_completed/signups,2) FROM f
UNION ALL SELECT '4. Funded (deposit)', deposited,  ROUND(100*deposited/signups,2)     FROM f
UNION ALL SELECT '5. Traded',        traded,        ROUND(100*traded/signups,2)        FROM f;

SELECT '=== 5.1b STRICT NESTED FUNNEL (each stage requires all prior stages) ===' AS section;

WITH n AS (
    SELECT COUNT(*) AS signups,
           SUM(is_kyc_completed) AS s3,
           SUM(is_kyc_completed=1 AND is_activated=1) AS s4,
           SUM(is_kyc_completed=1 AND is_activated=1 AND is_trader=1) AS s5
    FROM mart_user_360
)
SELECT '1. Signup' AS stage, signups AS users, 100.00 AS pct_of_signups,
       NULL AS step_conv_pct FROM n
UNION ALL SELECT '2. KYC completed', s3, ROUND(100*s3/signups,2), ROUND(100*s3/signups,2) FROM n
UNION ALL SELECT '3. + Funded',      s4, ROUND(100*s4/signups,2), ROUND(100*s4/s3,2)      FROM n
UNION ALL SELECT '4. + Traded',      s5, ROUND(100*s5/signups,2), ROUND(100*s5/s4,2)      FROM n;

SELECT '=== 5.2 DROP-OFF: where users are lost (strict funnel) ===' AS section;

WITH n AS (
    SELECT COUNT(*) AS signups,
           SUM(is_kyc_completed) AS s3,
           SUM(is_kyc_completed=1 AND is_activated=1) AS s4,
           SUM(is_kyc_completed=1 AND is_activated=1 AND is_trader=1) AS s5,
           SUM(kyc_status='Pending')  AS kyc_pending,
           SUM(kyc_status='Rejected') AS kyc_rejected
    FROM mart_user_360
)
SELECT 'Stage 1->2  KYC not completed' AS leak, signups-s3 AS users_lost,
       ROUND(100*(signups-s3)/signups,2) AS pct_of_signups,
       CONCAT(kyc_pending,' pending / ',kyc_rejected,' rejected') AS detail FROM n
UNION ALL
SELECT 'Stage 2->3  Verified but never funded', s3-s4, ROUND(100*(s3-s4)/signups,2),
       'LARGEST LEAK - verified users who never deposited' FROM n
UNION ALL
SELECT 'Stage 3->4  Funded but never traded', s4-s5, ROUND(100*(s4-s5)/signups,2),
       'Idle balances - money in, no product usage' FROM n;

SELECT '=== 5.2b THE SEQUENCE ANOMALY (quantified) ===' AS section;
SELECT CASE WHEN is_activated=1 AND is_trader=1 THEN 'Funded AND traded'
            WHEN is_activated=0 AND is_trader=1 THEN 'Traded WITHOUT funding (anomaly)'
            WHEN is_activated=1 AND is_trader=0 THEN 'Funded, never traded'
            ELSE 'Neither' END AS segment,
       COUNT(*) AS users, ROUND(100*COUNT(*)/SUM(COUNT(*)) OVER (),2) AS pct_of_base,
       ROUND(AVG(total_trade_eur),2) AS avg_trade_eur
FROM mart_user_360 GROUP BY 1 ORDER BY users DESC;

SELECT '=== 5.3 KYC REJECTION REASONS ===' AS section;
SELECT rejection_reason,
       COUNT(*) AS users,
       ROUND(100*COUNT(*)/SUM(COUNT(*)) OVER (),2) AS pct_of_rejections
FROM mart_user_360 WHERE kyc_status='Rejected'
GROUP BY rejection_reason ORDER BY users DESC;

SELECT '=== 5.4 KYC TURNAROUND (completed only) ===' AS section;
SELECT COUNT(*) AS n,
       ROUND(AVG(kyc_turnaround_days),2) AS avg_days,
       MIN(kyc_turnaround_days) AS min_days,
       MAX(kyc_turnaround_days) AS max_days,
       SUM(kyc_turnaround_days<=1) AS within_1d,
       ROUND(100*SUM(kyc_turnaround_days<=3)/COUNT(*),2) AS pct_within_3d,
       ROUND(100*SUM(kyc_turnaround_days>7)/COUNT(*),2)  AS pct_over_7d
FROM mart_user_360 WHERE is_kyc_completed=1;

SELECT '=== 5.5 DOES SLOW KYC SUPPRESS ACTIVATION? ===' AS section;
SELECT CASE WHEN kyc_turnaround_days <= 1 THEN 'a. 0-1 days'
            WHEN kyc_turnaround_days <= 3 THEN 'b. 2-3 days'
            WHEN kyc_turnaround_days <= 7 THEN 'c. 4-7 days'
            ELSE 'd. 8+ days' END AS kyc_speed_bucket,
       COUNT(*) AS users,
       ROUND(100*AVG(is_activated),2) AS deposit_rate_pct,
       ROUND(100*AVG(is_trader),2)    AS trade_rate_pct,
       ROUND(AVG(total_deposit_eur),2) AS avg_deposit_eur
FROM mart_user_360 WHERE is_kyc_completed=1
GROUP BY 1 ORDER BY 1;

SELECT '=== 5.6 FUNNEL BY ACQUISITION CHANNEL ===' AS section;
SELECT acquisition_channel,
       COUNT(*) AS signups,
       ROUND(100*AVG(is_kyc_completed),2) AS kyc_pass_pct,
       ROUND(100*AVG(is_activated),2)     AS deposit_pct,
       ROUND(100*AVG(is_trader),2)        AS trade_pct,
       ROUND(AVG(acquisition_cost_eur),2) AS avg_cac_eur
FROM mart_user_360 GROUP BY acquisition_channel ORDER BY deposit_pct DESC;

SELECT '=== 5.7 FUNNEL BY DEVICE AND AGE ===' AS section;
SELECT device_type, COUNT(*) AS signups,
       ROUND(100*AVG(is_kyc_completed),2) AS kyc_pass_pct,
       ROUND(100*AVG(is_activated),2)     AS deposit_pct,
       ROUND(100*AVG(is_trader),2)        AS trade_pct
FROM mart_user_360 GROUP BY device_type ORDER BY deposit_pct DESC;

SELECT age_group, COUNT(*) AS signups,
       ROUND(100*AVG(is_activated),2) AS deposit_pct,
       ROUND(100*AVG(is_trader),2)    AS trade_pct,
       ROUND(AVG(total_deposit_eur),2) AS avg_deposit_eur
FROM mart_user_360 GROUP BY age_group ORDER BY age_group;

SELECT '=== 5.8 TIME-TO-VALUE (speed through the funnel) ===' AS section;
SELECT 'Signup -> first deposit' AS journey, COUNT(*) AS users,
       ROUND(AVG(days_signup_to_deposit),2) AS avg_days,
       ROUND(100*SUM(days_signup_to_deposit<=1)/COUNT(*),2) AS pct_day0_1,
       ROUND(100*SUM(days_signup_to_deposit<=7)/COUNT(*),2) AS pct_within_7d,
       ROUND(100*SUM(days_signup_to_deposit<=30)/COUNT(*),2) AS pct_within_30d
FROM mart_user_360 WHERE is_activated=1
UNION ALL
SELECT 'Signup -> first trade', COUNT(*),
       ROUND(AVG(days_signup_to_trade),2),
       ROUND(100*SUM(days_signup_to_trade<=1)/COUNT(*),2),
       ROUND(100*SUM(days_signup_to_trade<=7)/COUNT(*),2),
       ROUND(100*SUM(days_signup_to_trade<=30)/COUNT(*),2)
FROM mart_user_360 WHERE is_trader=1;

SELECT '=== 5.9 MONTHLY SIGNUP COHORT FUNNEL ===' AS section;
SELECT signup_month, COUNT(*) AS signups,
       ROUND(100*AVG(is_kyc_completed),2) AS kyc_pass_pct,
       ROUND(100*AVG(is_activated),2)     AS deposit_pct,
       ROUND(100*AVG(is_trader),2)        AS trade_pct
FROM mart_user_360 GROUP BY signup_month ORDER BY signup_month;

/* =====================================================================
   5.10 CENSORING-CORRECTED COHORT CONVERSION
   ---------------------------------------------------------------------
   Section 5.9 appears to show conversion collapsing from ~77% to ~7%.
   That is an artefact, not a trend. Mean time-to-first-deposit is ~101
   days, so a cohort that signed up in Aug-2026 has only days of
   observation before the 2026-08-31 cut-off and CANNOT have converted yet.
   This is right-censoring (survivorship bias in the denominator).

   Correct approach: fix an observation window of W days and include a
   cohort only if every user in it has had at least W days to convert.
   Conversion is then counted only if it happened within W days of signup.
   This makes cohorts comparable on equal footing.
   ===================================================================== */

SELECT '=== 5.10a COHORT MATURITY (why 5.9 is misleading) ===' AS section;
SELECT signup_month, COUNT(*) AS signups,
       MIN(tenure_days) AS min_days_observed,
       CASE WHEN MIN(tenure_days) >= 30 THEN 'mature for 30d window'
            ELSE 'CENSORED - excluded' END AS status
FROM mart_user_360 GROUP BY signup_month ORDER BY signup_month;

SELECT '=== 5.10b 30-DAY CONVERSION, MATURE COHORTS ONLY ===' AS section;
SELECT signup_month, COUNT(*) AS signups,
       ROUND(100*AVG(days_signup_to_deposit <= 30),2) AS deposit_30d_pct,
       ROUND(100*AVG(days_signup_to_trade   <= 30),2) AS trade_30d_pct
FROM mart_user_360
WHERE tenure_days >= 30
GROUP BY signup_month
HAVING COUNT(*) > 0
ORDER BY signup_month;

SELECT '=== 5.10c CHANNEL CONVERSION, CENSORING-CORRECTED (30d window) ===' AS section;
SELECT acquisition_channel, COUNT(*) AS mature_signups,
       ROUND(100*AVG(days_signup_to_deposit <= 30),2) AS deposit_30d_pct,
       ROUND(100*AVG(days_signup_to_trade   <= 30),2) AS trade_30d_pct,
       ROUND(AVG(acquisition_cost_eur),2) AS avg_cac_eur
FROM mart_user_360 WHERE tenure_days >= 30
GROUP BY acquisition_channel ORDER BY deposit_30d_pct DESC;
