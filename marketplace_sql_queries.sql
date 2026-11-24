-- ============================================================================
-- База: Таблицы user_activity_data, experiment_data
-- все p-value ниже — ДВУСТОРОННИЕ
-- ============================================================================

-- Число уникальных пользователей и период данных
SELECT COUNT(DISTINCT user_id) AS n_users,
       MIN(date)               AS first_date,
       MAX(date)               AS last_date,
       COUNT(DISTINCT date)    AS n_days
FROM user_activity_data;

-- WAU (weekly active users) по ISO-неделям
SELECT strftime('%Y-W%W', date) AS week,
       COUNT(DISTINCT user_id)  AS wau
FROM user_activity_data
GROUP BY week
ORDER BY week;

-- Retention: средний weekly retention по полным парам недель
-- (доля пользователей, активных в неделе N, которые вернулись в неделю N+1)
WITH wu AS (
    SELECT DISTINCT user_id, CAST(strftime('%W', date) AS INTEGER) AS wk
    FROM user_activity_data
),
wk_ret AS (
    SELECT a.wk,
           (SELECT COUNT(*) FROM wu b
             WHERE b.user_id IN (SELECT user_id FROM wu WHERE wk = a.wk)
               AND b.wk = a.wk + 1) * 1.0 /
           (SELECT COUNT(*) FROM wu WHERE wk = a.wk) AS ret
    FROM (SELECT DISTINCT wk FROM wu) a
    WHERE a.wk BETWEEN 1 AND 6
)
SELECT ROUND(100.0 * AVG(ret), 1) AS retention_pct
FROM wk_ret;


-- Доля трафика по устройствам
SELECT device,
       COUNT(*)                                          AS n_rows,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM user_activity_data), 1) AS pct_traffic
FROM user_activity_data
GROUP BY device;

-- Mobile vs desktop: активность и конверсия
SELECT device,
       ROUND(AVG(pages_viewed), 2)                                AS avg_pages_per_session,
       ROUND(SUM(paid_clicks)    * 1.0 / SUM(pages_viewed), 4)    AS ctr_paid,
       ROUND(SUM(organic_clicks) * 1.0 / SUM(pages_viewed), 4)    AS ctr_organic
FROM user_activity_data
GROUP BY device;

-- ----------------------------------------------------------------------------
-- Таблица дизайнов: MDE по длительности (2/3/4 недели)
-- ----------------------------------------------------------------------------
-- Входы для формул: N, σ(revenue) и R² CUPED для горизонта T = 14 дней
WITH u AS (
    -- revenue пользователя за первые T дней истории
    SELECT user_id,
           SUM(revenue)       AS rev,
           SUM(pages_viewed)  AS pv
    FROM user_activity_data
    WHERE julianday(date) - julianday('2026-01-01') < 14
    GROUP BY user_id
)
SELECT 14                                                AS t_days,
       COUNT(*)                                          AS n_total,
       COUNT(*) / 2                                      AS n_per_group,
       AVG(rev)                                          AS mean_rev,
       sqrt(AVG(rev*rev) - AVG(rev)*AVG(rev))            AS sigma_rev,
       (AVG(rev*pv)-AVG(rev)*AVG(pv))
         * (AVG(rev*pv)-AVG(rev)*AVG(pv))
         / ((AVG(rev*rev)-AVG(rev)*AVG(rev))
            * (AVG(pv*pv)-AVG(pv)*AVG(pv)))              AS r2_cuped
FROM u;


-- Итоговая таблица MDE одним запросом (все три горизонта)
WITH u AS (
    SELECT user_id,
           CASE WHEN julianday(date)-julianday('2026-01-01') < 14 THEN 14
                WHEN julianday(date)-julianday('2026-01-01') < 21 THEN 21
                ELSE 28 END AS t_days,
           revenue, pages_viewed
    FROM user_activity_data
),
per_user AS (
    SELECT t_days, user_id,
           SUM(revenue)      AS rev,
           SUM(pages_viewed) AS pv
    FROM u GROUP BY t_days, user_id
),
agg AS (
    SELECT t_days,
           COUNT(*)                                        AS n,
           AVG(rev)                                        AS mean,
           AVG(rev*rev)-AVG(rev)*AVG(rev)                  AS var_y,
           AVG(pv*pv)-AVG(pv)*AVG(pv)                      AS var_x,
           AVG(rev*pv)-AVG(rev)*AVG(pv)                    AS cov_xy
    FROM per_user GROUP BY t_days
)
SELECT t_days                                                        AS duration_days,
       n                                                            AS n_total,
       n / 2                                                        AS n_per_group,
       ROUND(2.8016 * sqrt(var_y) * sqrt(2.0 / (n/2)), 1)           AS mde_rev_raw,
       ROUND(2.8016 * sqrt(var_y * (1 - (cov_xy*cov_xy)/(var_y*var_x))) * sqrt(2.0/(n/2)), 1) AS mde_rev_cuped,
       ROUND(100.0 * 2.8016 * sqrt(var_y * (1 - (cov_xy*cov_xy)/(var_y*var_x))) * sqrt(2.0/(n/2)) / mean, 1) AS pct_lift_cuped
