/* =====================================================================
   04_cleaning.sql  |  STAGING -> CLEAN -> MART
   ---------------------------------------------------------------------
   Cleaning decisions are driven by the severity assigned in
   03_data_quality.sql. Guiding principle: never silently delete a user.
   Deleting rows to make a metric look tidy biases the denominator, so
   defects are either repaired, flagged, or quarantined to a side table
   that remains queryable.

   Analysis cut-off (ANALYSIS_DATE) = 2026-08-31, the maximum event date
   observed across all fact tables. Every "days since" metric is measured
   against this date so results are reproducible.
   ===================================================================== */

USE crypto_app;

/* ---------------- clean_users ----------------
   Fix: 100 NULL age_group -> 'Unknown'.
   Rationale: age_group is a segmentation dimension, not a filter.
   Dropping these users would remove them from funnel denominators and
   understate signups. 'Unknown' keeps them counted and visible.        */

DROP TABLE IF EXISTS clean_users;
CREATE TABLE clean_users (
    user_id             VARCHAR(20)  NOT NULL PRIMARY KEY,
    signup_date         DATE         NOT NULL,
    signup_month        DATE         NOT NULL,
    signup_week         DATE         NOT NULL,
    country             VARCHAR(60)  NOT NULL,
    age_group           VARCHAR(20)  NOT NULL,
    acquisition_channel VARCHAR(40)  NOT NULL,
    device_type         VARCHAR(20)  NOT NULL,
    account_status      VARCHAR(20)  NOT NULL,
    is_imputed_age      TINYINT      NOT NULL DEFAULT 0,
    tenure_days         INT          NOT NULL,
    INDEX ix_signup (signup_date),
    INDEX ix_channel (acquisition_channel),
    INDEX ix_country (country)
) ENGINE=InnoDB;

INSERT INTO clean_users
SELECT
    user_id,
    signup_date,
    DATE_FORMAT(signup_date,'%Y-%m-01')                       AS signup_month,
    DATE_SUB(signup_date, INTERVAL WEEKDAY(signup_date) DAY)  AS signup_week,
    TRIM(country),
    COALESCE(NULLIF(TRIM(age_group),''),'Unknown')            AS age_group,
    TRIM(acquisition_channel),
    TRIM(device_type),
    TRIM(account_status),
    CASE WHEN age_group IS NULL THEN 1 ELSE 0 END             AS is_imputed_age,
    DATEDIFF('2026-08-31', signup_date)                       AS tenure_days
FROM stg_users;

/* ---------------- clean_kyc ----------------
   No defects found. We derive turnaround days and a boolean outcome so
   downstream funnel queries do not repeat the same CASE logic.         */

DROP TABLE IF EXISTS clean_kyc;
CREATE TABLE clean_kyc (
    user_id            VARCHAR(20) NOT NULL PRIMARY KEY,
    kyc_started_date   DATE        NOT NULL,
    kyc_completed_date DATE        NULL,
    kyc_status         VARCHAR(20) NOT NULL,
    rejection_reason   VARCHAR(80) NULL,
    kyc_turnaround_days INT        NULL,
    is_kyc_completed   TINYINT     NOT NULL,
    INDEX ix_status (kyc_status)
) ENGINE=InnoDB;

INSERT INTO clean_kyc
SELECT user_id, kyc_started_date, kyc_completed_date, kyc_status, rejection_reason,
       DATEDIFF(kyc_completed_date, kyc_started_date),
       CASE WHEN kyc_status='Completed' THEN 1 ELSE 0 END
FROM stg_kyc;

/* ---------------- clean_marketing ---------------- */

DROP TABLE IF EXISTS clean_marketing;
CREATE TABLE clean_marketing (
    user_id              VARCHAR(20) NOT NULL PRIMARY KEY,
    channel              VARCHAR(40) NOT NULL,
    campaign             VARCHAR(60) NOT NULL,
    signup_date          DATE        NOT NULL,
    acquisition_cost_eur DECIMAL(10,2) NOT NULL,
    is_paid_channel      TINYINT     NOT NULL,
    INDEX ix_ch (channel), INDEX ix_cmp (campaign)
) ENGINE=InnoDB;

