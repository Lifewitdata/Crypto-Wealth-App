/* =====================================================================
   03_data_quality.sql  |  Profiling & DQ audit against the staging layer
   ---------------------------------------------------------------------
   Framework: each check is scored on one of six DQ dimensions and
   logged to dq_audit_log with a severity and a stated resolution.
   Severity drives what 04_cleaning.sql does:
       HIGH   -> must fix before analysis (corrupts a headline metric)
       MEDIUM -> fix, but impact is contained
       LOW    -> document only, no material impact
   ===================================================================== */

USE crypto_app;
TRUNCATE TABLE dq_audit_log;

/* ---------- 1. UNIQUENESS: duplicate primary keys ---------- */

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_transactions','Duplicate transaction_id','Uniqueness','HIGH',
       (SELECT COUNT(*) FROM (SELECT transaction_id FROM stg_transactions
                              GROUP BY transaction_id HAVING COUNT(*)>1) x),
       (SELECT COUNT(*) FROM stg_transactions),
       ROUND(100*(SELECT COUNT(*) FROM (SELECT transaction_id FROM stg_transactions
              GROUP BY transaction_id HAVING COUNT(*)>1) y)/(SELECT COUNT(*) FROM stg_transactions),4),
       'Deduplicate on transaction_id keeping one row (rows are byte-identical)';

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_users','Duplicate user_id','Uniqueness','HIGH',
       (SELECT COUNT(*) FROM (SELECT user_id FROM stg_users GROUP BY user_id HAVING COUNT(*)>1) x),
       (SELECT COUNT(*) FROM stg_users), 0, 'None required if zero';

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_sessions','Duplicate session_id','Uniqueness','HIGH',
       (SELECT COUNT(*) FROM (SELECT session_id FROM stg_sessions GROUP BY session_id HAVING COUNT(*)>1) x),
       (SELECT COUNT(*) FROM stg_sessions), 0, 'None required if zero';

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_deposits','Duplicate deposit_id','Uniqueness','HIGH',
       (SELECT COUNT(*) FROM (SELECT deposit_id FROM stg_deposits GROUP BY deposit_id HAVING COUNT(*)>1) x),
       (SELECT COUNT(*) FROM stg_deposits), 0, 'None required if zero';

/* ---------- 2. VALIDITY: impossible values ---------- */

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_transactions','Negative amount_eur','Validity','HIGH',
       SUM(amount_eur < 0), COUNT(*), ROUND(100*SUM(amount_eur<0)/COUNT(*),4),
       'Quarantine: exclude from volume/ARPU. Trade amounts are unsigned; direction is in transaction_type'
FROM stg_transactions;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_deposits','Non-positive amount_eur','Validity','HIGH',
       SUM(amount_eur <= 0), COUNT(*), ROUND(100*SUM(amount_eur<=0)/COUNT(*),4),
       'Quarantine if present'
FROM stg_deposits;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_sessions','Duration outside 1s-4h plausible range','Validity','LOW',
       SUM(session_duration_sec <= 0 OR session_duration_sec > 14400), COUNT(*),
       ROUND(100*SUM(session_duration_sec<=0 OR session_duration_sec>14400)/COUNT(*),4),
       'Cap at 99.9th pct if present'
FROM stg_sessions;

/* ---------- 3. COMPLETENESS: nulls in analytically-used fields ---------- */

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_users','NULL age_group','Completeness','MEDIUM',
       SUM(age_group IS NULL), COUNT(*), ROUND(100*SUM(age_group IS NULL)/COUNT(*),4),
       'Relabel to "Unknown" - keeps the user in funnel counts instead of dropping them'
FROM stg_users;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_sessions','NULL session_duration_sec','Completeness','MEDIUM',
       SUM(session_duration_sec IS NULL), COUNT(*),
       ROUND(100*SUM(session_duration_sec IS NULL)/COUNT(*),4),
       'Keep row (session still happened, screens_viewed intact); exclude from duration averages only'
FROM stg_sessions;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_kyc','NULL kyc_completed_date','Completeness','LOW',
       SUM(kyc_completed_date IS NULL), COUNT(*),
       ROUND(100*SUM(kyc_completed_date IS NULL)/COUNT(*),4),
       'EXPECTED - null only where status is Pending/Rejected. Not a defect'
FROM stg_kyc;

/* ---------- 4. CONSISTENCY: cross-field / cross-table logic ---------- */

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_kyc','Status=Completed but completion date missing','Consistency','HIGH',
       SUM(kyc_status='Completed' AND kyc_completed_date IS NULL), COUNT(*), 0,
       'Would invalidate KYC turnaround metric'
FROM stg_kyc;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_kyc','KYC completed before started','Consistency','HIGH',
       SUM(kyc_completed_date < kyc_started_date), COUNT(*), 0,
       'Negative turnaround times'