FROM agg
ORDER BY t_days;

-- ----------------------------------------------------------------------------
-- CUPED: снижение дисперсии
-- ----------------------------------------------------------------------------
-- Корреляция, R² и глобальный θ = Cov(Y,X)/Var(X)
-- Горизонт: первые 4 недели истории (совпадает с длительностью теста)
WITH u AS (
    SELECT user_id, SUM(revenue) AS rev, SUM(pages_viewed) AS pv
    FROM user_activity_data
    WHERE julianday(date) - julianday('2026-01-01') < 28
    GROUP BY user_id
),
s AS (
    SELECT AVG(rev*rev)-AVG(rev)*AVG(rev) AS var_y,
           AVG(pv*pv)-AVG(pv)*AVG(pv)     AS var_x,
           AVG(rev*pv)-AVG(rev)*AVG(pv)   AS cov_xy
    FROM u
)
SELECT ROUND(cov_xy / sqrt(var_y * var_x), 2)  AS r,
       ROUND((cov_xy*cov_xy) / (var_y*var_x), 2) AS r2,
       ROUND(cov_xy / var_x, 3)                AS theta_global
FROM s;

-- Снижение дисперсии после CUPED:
WITH u AS (
    SELECT user_id, SUM(revenue) AS rev, SUM(pages_viewed) AS pv
    FROM user_activity_data
    WHERE julianday(date) - julianday('2026-01-01') < 28
    GROUP BY user_id
),
s AS (
    SELECT AVG(rev*rev)-AVG(rev)*AVG(rev) AS var_y,
           AVG(pv*pv)-AVG(pv)*AVG(pv)     AS var_x,
           AVG(rev*pv)-AVG(rev)*AVG(pv)   AS cov_xy
    FROM u
)
SELECT ROUND(sqrt(var_y), 1)                                  AS sigma_before,
       ROUND(sqrt(var_y * (1 - (cov_xy*cov_xy)/(var_y*var_x))), 1) AS sigma_after,
       ROUND(100.0 * (1 - sqrt(1 - (cov_xy*cov_xy)/(var_y*var_x))), 0) AS sigma_reduction_pct
FROM s;


-- ----------------------------------------------------------------------------
-- Валидация дизайна
-- ----------------------------------------------------------------------------
-- SRM (Sample Ratio Mismatch)
WITH cnt AS (
    SELECT "group", COUNT(*) AS n
    FROM experiment_data GROUP BY "group"
),
tot AS (SELECT SUM(n) AS total FROM cnt)
SELECT cnt."group", cnt.n,
       tot.total / 2.0                                        AS expected,
       (cnt.n - tot.total/2.0)*(cnt.n - tot.total/2.0)/(tot.total/2.0) AS chi2_component
FROM cnt, tot;

-- Баланс ковариат между группами
WITH pre AS (
    SELECT user_id,
           AVG(revenue)      AS x_rev,
           AVG(pages_viewed) AS x_pv
    FROM user_activity_data GROUP BY user_id
),
j AS (
    SELECT e."group", p.x_rev, p.x_pv
    FROM experiment_data e JOIN pre p ON e.user_id = p.user_id
),
g AS (
    SELECT "group",
           AVG(x_rev) m_rev, AVG(x_pv) m_pv,
           AVG(x_rev*x_rev)-AVG(x_rev)*AVG(x_rev) v_rev,
           AVG(x_pv*x_pv)-AVG(x_pv)*AVG(x_pv)     v_pv,
           COUNT(*) n
    FROM j GROUP BY "group"
)
SELECT c.m_rev AS ctrl_pre_rev, t.m_rev AS test_pre_rev,
       (t.m_rev - c.m_rev) / sqrt(c.v_rev/c.n + t.v_rev/t.n) AS z_pre_rev,
       c.m_pv  AS ctrl_pre_pv,  t.m_pv  AS test_pre_pv,
       (t.m_pv - c.m_pv)  / sqrt(c.v_pv/c.n  + t.v_pv/t.n)  AS z_pre_pv
FROM g c JOIN g t ON c."group"='control' AND t."group"='test';


-- ----------------------------------------------------------------------------
-- Итоговый дизайн
-- ----------------------------------------------------------------------------
-- Средние CTR по группам (значения KPI-карточек)
SELECT "group",
       ROUND(AVG(ctr_paid), 3)    AS ctr_paid,
       ROUND(AVG(ctr_organic), 3) AS ctr_organic