INSERT INTO clean_marketing
SELECT user_id, TRIM(channel), TRIM(campaign), signup_date,
       COALESCE(acquisition_cost_eur,0),
       CASE WHEN acquisition_cost_eur > 0 THEN 1 ELSE 0 END
FROM stg_marketing_channels;

/* ---------------- clean_sessions ----------------
   Fix: 250 NULL session_duration_sec are KEPT.
   Rationale: the session demonstrably happened (screens_viewed is
   populated and averages 6.9, in line with the overall mean). Dropping
   them would understate session counts and DAU. The NULL is preserved
   so AVG() ignores it natively; a flag makes the exclusion explicit.   */

DROP TABLE IF EXISTS clean_sessions;
CREATE TABLE clean_sessions (
    session_id           VARCHAR(20) NOT NULL PRIMARY KEY,
    user_id              VARCHAR(20) NOT NULL,
    session_date         DATE        NOT NULL,
    session_month        DATE        NOT NULL,
    session_duration_sec DECIMAL(10,2) NULL,
    screens_viewed       INT         NOT NULL,
    device_type          VARCHAR(20) NOT NULL,
    app_version          VARCHAR(20) NOT NULL,
    has_duration         TINYINT     NOT NULL,
    sec_per_screen       DECIMAL(10,2) NULL,
    INDEX ix_u (user_id), INDEX ix_dt (session_date), INDEX ix_ver (app_version)
) ENGINE=InnoDB;

INSERT INTO clean_sessions
SELECT session_id, user_id, session_date,
       DATE_FORMAT(session_date,'%Y-%m-01'),
       session_duration_sec, screens_viewed, TRIM(device_type), TRIM(app_version),
       CASE WHEN session_duration_sec IS NULL THEN 0 ELSE 1 END,
       CASE WHEN session_duration_sec IS NOT NULL AND screens_viewed > 0
            THEN ROUND(session_duration_sec/screens_viewed,2) END
FROM stg_sessions;

/* ---------------- clean_deposits ---------------- */

DROP TABLE IF EXISTS clean_deposits;
CREATE TABLE clean_deposits (
    deposit_id     VARCHAR(20) NOT NULL PRIMARY KEY,
    user_id        VARCHAR(20) NOT NULL,
    deposit_date   DATE        NOT NULL,
    deposit_month  DATE        NOT NULL,
    amount_eur     DECIMAL(12,2) NOT NULL,
    payment_method VARCHAR(40) NOT NULL,
    status         VARCHAR(20) NOT NULL,
    is_completed   TINYINT     NOT NULL,
    INDEX ix_u (user_id), INDEX ix_dt (deposit_date), INDEX ix_st (status)
) ENGINE=InnoDB;

INSERT INTO clean_deposits
SELECT deposit_id, user_id, deposit_date,
       DATE_FORMAT(deposit_date,'%Y-%m-01'),
       amount_eur, TRIM(payment_method), TRIM(status),
       CASE WHEN status='Completed' THEN 1 ELSE 0 END
FROM stg_deposits;

/* ---------------- clean_transactions ----------------
   Fix 1: 100 byte-identical duplicate transaction_id rows -> deduplicate.
           Left in place they double-count trade volume for those users.
   Fix 2: 120 negative amount_eur -> quarantine, not delete.
           Direction is already carried by transaction_type (Buy/Sell/Swap),
           so a negative magnitude is not a signed convention, it is
           corrupt. They are moved to quarantine_transactions so the
           volume of excluded value stays auditable.                     */

DROP TABLE IF EXISTS quarantine_transactions;
CREATE TABLE quarantine_transactions (
    transaction_id VARCHAR(20), user_id VARCHAR(20), transaction_date DATE,
    transaction_type VARCHAR(20), asset VARCHAR(20), amount_eur DECIMAL(12,2),
    status VARCHAR(20), quarantine_reason VARCHAR(80)
) ENGINE=InnoDB;

INSERT INTO quarantine_transactions
SELECT transaction_id,user_id,transaction_date,transaction_type,asset,amount_eur,status,
       'Negative amount_eur - invalid magnitude'
