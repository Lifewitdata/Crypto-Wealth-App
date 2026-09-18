/* =====================================================================
   07_kpis.sql  |  BUSINESS KPIs & UNIT ECONOMICS
   ---------------------------------------------------------------------
   REVENUE ASSUMPTION (stated explicitly because it drives every figure
   below): the dataset contains trade VOLUME, not revenue. A crypto
   wealth app typically earns a spread/fee on executed volume. We apply
   a flat 1.00% take rate to COMPLETED trade volume as a revenue proxy.
   The take rate is isolated in one place so it can be re-parameterised;
   all ratios below scale linearly with it.
   ===================================================================== */

USE crypto_app;

SELECT '=== 7.1 HEADLINE KPIs ===' AS section;
SELECT
  (SELECT COUNT(*) FROM clean_users)                                        AS total_users,
  (SELECT COUNT(*) FROM mart_user_360 WHERE is_activated=1)                 AS funded_users,
  (SELECT ROUND(100*AVG(is_activated),2) FROM mart_user_360)                AS activation_rate_pct,
  (SELECT ROUND(SUM(amount_eur),0) FROM clean_deposits WHERE is_completed=1) AS total_deposits_eur,
  (SELECT ROUND(SUM(amount_eur),0) FROM clean_transactions WHERE is_completed=1) AS total_trade_volume_eur,
  (SELECT ROUND(0.01*SUM(amount_eur),0) FROM clean_transactions WHERE is_completed=1) AS est_revenue_eur,
  (SELECT ROUND(SUM(acquisition_cost_eur),0) FROM clean_marketing)          AS total_cac_spend_eur;

SELECT '=== 7.2 ARPU / ARPPU / DEPOSIT PER USER ===' AS section;
SELECT ROUND(0.01*SUM(total_trade_eur)/COUNT(*),2)                        AS arpu_all_users_eur,
       ROUND(0.01*SUM(total_trade_eur)/NULLIF(SUM(is_trader),0),2)        AS arppu_traders_eur,
       ROUND(SUM(total_deposit_eur)/COUNT(*),2)                           AS avg_deposit_per_user_eur,
       ROUND(SUM(total_deposit_eur)/NULLIF(SUM(is_activated),0),2)        AS avg_deposit_per_funded_user_eur,
       ROUND(AVG(n_trades),2)                                             AS avg_trades_per_user
FROM mart_user_360;

SELECT '=== 7.3 REVENUE CONCENTRATION (whale analysis) ===' AS section;
/* If a small share of users drives most volume, retention priorities and
   support SLAs should be weighted towards them. */
SELECT decile,
       COUNT(*) AS users,
       ROUND(SUM(total_trade_eur),0) AS trade_volume_eur,
       ROUND(100*SUM(total_trade_eur)/SUM(SUM(total_trade_eur)) OVER (),2) AS pct_of_volume
FROM (
  SELECT total_trade_eur,
         NTILE(10) OVER (ORDER BY total_trade_eur DESC) AS decile
  FROM mart_user_360 WHERE is_trader=1
) x GROUP BY decile ORDER BY decile;

SELECT '=== 7.4 CHANNEL ROI / UNIT ECONOMICS ===' AS section;
/* CAC is spend per SIGNUP; effective CAC is spend per FUNDED user, which
   is the number that actually matters. ROAS uses the 1% revenue proxy. */
SELECT acquisition_channel,
       COUNT(*)                                             AS signups,
       ROUND(SUM(acquisition_cost_eur),0)                   AS spend_eur,
       ROUND(AVG(acquisition_cost_eur),2)                   AS cac_per_signup_eur,
       SUM(is_activated)                                    AS funded_users,
       ROUND(SUM(acquisition_cost_eur)/NULLIF(SUM(is_activated),0),2) AS effective_cac_eur,
       ROUND(0.01*SUM(total_trade_eur),0)                   AS est_revenue_eur,
       ROUND(0.01*SUM(total_trade_eur)/NULLIF(COUNT(*),0),2) AS revenue_per_signup_eur,
       ROUND(0.01*SUM(total_trade_eur)/NULLIF(SUM(acquisition_cost_eur),0),2) AS roas
FROM mart_user_360
GROUP BY acquisition_channel
ORDER BY est_revenue_eur DESC;

SELECT '=== 7.5 CAMPAIGN PERFORMANCE ===' AS section;
SELECT campaign, COUNT(*) AS signups,
       ROUND(SUM(acquisition_cost_eur),0) AS spend_eur,
       ROUND(100*AVG(is_activated),2)     AS activation_pct,
       ROUND(SUM(acquisition_cost_eur)/NULLIF(SUM(is_activated),0),2) AS effective_cac_eur,
       ROUND(0.01*SUM(total_trade_eur)/NULLIF(SUM(acquisition_cost_eur),0),2) AS roas