FROM experiment_data
GROUP BY "group";

-- Относительные изменения Δ%
WITH g AS (
    SELECT "group", AVG(ctr_paid) cp, AVG(ctr_organic) co
    FROM experiment_data GROUP BY "group"
)
SELECT ROUND(100.0 * (t.cp - c.cp) / c.cp, 1)  AS ctr_paid_delta_pct,
       ROUND(100.0 * (t.co - c.co) / c.co, 1)  AS ctr_organic_delta_pct
FROM g c JOIN g t ON c."group"='control' AND t."group"='test';

-- CTR paid
WITH g AS (
    SELECT "group",
           AVG(ctr_paid) AS mean,
           AVG(ctr_paid*ctr_paid) - AVG(ctr_paid)*AVG(ctr_paid) AS var,
           COUNT(*) AS n
    FROM experiment_data GROUP BY "group"
),
tstat AS (
    SELECT (t.mean - c.mean) / sqrt(c.var/c.n + t.var/t.n) AS z
    FROM g c JOIN g t ON c."group"='control' AND t."group"='test'
)
SELECT ROUND(z, 2) AS z_stat,
       2 * (exp(-abs(z)*abs(z)/2.0) / sqrt(2*3.14159265358979))
         * ( 0.319381530*power(1.0/(1.0+0.2316419*abs(z)),1)
           + (-0.356563782)*power(1.0/(1.0+0.2316419*abs(z)),2)
           + 1.781477937*power(1.0/(1.0+0.2316419*abs(z)),3)
           + (-1.821255978)*power(1.0/(1.0+0.2316419*abs(z)),4)
           + 1.330274429*power(1.0/(1.0+0.2316419*abs(z)),5) ) AS p_value
FROM tstat;

-- CTR organic
WITH g AS (
    SELECT "group",
           AVG(ctr_organic) AS mean,
           AVG(ctr_organic*ctr_organic) - AVG(ctr_organic)*AVG(ctr_organic) AS var,
           COUNT(*) AS n
    FROM experiment_data GROUP BY "group"
),
tstat AS (
    SELECT (t.mean - c.mean) / sqrt(c.var/c.n + t.var/t.n) AS z
    FROM g c JOIN g t ON c."group"='control' AND t."group"='test'
)
SELECT ROUND(z, 2) AS z_stat,
       2 * (exp(-abs(z)*abs(z)/2.0) / sqrt(2*3.14159265358979))
         * ( 0.319381530*power(1.0/(1.0+0.2316419*abs(z)),1)
           + (-0.356563782)*power(1.0/(1.0+0.2316419*abs(z)),2)
           + 1.781477937*power(1.0/(1.0+0.2316419*abs(z)),3)
           + (-1.821255978)*power(1.0/(1.0+0.2316419*abs(z)),4)
           + 1.330274429*power(1.0/(1.0+0.2316419*abs(z)),5) ) AS p_value
FROM tstat;

-- Pages viewed (guardrail)
WITH g AS (
    SELECT "group",
           AVG(pages_viewed) AS mean,
           AVG(pages_viewed*pages_viewed) - AVG(pages_viewed)*AVG(pages_viewed) AS var,
           COUNT(*) AS n
    FROM experiment_data GROUP BY "group"
),
tstat AS (
    SELECT (t.mean - c.mean) / sqrt(c.var/c.n + t.var/t.n) AS z
    FROM g c JOIN g t ON c."group"='control' AND t."group"='test'
)
SELECT ROUND(z, 2) AS z_stat,
       2 * (exp(-abs(z)*abs(z)/2.0) / sqrt(2*3.14159265358979))
         * ( 0.319381530*power(1.0/(1.0+0.2316419*abs(z)),1)
           + (-0.356563782)*power(1.0/(1.0+0.2316419*abs(z)),2)
           + 1.781477937*power(1.0/(1.0+0.2316419*abs(z)),3)
           + (-1.821255978)*power(1.0/(1.0+0.2316419*abs(z)),4)
           + 1.330274429*power(1.0/(1.0+0.2316419*abs(z)),5) ) AS p_value
FROM tstat;

-- Revenue raw (без CUPED)
WITH g AS (
    SELECT "group",
           AVG(revenue) AS mean,
           AVG(revenue*revenue) - AVG(revenue)*AVG(revenue) AS var,
           COUNT(*) AS n
    FROM experiment_data GROUP BY "group"
),
tstat AS (
    SELECT (t.mean - c.mean) / sqrt(c.var/c.n + t.var/t.n) AS z
    FROM g c JOIN g t ON c."group"='control' AND t."group"='test'
)
SELECT ROUND(z, 2) AS z_stat,
       2 * (exp(-abs(z)*abs(z)/2.0) / sqrt(2*3.14159265358979))
         * ( 0.319381530*power(1.0/(1.0+0.2316419*abs(z)),1)
           + (-0.356563782)*power(1.0/(1.0+0.2316419*abs(z)),2)
           + 1.781477937*power(1.0/(1.0+0.2316419*abs(z)),3)
           + (-1.821255978)*power(1.0/(1.0+0.2316419*abs(z)),4)
           + 1.330274429*power(1.0/(1.0+0.2316419*abs(z)),5) ) AS p_value