FROM stg_transactions
WHERE amount_eur < 0;

DROP TABLE IF EXISTS clean_transactions;
CREATE TABLE clean_transactions (
    transaction_id   VARCHAR(20) NOT NULL PRIMARY KEY,
    user_id          VARCHAR(20) NOT NULL,
    transaction_date DATE        NOT NULL,
    transaction_month DATE       NOT NULL,
    transaction_type VARCHAR(20) NOT NULL,
    asset            VARCHAR(20) NOT NULL,
    amount_eur       DECIMAL(12,2) NOT NULL,
    status           VARCHAR(20) NOT NULL,
    is_completed     TINYINT     NOT NULL,
    INDEX ix_u (user_id), INDEX ix_dt (transaction_date),
    INDEX ix_asset (asset), INDEX ix_st (status)
) ENGINE=InnoDB;

/* ROW_NUMBER de-duplication: keep exactly one row per transaction_id */
INSERT INTO clean_transactions
SELECT transaction_id, user_id, transaction_date,
       DATE_FORMAT(transaction_date,'%Y-%m-01'),
       transaction_type, asset, amount_eur, status,
       CASE WHEN status='Completed' THEN 1 ELSE 0 END
FROM (
    SELECT t.*,
           ROW_NUMBER() OVER (PARTITION BY transaction_id
                              ORDER BY transaction_date, amount_eur) AS rn
    FROM stg_transactions t
    WHERE amount_eur >= 0          -- negatives handled in quarantine
) d
WHERE rn = 1;

/* =====================================================================
   MART: mart_user_360
   One row per user joining onboarding, engagement and monetisation.
   This is the single table the Python notebook reads, so SQL and Python
   can never disagree about a definition.
   ===================================================================== */

DROP TABLE IF EXISTS mart_user_360;
CREATE TABLE mart_user_360 (
    user_id VARCHAR(20) NOT NULL PRIMARY KEY,
    signup_date DATE, signup_month DATE, signup_week DATE,
    country VARCHAR(60), age_group VARCHAR(20), device_type VARCHAR(20),
    acquisition_channel VARCHAR(40), campaign VARCHAR(60),
    acquisition_cost_eur DECIMAL(10,2), account_status VARCHAR(20),
    tenure_days INT,
    kyc_status VARCHAR(20), kyc_started_date DATE, kyc_completed_date DATE,
    rejection_reason VARCHAR(80),
    kyc_turnaround_days INT, is_kyc_completed TINYINT,
    first_deposit_date DATE, days_signup_to_deposit INT,
    n_deposits INT, n_deposits_failed INT,
    total_deposit_eur DECIMAL(14,2), avg_deposit_eur DECIMAL(12,2),
    first_trade_date DATE, days_signup_to_trade INT,
    n_trades INT, n_trades_failed INT,
    total_trade_eur DECIMAL(14,2), avg_trade_eur DECIMAL(12,2),
    n_assets_traded INT,
    n_sessions INT, total_session_sec DECIMAL(14,2),
    avg_session_sec DECIMAL(10,2), total_screens INT,
    first_session_date DATE, last_session_date DATE,
    active_days INT, days_since_last_session INT,
    is_activated TINYINT, is_trader TINYINT,
    INDEX ix_ch (acquisition_channel), INDEX ix_m (signup_month),
    INDEX ix_country (country), INDEX ix_act (is_activated)
) ENGINE=InnoDB;