FROM stg_kyc;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_users vs stg_marketing_channels','Acquisition channel disagrees between tables','Consistency','HIGH',
       COUNT(*), (SELECT COUNT(*) FROM stg_users), 0,
       'Marketing table would be untrustworthy for CAC attribution'
FROM stg_users u JOIN stg_marketing_channels m USING (user_id)
WHERE u.acquisition_channel <> m.channel OR u.signup_date <> m.signup_date;

/* Events that occur before the user existed */
INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_deposits','Deposit dated before user signup','Consistency','HIGH',
       COUNT(*), (SELECT COUNT(*) FROM stg_deposits), 0, 'Would corrupt time-to-deposit funnel'
FROM stg_deposits d JOIN stg_users u USING (user_id) WHERE d.deposit_date < u.signup_date;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_sessions','Session dated before user signup','Consistency','HIGH',
       COUNT(*), (SELECT COUNT(*) FROM stg_sessions), 0, 'Would corrupt retention day-index'
FROM stg_sessions s JOIN stg_users u USING (user_id) WHERE s.session_date < u.signup_date;

/* ---------- 5. REFERENTIAL INTEGRITY: orphan foreign keys ---------- */

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_transactions','user_id not present in users','Integrity','HIGH',
       COUNT(*), (SELECT COUNT(*) FROM stg_transactions), 0, 'Orphan events inflate activity vs user base'
FROM stg_transactions t LEFT JOIN stg_users u USING (user_id) WHERE u.user_id IS NULL;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_deposits','user_id not present in users','Integrity','HIGH',
       COUNT(*), (SELECT COUNT(*) FROM stg_deposits), 0, 'Orphan events inflate deposit metrics'
FROM stg_deposits d LEFT JOIN stg_users u USING (user_id) WHERE u.user_id IS NULL;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_users','User has no KYC record','Integrity','MEDIUM',
       COUNT(*), (SELECT COUNT(*) FROM stg_users), 0, 'Users missing from the onboarding funnel entirely'
FROM stg_users u LEFT JOIN stg_kyc k USING (user_id) WHERE k.user_id IS NULL;

/* ---------- 6. TIMELINESS: observation window ---------- */

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'stg_sessions','Events after stated analysis cut-off 2026-08-31','Timeliness','MEDIUM',
       SUM(session_date > '2026-08-31'), COUNT(*), 0,
       'Cut-off fixed at 2026-08-31 = max event date across fact tables'
FROM stg_sessions;

/* ---------- 7. BUSINESS-RULE / SEQUENCE INTEGRITY ----------
   These checks encode how the product is *supposed* to work. They were
   added after the first funnel run showed more traders than depositors,
   which is impossible if trading requires funded, verified accounts.
   Run against the clean layer, so 04_cleaning.sql must execute first.
   ------------------------------------------------------------------- */

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'mart_user_360','Traded without any completed deposit','Business Rule','HIGH',
       SUM(is_trader=1 AND is_activated=0), COUNT(*),
       ROUND(100*SUM(is_trader=1 AND is_activated=0)/COUNT(*),4),
       'Unfunded trading is impossible. Deposits table likely missing a funding source (e.g. crypto transfer-in) OR trades are mis-attributed'
FROM mart_user_360;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'mart_user_360','Traded without completing KYC','Business Rule','HIGH',
       SUM(is_trader=1 AND is_kyc_completed=0), COUNT(*),
       ROUND(100*SUM(is_trader=1 AND is_kyc_completed=0)/COUNT(*),4),
       'Regulatory red flag: unverified users transacting. Escalate to Compliance before using funnel for reporting'
FROM mart_user_360;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'mart_user_360','Deposited without completing KYC','Business Rule','HIGH',
       SUM(is_activated=1 AND is_kyc_completed=0), COUNT(*),
       ROUND(100*SUM(is_activated=1 AND is_kyc_completed=0)/COUNT(*),4),
       'Funding an unverified account. Same escalation path'
FROM mart_user_360;

INSERT INTO dq_audit_log (table_name,check_name,dimension,severity,rows_affected,rows_total,pct_affected,resolution)
SELECT 'mart_user_360','First trade occurs before first deposit','Business Rule','HIGH',
       SUM(first_trade_date < first_deposit_date), SUM(is_trader=1 AND is_activated=1),
       ROUND(100*SUM(first_trade_date < first_deposit_date)/SUM(is_trader=1 AND is_activated=1),4),
       'Event ordering violated for dual-action users. Suggests fact tables generated independently of the funnel'
FROM mart_user_360;

/* =============== DQ REPORT =============== */
SELECT dimension, severity, table_name, check_name,
       rows_affected, rows_total, pct_affected,
       CASE WHEN rows_affected = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM dq_audit_log
ORDER BY (rows_affected = 0), FIELD(severity,'HIGH','MEDIUM','LOW'), rows_affected DESC;

SELECT CASE WHEN rows_affected=0 THEN 'PASS' ELSE 'FAIL' END AS result,
       COUNT(*) AS checks
FROM dq_audit_log GROUP BY 1;