FROM tstat;

-- Revenue через CUPED (KPI «flat, p≈0.96»):
WITH pre AS (
    SELECT user_id, AVG(revenue) AS x_rev
    FROM user_activity_data GROUP BY user_id
),
j AS (
    SELECT e."group", e.revenue AS y, p.x_rev AS x
    FROM experiment_data e JOIN pre p ON e.user_id = p.user_id
),
glob AS (
    SELECT AVG(x) gx,
           AVG(y*x)-AVG(y)*AVG(x) AS cov_xy,
           AVG(x*x)-AVG(x)*AVG(x) AS var_x
    FROM j
),
adj AS (
    SELECT j."group",
           j.y - (SELECT cov_xy/var_x FROM glob) * (j.x - (SELECT gx FROM glob)) AS y_adj
    FROM j
),
g AS (
    SELECT "group",
           AVG(y_adj) AS mean,
           AVG(y_adj*y_adj)-AVG(y_adj)*AVG(y_adj) AS var,
           COUNT(*) AS n
    FROM adj GROUP BY "group"
),
tstat AS (
    SELECT (t.mean - c.mean) / sqrt(c.var/c.n + t.var/t.n) AS z
    FROM g c JOIN g t ON c."group"='control' AND t."group"='test'
)
SELECT ROUND(z, 3) AS z_stat,
       2 * (exp(-abs(z)*abs(z)/2.0) / sqrt(2*3.14159265358979))
         * ( 0.319381530*power(1.0/(1.0+0.2316419*abs(z)),1)
           + (-0.356563782)*power(1.0/(1.0+0.2316419*abs(z)),2)
           + 1.781477937*power(1.0/(1.0+0.2316419*abs(z)),3)
           + (-1.821255978)*power(1.0/(1.0+0.2316419*abs(z)),4)
           + 1.330274429*power(1.0/(1.0+0.2316419*abs(z)),5) ) AS p_value
FROM tstat;

-- ----------------------------------------------------------------------------
-- Сравнение групп по метрикам (таблица)
-- Метрика | Control | Test | Δ% | p-value
-- ----------------------------------------------------------------------------
WITH g AS (
    SELECT "group",
           AVG(revenue)        AS m_rev,
           AVG(ctr_paid)       AS m_cp,
           AVG(ctr_organic)    AS m_co,
           AVG(pages_viewed)   AS m_pv,
           COUNT(*)            AS n
    FROM experiment_data GROUP BY "group"
)
SELECT 'Revenue (raw)'    AS metric, c.m_rev AS control, t.m_rev AS test,
       ROUND(100.0*(t.m_rev-c.m_rev)/c.m_rev, 2) AS delta_pct
FROM g c JOIN g t ON c."group"='control' AND t."group"='test'
UNION ALL
SELECT 'CTR paid',        c.m_cp, t.m_cp, ROUND(100.0*(t.m_cp-c.m_cp)/c.m_cp, 1)
FROM g c JOIN g t ON c."group"='control' AND t."group"='test'
UNION ALL
SELECT 'CTR organic',     c.m_co, t.m_co, ROUND(100.0*(t.m_co-c.m_co)/c.m_co, 1)
FROM g c JOIN g t ON c."group"='control' AND t."group"='test'
UNION ALL
SELECT 'Pages viewed',    c.m_pv, t.m_pv, ROUND(100.0*(t.m_pv-c.m_pv)/c.m_pv, 2)
FROM g c JOIN g t ON c."group"='control' AND t."group"='test';

-- CTR по device × group
SELECT device, "group",
       ROUND(AVG(ctr_organic), 4) AS ctr_organic,
       ROUND(AVG(ctr_paid), 4)    AS ctr_paid
FROM experiment_data
GROUP BY device, "group"
ORDER BY device, "group";


-- Относительное изменение CTR organic внутри каждого сегмента
WITH g AS (
    SELECT device, "group", AVG(ctr_organic) AS co
    FROM experiment_data GROUP BY device, "group"
)
SELECT c.device,
       c.co AS ctrl_ctr, t.co AS test_ctr,
       ROUND(100.0 * (t.co - c.co) / c.co, 1) AS delta_pct
FROM g c JOIN g t ON c.device = t.device
              AND c."group"='control' AND t."group"='test'
ORDER BY c.device;