INSERT INTO mart_user_360
SELECT
    u.user_id, u.signup_date, u.signup_month, u.signup_week,
    u.country, u.age_group, u.device_type,
    u.acquisition_channel, m.campaign, m.acquisition_cost_eur, u.account_status,
    u.tenure_days,
    k.kyc_status, k.kyc_started_date, k.kyc_completed_date, k.rejection_reason,
    k.kyc_turnaround_days, k.is_kyc_completed,
    d.first_deposit_date,
    DATEDIFF(d.first_deposit_date, u.signup_date),
    COALESCE(d.n_deposits,0), COALESCE(d.n_deposits_failed,0),
    COALESCE(d.total_deposit_eur,0), d.avg_deposit_eur,
    t.first_trade_date,
    DATEDIFF(t.first_trade_date, u.signup_date),
    COALESCE(t.n_trades,0), COALESCE(t.n_trades_failed,0),
    COALESCE(t.total_trade_eur,0), t.avg_trade_eur, COALESCE(t.n_assets_traded,0),
    COALESCE(s.n_sessions,0), COALESCE(s.total_session_sec,0),
    s.avg_session_sec, COALESCE(s.total_screens,0),
    s.first_session_date, s.last_session_date, COALESCE(s.active_days,0),
    DATEDIFF('2026-08-31', s.last_session_date),
    CASE WHEN d.first_deposit_date IS NOT NULL THEN 1 ELSE 0 END,
    CASE WHEN t.first_trade_date  IS NOT NULL THEN 1 ELSE 0 END
FROM clean_users u
LEFT JOIN clean_marketing m ON m.user_id = u.user_id
LEFT JOIN clean_kyc       k ON k.user_id = u.user_id
LEFT JOIN (
    /* Monetisation counts every attempt; value counts only Completed */
    SELECT user_id,
           MIN(CASE WHEN is_completed=1 THEN deposit_date END) AS first_deposit_date,
           SUM(is_completed)                                   AS n_deposits,
           SUM(status='Failed')                                AS n_deposits_failed,
           SUM(CASE WHEN is_completed=1 THEN amount_eur ELSE 0 END) AS total_deposit_eur,
           AVG(CASE WHEN is_completed=1 THEN amount_eur END)   AS avg_deposit_eur
    FROM clean_deposits GROUP BY user_id
) d ON d.user_id = u.user_id
LEFT JOIN (
    SELECT user_id,
           MIN(CASE WHEN is_completed=1 THEN transaction_date END) AS first_trade_date,
           SUM(is_completed)                                       AS n_trades,
           SUM(status='Failed')                                    AS n_trades_failed,
           SUM(CASE WHEN is_completed=1 THEN amount_eur ELSE 0 END) AS total_trade_eur,
           AVG(CASE WHEN is_completed=1 THEN amount_eur END)       AS avg_trade_eur,
           COUNT(DISTINCT CASE WHEN is_completed=1 THEN asset END) AS n_assets_traded
    FROM clean_transactions GROUP BY user_id
) t ON t.user_id = u.user_id
LEFT JOIN (
    SELECT user_id,
           COUNT(*) AS n_sessions,
           SUM(session_duration_sec) AS total_session_sec,
           AVG(session_duration_sec) AS avg_session_sec,
           SUM(screens_viewed)       AS total_screens,
           MIN(session_date)         AS first_session_date,
           MAX(session_date)         AS last_session_date,
           COUNT(DISTINCT session_date) AS active_days
    FROM clean_sessions GROUP BY user_id
) s ON s.user_id = u.user_id;

/* ---------------- Post-clean reconciliation ---------------- */
SELECT 'users'        AS entity, (SELECT COUNT(*) FROM stg_users) AS staged,        (SELECT COUNT(*) FROM clean_users) AS cleaned
UNION ALL SELECT 'kyc',          (SELECT COUNT(*) FROM stg_kyc),                    (SELECT COUNT(*) FROM clean_kyc)
UNION ALL SELECT 'sessions',     (SELECT COUNT(*) FROM stg_sessions),               (SELECT COUNT(*) FROM clean_sessions)
UNION ALL SELECT 'deposits',     (SELECT COUNT(*) FROM stg_deposits),               (SELECT COUNT(*) FROM clean_deposits)
UNION ALL SELECT 'transactions', (SELECT COUNT(*) FROM stg_transactions),           (SELECT COUNT(*) FROM clean_transactions)
UNION ALL SELECT 'quarantined',  0,                                                 (SELECT COUNT(*) FROM quarantine_transactions)
UNION ALL SELECT 'mart_user_360',(SELECT COUNT(*) FROM stg_users),                  (SELECT COUNT(*) FROM mart_user_360);
