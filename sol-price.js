// Harga SOL/USD (dipakai untuk mengonversi PnL USD → SOL di laporan harian).
// Urutan: Jupiter Price API → CoinGecko → harga terakhir yang berhasil diambil (cache).
import { config } from "./config.js";
import { log } from "./logger.js";

const SOL_MINT = "So11111111111111111111111111111111111111112";
const TTL_MS = 60_000;
let _cache = { price: null, at: 0 };

async function fetchJson(url, headers = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 8000);
  try {
    const res = await fetch(url, { headers, signal: ctrl.signal });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}

/** @returns {Promise<number|null>} harga 1 SOL dalam USD, atau null kalau semua sumber gagal */
export async function getSolPriceUsd() {
  if (_cache.price && Date.now() - _cache.at < TTL_MS) return _cache.price;

  const key = config.jupiter?.apiKey || process.env.JUPITER_API_KEY || "";
  const attempts = [
    async () => {
      const url = key
        ? `https://api.jup.ag/price/v3?ids=${SOL_MINT}`
        : `https://lite-api.jup.ag/price/v3?ids=${SOL_MINT}`;
      const j = await fetchJson(url, key ? { "x-api-key": key } : {});
      return Number(j?.[SOL_MINT]?.usdPrice);
    },
    async () => {
      const j = await fetchJson("https://api.coingecko.com/api/v3/simple/price?ids=solana&vs_currencies=usd");
      return Number(j?.solana?.usd);
    },
  ];

  for (const attempt of attempts) {
    try {
      const p = await attempt();
      if (Number.isFinite(p) && p > 1) {
        _cache = { price: p, at: Date.now() };
        return p;
      }
    } catch (e) {
      log("sol_price_warn", `Gagal ambil harga SOL: ${e.message}`);
    }
  }
  return _cache.price; // bisa null; pemanggil harus siap
}

// ─── Perubahan harga SOL 1 jam (guard makro untuk LP single-sided SOL) ───────────
let _chgCache = { pct: null, at: 0 };
const CHG_TTL_MS = 5 * 60_000;

/** @returns {Promise<number|null>} % perubahan SOL/USD dalam 1 jam terakhir; null kalau data tidak ada (fail-open). */
export async function getSolChange1hPct() {
  if (_chgCache.at && Date.now() - _chgCache.at < CHG_TTL_MS) return _chgCache.pct;
  try {
    const j = await fetchJson(
      "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=solana&price_change_percentage=1h",
    );
    const pct = Number(j?.[0]?.price_change_percentage_1h_in_currency);
    if (Number.isFinite(pct)) {
      _chgCache = { pct, at: Date.now() };
      return pct;
    }
  } catch (e) {
    log("sol_price_warn", `Gagal ambil perubahan 1h SOL: ${e.message}`);
  }
  _chgCache = { pct: null, at: Date.now() };
  return null;
}
