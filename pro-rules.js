/**
 * pro-rules.js — aturan LP "level pro" (murni, tanpa I/O, mudah dites).
 *
 * Dipakai oleh:
 *  - index.js getDeterministicCloseRule()  → evaluateProExits()
 *  - index.js runScreeningCycle()          → screeningGuards()
 *  - tools/dlmm.js deployPosition()        → pickStrategyByVolatility()
 *
 * Semua ambang diambil dari config (user-config.json). Nilai null/0 = fitur mati.
 */

const num = (v) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

/** Normalisasi stopLossPct: harus NEGATIF. Angka positif (salah input) dibalik. */
export function normalizeStopLoss(value, fallback = -15) {
  const n = num(value);
  if (n == null) return fallback;
  if (n > 0) return -n;
  return n;
}

/**
 * Fee velocity: bandingkan laju fee 2 jendela terakhir (masing-masing windowMin menit)
 * dengan rata-rata laju fee sepanjang snapshot yang tersedia.
 * Snapshot = [{ts, unclaimed_fees_usd, position}] dari pool-memory (per siklus manajemen).
 * Penurunan unclaimed fee (klaim) diabaikan, hanya delta positif yang dihitung.
 */
export function feeVelocityDecay(snapshots, positionId, { windowMin = 30, dropPct = 40, minSpanMin = 60 } = {}) {
  const pts = (snapshots || [])
    .filter((s) => (!positionId || s.position === positionId) && num(s.unclaimed_fees_usd) != null && s.ts)
    .map((s) => ({ t: new Date(s.ts).getTime(), f: Number(s.unclaimed_fees_usd) }))
    .filter((p) => Number.isFinite(p.t))
    .sort((a, b) => a.t - b.t);
  if (pts.length < 4) return null;

  const spanMin = (pts[pts.length - 1].t - pts[0].t) / 60000;
  if (spanMin < Math.max(minSpanMin, windowMin * 2)) return null;

  const now = pts[pts.length - 1].t;
  const w = windowMin * 60000;
  let total = 0, recent = 0, prev = 0;
  for (let i = 1; i < pts.length; i++) {
    const d = pts[i].f - pts[i - 1].f;
    if (d <= 0) continue; // klaim / tidak ada fee baru
    total += d;
    const age = now - pts[i].t;
    if (age <= w) recent += d;
    else if (age <= 2 * w) prev += d;
  }
  if (total <= 0) return null; // tidak pernah ada fee → urusan rule low-yield
  const avgRate = total / spanMin;               // $/menit
  const recentRate = recent / windowMin;
  const prevRate = prev / windowMin;
  const limit = avgRate * (dropPct / 100);
  if (recentRate < limit && prevRate < limit) {
    return {
      avgRate, recentRate, prevRate,
      reason: `fee velocity decay: ${(recentRate * 60).toFixed(4)}$/jam & ${(prevRate * 60).toFixed(4)}$/jam < ${dropPct}% rata-rata ${(avgRate * 60).toFixed(4)}$/jam`,
    };
  }
  return null;
}

/**
 * Exit tambahan di luar rule 1–5 bawaan. Return {action:"CLOSE", rule, reason} atau null.
 * rule 6 = OOR sisi bawah (bag penuh), 7 = time stop, 8 = fee velocity decay.
 */
export function evaluateProExits(position, mgmt, snapshots = []) {
  if (!position) return null;
  const pnlOk = !position.pnl_pct_suspicious && position.pnl_pct != null;

  // 6 — keluar range ke BAWAH: posisi sudah jadi 100% token yang sedang turun.
  const belowWait = num(mgmt.oorBelowWaitMinutes);
  if (
    belowWait != null &&
    position.active_bin != null && position.lower_bin != null &&
    position.active_bin < position.lower_bin &&
    (position.minutes_out_of_range ?? 0) >= belowWait
  ) {
    return { action: "CLOSE", rule: 6, reason: `OOR bawah (${position.minutes_out_of_range ?? 0}m >= ${belowWait}m)` };
  }

  // 7 — time stop: modal nyangkut terlalu lama tanpa hasil (maxPositions kecil → perputaran modal penting).
  const tsMin = num(mgmt.timeStopMinutes);
  const tsPnl = num(mgmt.timeStopMinPnlPct);
  if (tsMin && tsPnl != null && pnlOk && (position.age_minutes ?? 0) >= tsMin && position.pnl_pct < tsPnl) {
    return { action: "CLOSE", rule: 7, reason: `time stop (${position.age_minutes}m, PnL ${position.pnl_pct.toFixed(2)}% < ${tsPnl}%)` };
  }

  // 8 — fee velocity decay (volume mati lebih cepat terdeteksi daripada fee/TVL 24h).
  if (mgmt.feeVelocityEnabled && (position.age_minutes ?? 0) >= (num(mgmt.feeVelocityMinAgeMin) ?? 90)) {
    const fv = feeVelocityDecay(snapshots, position.position, {
      windowMin: num(mgmt.feeVelocityWindowMin) ?? 30,
      dropPct: num(mgmt.feeVelocityDropPct) ?? 40,
    });
    if (fv) return { action: "CLOSE", rule: 8, reason: fv.reason };
  }
  return null;
}

/**
 * Guard screening setelah recon token. Return alasan (string) kalau kandidat harus dibuang, else null.
 * pool = kandidat ringkas dari getTopCandidates, ti = hasil getTokenInfo.
 */
export function screeningGuards(pool, ti, s = {}) {
  // Mint / freeze authority harus sudah dicabut (kalau datanya ada).
  if (s.requireRenouncedAuthority !== false && ti?.audit) {
    if (ti.audit.mint_disabled === false) return "mint authority masih aktif";
    if (ti.audit.freeze_disabled === false) return "freeze authority masih aktif";
  }

  // Jangan kejar pump vertikal: LP SOL di bawah harga baru terisi saat harga turun dari pucuk.
  const chg = num(pool?.price_change_pct ?? pool?.pool_price_change_pct);
  const maxChg = num(s.maxPriceChangePct);
  if (chg != null && maxChg != null && chg > maxChg) {
    return `pump vertikal: harga +${chg}% dalam window screening (> ${maxChg}%)`;
  }
  const chg1h = num(ti?.stats_1h?.price_change);
  const max1h = num(s.maxPriceChange1hPct);
  if (chg1h != null && max1h != null && chg1h > max1h) {
    return `pump 1h terlalu besar: +${chg1h}% (> ${max1h}%)`;
  }
  return null;
}

/** Pilih bentuk likuiditas: volatilitas tinggi → highVolStrategy (mis. bid_ask), selain itu default. */
export function pickStrategyByVolatility(volatility, strategyCfg = {}) {
  const v = num(volatility);
  const thr = num(strategyCfg.highVolThreshold);
  if (strategyCfg.highVolStrategy && v != null && thr != null && v >= thr) return strategyCfg.highVolStrategy;
  return strategyCfg.strategy;
}