FROM mart_user_360 GROUP BY campaign
HAVING SUM(acquisition_cost_eur) > 0
ORDER BY roas DESC;

SELECT '=== 7.6 PAYMENT METHOD PERFORMANCE (failure = lost revenue) ===' AS section;
SELECT payment_method,
       COUNT(*) AS attempts,
       SUM(status='Completed') AS completed,
       ROUND(100*SUM(status='Completed')/COUNT(*),2) AS success_rate_pct,
       ROUND(100*SUM(status='Failed')/COUNT(*),2)    AS failure_rate_pct,
       ROUND(100*SUM(status='Pending')/COUNT(*),2)   AS pending_rate_pct,
       ROUND(AVG(CASE WHEN status='Completed' THEN amount_eur END),2) AS avg_completed_eur,
       ROUND(SUM(CASE WHEN status='Failed' THEN amount_eur ELSE 0 END),0) AS failed_value_eur
FROM clean_deposits GROUP BY payment_method ORDER BY attempts DESC;

SELECT '=== 7.7 DEPOSIT FUNNEL LEAKAGE (value at risk) ===' AS section;
SELECT status, COUNT(*) AS deposits,
       ROUND(100*COUNT(*)/SUM(COUNT(*)) OVER (),2) AS pct_of_deposits,
       ROUND(SUM(amount_eur),0) AS value_eur,
       ROUND(100*SUM(amount_eur)/SUM(SUM(amount_eur)) OVER (),2) AS pct_of_value
FROM clean_deposits GROUP BY status ORDER BY value_eur DESC;

SELECT '=== 7.8 TRADING: ASSET MIX ===' AS section;
SELECT asset, COUNT(*) AS trades,
       COUNT(DISTINCT user_id) AS traders,
       ROUND(SUM(CASE WHEN is_completed=1 THEN amount_eur ELSE 0 END),0) AS volume_eur,
       ROUND(100*SUM(CASE WHEN is_completed=1 THEN amount_eur ELSE 0 END)
             /SUM(SUM(CASE WHEN is_completed=1 THEN amount_eur ELSE 0 END)) OVER (),2) AS pct_volume,
       ROUND(AVG(CASE WHEN is_completed=1 THEN amount_eur END),2) AS avg_trade_eur,
       ROUND(100*SUM(status='Failed')/COUNT(*),2) AS fail_rate_pct
FROM clean_transactions GROUP BY asset ORDER BY volume_eur DESC;

SELECT '=== 7.9 TRADING: TYPE MIX & EXECUTION QUALITY ===' AS section;
SELECT transaction_type, COUNT(*) AS trades,
       ROUND(100*COUNT(*)/SUM(COUNT(*)) OVER (),2) AS pct_of_trades,
       ROUND(SUM(CASE WHEN is_completed=1 THEN amount_eur ELSE 0 END),0) AS volume_eur,
       ROUND(100*SUM(status='Completed')/COUNT(*),2) AS success_rate_pct,
       ROUND(100*SUM(status='Failed')/COUNT(*),2)    AS fail_rate_pct
FROM clean_transactions GROUP BY transaction_type ORDER BY volume_eur DESC;

SELECT '=== 7.10 MONTHLY BUSINESS TREND ===' AS section;
SELECT d.m AS month,
       d.deposit_value_eur, d.deposits,
       t.trade_volume_eur, t.trades,
       ROUND(0.01*t.trade_volume_eur,0) AS est_revenue_eur,
       u.new_signups
FROM (SELECT deposit_month AS m, ROUND(SUM(CASE WHEN is_completed=1 THEN amount_eur ELSE 0 END),0) AS deposit_value_eur,
             COUNT(*) AS deposits FROM clean_deposits GROUP BY 1) d
LEFT JOIN (SELECT transaction_month AS m, ROUND(SUM(CASE WHEN is_completed=1 THEN amount_eur ELSE 0 END),0) AS trade_volume_eur,
             COUNT(*) AS trades FROM clean_transactions GROUP BY 1) t ON t.m=d.m
LEFT JOIN (SELECT signup_month AS m, COUNT(*) AS new_signups FROM clean_users GROUP BY 1) u ON u.m=d.m
ORDER BY d.m;

SELECT '=== 7.11 GEOGRAPHIC PERFORMANCE ===' AS section;
SELECT country, COUNT(*) AS users,
       ROUND(100*AVG(is_activated),2) AS activation_pct,
       ROUND(AVG(total_deposit_eur),2) AS avg_deposit_eur,
       ROUND(0.01*SUM(total_trade_eur),0) AS est_revenue_eur,
       ROUND(0.01*SUM(total_trade_eur)/COUNT(*),2) AS revenue_per_user_eur
FROM mart_user_360 GROUP BY country ORDER BY revenue_per_user_eur DESC;
