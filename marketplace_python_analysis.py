"""
================================================================================
PYTHON-РАСЧЁТЫ
База: marketpele.db (user_activity_data, experiment_data)
================================================================================
"""

import numpy as np
import pandas as pd
import sqlite3
from math import erf, sqrt, log


def norm_cdf(z):
    """CDF стандартного нормального распределения."""
    return 0.5 * (1 + erf(z / sqrt(2)))

def norm_ppf(p):
    """Квантиль нормального распределения (аппроксимация Acklam)."""
    if p <= 0 or p >= 1:
        raise ValueError("p must be in (0,1)")
    a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
         1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
    b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
         6.680131188771972e+01, -1.328068155288572e+01]
    c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
         -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
    d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
         3.754408661907416e+00]
    plow = 0.02425
    if p < plow:
        q = sqrt(-2 * log(p))
        return (((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / \
               ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)
    elif p > 1 - plow:
        q = sqrt(-2 * log(1 - p))
        return -(((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / \
                ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)
    else:
        q = p - 0.5
        r = q * q
        return (((((a[0]*r+a[1])*r+a[2])*r+a[3])*r+a[4])*r+a[5])*q / \
               (((((b[0]*r+b[1])*r+b[2])*r+b[3])*r+b[4])*r+1)

def welch_ttest(a, b):
    """Welch's t-test → (t_stat, p_value two-sided). Нормальная аппроксимация."""
    a = np.asarray(a, dtype=float)
    b = np.asarray(b, dtype=float)
    na, nb = len(a), len(b)
    ma, mb = a.mean(), b.mean()
    va, vb = a.var(ddof=1), b.var(ddof=1)
    se = sqrt(va/na + vb/nb)
    if se == 0:
        return 0.0, 1.0
    t = (mb - ma) / se
    num = (va/na + vb/nb)**2
    den = (va/na)**2/(na-1) + (vb/nb)**2/(nb-1)
    df = num / den if den > 0 else na + nb - 2
    if df > 100:
        p = 2 * (1 - norm_cdf(abs(t)))
    else:
        z = t * (1 - 1/(4*df)) / sqrt(1 + t*t/(2*df))
        p = 2 * (1 - norm_cdf(abs(z)))
    return t, max(min(p, 1.0), 0.0)


# ──────────────────────────────────────────────
# ЗАГРУЗКА ДАННЫХ
# ──────────────────────────────────────────────
con = sqlite3.connect("marketpele.db")
uad = pd.read_sql("SELECT * FROM user_activity_data", con)
exp = pd.read_sql('SELECT * FROM experiment_data', con)
con.close()

uad["day"] = (pd.to_datetime(uad["date"]) - pd.Timestamp("2026-01-01")).dt.days

print(f"user_activity_data: {len(uad)} rows, {uad['user_id'].nunique()} users")
print(f"experiment_data:    {len(exp)} rows, {exp['user_id'].nunique()} users")

ALPHA = 0.05
POWER = 0.80
Z_ALPHA = norm_ppf(1 - ALPHA/2)
Z_BETA  = norm_ppf(POWER)
Z_SUM   = Z_ALPHA + Z_BETA
print(f"\nz_alpha/2={Z_ALPHA:.4f}, z_beta={Z_BETA:.4f}, sum={Z_SUM:.4f}")


def user_horizon(T_days):
    """Агрегаты пользователя за первые T дней: rev, pv."""
    sub = uad[uad["day"] < T_days]
    return sub.groupby("user_id").agg(rev=("revenue","sum"), pv=("pages_viewed","sum"))


# ══════════════════════════════════════════════
# ТАБЛИЦА MDE ПО ДЛИТЕЛЬНОСТИ
# ══════════════════════════════════════════════
print("\n" + "="*70)
print("ТАБЛИЦА MDE ПО ДЛИТЕЛЬНОСТИ")
print("="*70)

mde_rows = []
for T in [14, 21, 28]:
    ua = user_horizon(T)
    n_total = len(ua)
    n_per_group = n_total // 2
    sigma = ua["rev"].std(ddof=1)
    mean = ua["rev"].mean()
    cov_xy = ua["rev"].cov(ua["pv"])
    var_y = ua["rev"].var(ddof=1)
    var_x = ua["pv"].var(ddof=1)
    r2 = (cov_xy**2) / (var_y * var_x)

    mde_raw   = Z_SUM * sigma * sqrt(2.0 / n_per_group)
    mde_cuped = Z_SUM * sigma * sqrt(1 - r2) * sqrt(2.0 / n_per_group)
    pct_lift  = mde_cuped / mean * 100

    mde_rows.append(dict(duration=f"{T//7} нед", n_total=n_total,
                         n_per_group=n_per_group, sigma=sigma, r2=r2,
                         mde_raw=mde_raw, mde_cuped=mde_cuped, pct=pct_lift))

print(f"\n{'Длит.':<7} {'N всего':>8} {'n/грп':>6} {'σ_rev':>8} {'R²':>6} "
      f"{'MDE raw':>9} {'MDE CUPED':>10} {'%lift':>7}")
print("-"*66)
for r in mde_rows:
    print(f"{r['duration']:<7} {r['n_total']:>8} {r['n_per_group']:>6} "
          f"{r['sigma']:>8.1f} {r['r2']:>6.3f} "
          f"{r['mde_raw']:>8.1f}$ {r['mde_cuped']:>9.1f}$ {r['pct']:>6.1f}%")


# ══════════════════════════════════════════════
# CUPED
# ══════════════════════════════════════════════
print("\n" + "="*70)
print("CUPED — ОШИБКА ПРИ ОЦЕНКЕ θ ВНУТРИ ГРУПП")
print("="*70)

pre = uad.groupby("user_id")["revenue"].mean().rename("x_pre")
exp_j = exp.merge(pre, on="user_id", how="left").dropna()
y = exp_j["revenue"].values
x = exp_j["x_pre"].values
n_sim = 2000

def cuped_aa(theta_mode, seed=42):
    """AA-симуляция CUPED: случайное разбиение на 2 группы + t-тест."""
    rng = np.random.default_rng(seed)
    rej = 0
    for _ in range(n_sim):
        perm = rng.permutation(len(y))
        h = len(perm) // 2
        ia, ib = perm[:h], perm[h:]
        ya, yb = y[ia], y[ib]
        xa, xb = x[ia], x[ib]
        if theta_mode == "global":
            th = np.cov(y, x, bias=True)[0,1] / np.var(x, ddof=0)
            gx = x.mean()
            ya_a = ya - th*(xa - gx)
            yb_a = yb - th*(xb - gx)
        else:  # per_group — ошибка
            th_a = np.cov(ya, xa, bias=True)[0,1] / np.var(xa, ddof=0)
            th_b = np.cov(yb, xb, bias=True)[0,1] / np.var(xb, ddof=0)
            ya_a = ya - th_a*(xa - xa.mean())
            yb_a = yb - th_b*(xb - xb.mean())
        _, p = welch_ttest(ya_a, yb_a)
        if p < ALPHA:
            rej += 1
    return rej / n_sim

fpr_global = cuped_aa("global")
fpr_pg     = cuped_aa("per_group")
print(f"  θ глобально (правильно):  FPR = {fpr_global:.4f}")
print(f"  θ внутри групп (ошибка):  FPR = {fpr_pg:.4f}")


# ══════════════════════════════════════════════
# СВАЛИДАЦИЯ ДИЗАЙНА
# ══════════════════════════════════════════════
print("\n" + "="*70)
print("ВАЛИДАЦИЯ ДИЗАЙНА")
print("="*70)

# ─AA-тест по Revenue
print("\n──AA-тест")
user_rev = uad.groupby("user_id")["revenue"].sum().values
n_aa = 2000
rng = np.random.default_rng(123)
rej = 0
for _ in range(n_aa):
    perm = rng.permutation(len(user_rev))
    h = len(perm) // 2
    _, p = welch_ttest(user_rev[perm[:h]], user_rev[perm[h:]])
    if p < ALPHA:
        rej += 1
fpr_aa = rej / n_aa
print(f"  FPR по Revenue = {fpr_aa:.4f} — {n_aa} разбиений")

# ── Симуляция AB
print("\n──Симуляция AB")
r4 = mde_rows[-1]
mde_4w = r4["mde_cuped"]
n_pg = r4["n_per_group"]
std_cuped = r4["sigma"] * sqrt(1 - r4["r2"])
base_mean = user_horizon(28)["rev"].mean()

n_ab = 2000
rng = np.random.default_rng(456)
rej = 0
for _ in range(n_ab):
    ctrl  = rng.normal(loc=base_mean,        scale=std_cuped, size=n_pg)
    treat = rng.normal(loc=base_mean+mde_4w, scale=std_cuped, size=n_pg)
    _, p = welch_ttest(ctrl, treat)
    if p < ALPHA:
        rej += 1
power_emp = rej / n_ab
print(f"  MDE (4 нед, CUPED) = {mde_4w:.1f}$, n/группа = {n_pg}, σ_CUPED = {std_cuped:.1f}")
print(f"  Empirical power = {power_emp:.4f}")

# ── SRM (Sample Ratio Mismatch)
print("\n──SRM")
n_ctrl = int((exp["group"] == "control").sum())
n_test = int((exp["group"] == "test").sum())
n_tot  = n_ctrl + n_test
exp_n  = n_tot / 2.0
chi2   = (n_ctrl-exp_n)**2/exp_n + (n_test-exp_n)**2/exp_n
z_srm  = (n_ctrl - exp_n) / sqrt(n_tot * 0.25)   # биномиальная апроксимация
p_two  = 2 * (1 - norm_cdf(abs(z_srm)))           # двусторонний
p_one  = norm_cdf(-abs(z_srm))                    # односторонняя хвостовая вероятность

print(f"  control={n_ctrl}, test={n_test}, expected={exp_n}")
print(f"  χ² = {chi2:.4f} (df=1)")
print(f"  p (two-sided)  = {p_two:.4f}")
print(f"  p (one-sided)  = {p_one:.4f}")



# ══════════════════════════════════════════════
# СВОДКА
# ══════════════════════════════════════════════
print("\n" + "="*70)
print("СВОДКА")
print("="*70)
print(f"""
┌─────────────────────────────────────────────────────────────┐
│Метрика                         │ Расчётное значение         │
├─────────────────────────────────────────────────────────────┤
│MDE 2 нед (raw / CUPED)         │ {mde_rows[0]['mde_raw']:.1f}$ / {mde_rows[0]['mde_cuped']:.1f}$ ({mde_rows[0]['pct']:.1f}%)       │
│MDE 3 нед (raw / CUPED)         │ {mde_rows[1]['mde_raw']:.1f}$ / {mde_rows[1]['mde_cuped']:.1f}$ ({mde_rows[1]['pct']:.1f}%)       │
│MDE 4 нед (raw / CUPED)         │ {mde_rows[2]['mde_raw']:.1f}$ / {mde_rows[2]['mde_cuped']:.1f}$ ({mde_rows[2]['pct']:.1f}%)       │
│FPR CUPED, θ global             │ {fpr_global:.3f}                      │
│FPR CUPED, θ per-group (ошибка) │ {fpr_pg:.3f}                      │
│AA FPR (Revenue, 2000 разбиений)│ {fpr_aa:.3f}                      │
│Power AB (effect = MDE)         │ {power_emp:.3f}                      │
│SRM p-value (one-sided)         │ {p_one:.3f}                      │
└─────────────────────────────────────────────────────────────┘
""")
print("Done.")
