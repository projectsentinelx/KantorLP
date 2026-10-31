# Strategi LP Pro — catatan perubahan

> Heuristik, bukan hasil backtest, dan bukan saran finansial. Jalankan `dryRun: true` 1–2 minggu, lalu tinjau `lessons.json` / `decision-log.json` sebelum pakai dana nyata.

## Bug yang diperbaiki
`stopLossPct` positif (25) membuat `pnl_pct <= 25` benar hampir selalu → posisi langsung ditutup.
Sekarang SL **selalu dinormalisasi negatif** di `config.js` dan `update_config` (angka positif otomatis dibalik).

## Kapan OPEN (screening)
| Filter | Nilai | Lokasi |
|---|---|---|
| Entry indikator | `rsi_plus_supertrend` (pullback di tren naik), 5m + 15m, keduanya wajib | `chartIndicators` |
| Anti-pump vertikal | harga > +25% di window screening atau > +60% 1 jam → skip | `pro-rules.js` `screeningGuards` |
| Mint/freeze authority | harus sudah dicabut (jika datanya ada) | `screeningGuards` |
| Guard makro | SOL turun ≥ 3% dalam 1 jam → skip screening | `sol-price.js` `getSolChange1hPct` |
| Kualitas holder | top10 ≤ 40%, bot ≤ 20%, organic ≥ 60 | `user-config.json` |
| Umur token | ≥ 3 jam (hindari fase sniper) | `minTokenAgeHours` |

## Range & bentuk
- Bin step 60–90, 35–50 bins di bawah harga (≈ -19% s/d -36%). SL -15% memotong sebelum range habis.
- Volatilitas < 3 → `spot`; ≥ 3 → `bid_ask` (`highVolStrategy` / `highVolThreshold`).

## Kapan CLOSE
| # | Aturan | Default |
|---|---|---|
| 1 | Stop loss | -15% |
| 2 | Take profit keras | +12% (trailing aktif di +4%, tutup saat turun 2% dari puncak) |
| 3/4 | OOR atas | 6 bins di atas range, atau 8 menit |
| **6** | **OOR bawah** (bag penuh) | 2 menit |
| **7** | **Time stop** | umur ≥ 420 menit & PnL < +2% |
| **8** | **Fee velocity decay** | 2 jendela 30 menit berturut-turut < 40% dari rata-rata laju fee (umur ≥ 90 menit) |
| 5 | Low yield 24h | tetap ada |

Semua ambang bisa diubah lewat `user-config.json` atau `update_config`. Set `timeStopMinutes: 0`, `feeVelocityEnabled: false`, `oorBelowWaitMinutes: null`, `solDropGuardPct: 0`, atau `highVolStrategy: null` untuk mematikan fitur terkait.

## Belum diimplementasikan (data tidak tersedia di kode)
- Porsi dev & apakah dev sudah jual, konsentrasi whale LP di pool, tren akselerasi volume per window.
- Filter jam sesi (volume biasanya paling tebal sesi US, ±20:00–03:00 WIB) — belum divalidasi, jadi tidak di-hard-code.

## Tes
`node test/test-pro-rules.js` — mencakup normalisasi SL, OOR bawah, time stop, fee velocity (termasuk kasus klaim), guard screening, dan pemilihan bentuk.
