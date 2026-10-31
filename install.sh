#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  Kantor LP — installer satu perintah (VPS Ubuntu/Debian, via Termius)
#
#    bash install.sh              install lengkap + isi semua kunci + jalan 24 jam
#    bash install.sh --config     ubah kunci/setelan saja (Enter = pakai nilai lama)
#    bash install.sh --no-start   hanya tulis konfigurasi, jangan start PM2
# ─────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

APP_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$APP_DIR"

# Nama instance = nama folder. Folder berbeda (kantor, kantor2) => PM2, perintah & port terpisah.
INSTANCE="$(basename "$APP_DIR")"
AGENT_APP="$INSTANCE-agent"
TUN_APP="$INSTANCE-tunnel"

EOF_HIT=0
CONFIG_ONLY=0
NO_START=0
for arg in "$@"; do
  case "$arg" in
    --config)   CONFIG_ONLY=1 ;;
    --no-start) NO_START=1 ;;
    -h|--help)  sed -n '2,9p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) echo "Opsi tidak dikenal: $arg (pakai --help)"; exit 1 ;;
  esac
done

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B=; G=; Y=; R=; C=; N=; fi
step() { printf '\n%s== %s ==%s\n' "$B$C" "$*" "$N"; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
trap 'die "Gagal di baris $LINENO. Perbaiki lalu jalankan lagi: bash install.sh"' ERR

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# ─── Helper .env ─────────────────────────────────────────────────────
env_get() {
  [ -f .env ] || return 0
  { grep -E "^$1=" .env || true; } | tail -n1 | cut -d= -f2- | sed -E "s/^['\"]//; s/['\"]$//"
}
env_set() {
  local key="$1" value="$2"
  touch .env
  { grep -v -E "^${key}=" .env || true; } > .env.tmp
  printf '%s=%s\n' "$key" "$value" >> .env.tmp
  mv .env.tmp .env
  chmod 600 .env
}

# ─── Helper multi-instance ───────────────────────────────────────────
# Folder lain di sebelah folder ini yang juga berisi instance (punya .env + ecosystem.config.cjs)
sibling_envs() {
  local d
  for d in "$(dirname "$APP_DIR")"/*/; do
    d="${d%/}"
    [ "$d" = "$APP_DIR" ] && continue
    [ -f "$d/.env" ] && [ -f "$d/ecosystem.config.cjs" ] && echo "$d/.env"
  done
  return 0
}
port_taken() {
  local p="$1" f
  if command -v ss >/dev/null && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"; then return 0; fi
  for f in $(sibling_envs); do
    grep -qE "^MINIAPP_PORT=${p}\s*$" "$f" && return 0
  done
  return 1
}
pick_port() {
  local p="${1:-8787}"
  while port_taken "$p"; do p=$((p + 1)); done
  echo "$p"
}

# ─── Helper input ────────────────────────────────────────────────────
mask() { local s="$1"; if [ "${#s}" -le 10 ]; then echo "****"; else echo "${s:0:4}…${s: -4}"; fi; }
trim() { printf '%s' "$1" | tr -d '[:space:]'; }

# prompt_plain "Label" "default"  -> $REPLY
prompt_plain() {
  local hint=""
  [ -n "${2:-}" ] && hint=" [$2]"
  read -r -p "$1$hint: " REPLY || EOF_HIT=1
  REPLY="$(trim "${REPLY:-${2:-}}")"
}
# prompt_secret "Label" "nilai_lama" -> $REPLY (input disembunyikan, Enter = nilai lama)
prompt_secret() {
  local hint=""
  [ -n "${2:-}" ] && hint=" [tersimpan $(mask "$2"), Enter = pakai ini]"
  read -r -s -p "$1$hint: " REPLY || EOF_HIT=1
  echo
  REPLY="$(trim "${REPLY:-${2:-}}")"
}

# ask_required secret|plain "Label" "nilai_lama" validator_fn
ask_required() {
  local kind="$1" label="$2" cur="$3" validator="${4:-}"
  while :; do
    if [ "$kind" = secret ]; then prompt_secret "$label" "$cur"; else prompt_plain "$label" "$cur"; fi
    if [ -z "$REPLY" ]; then
      [ "${EOF_HIT:-0}" = 1 ] && die "Input terputus sebelum semua kolom wajib terisi."
      warn "Wajib diisi."; continue
    fi
    if [ "${EOF_HIT:-0}" = 1 ] && [ -n "$validator" ] && ! "$validator" "$REPLY"; then die "Input terputus dan nilai tidak valid."; fi
    if [ -n "$validator" ] && ! "$validator" "$REPLY"; then continue; fi
    break
  done
}

# ─── Validator ───────────────────────────────────────────────────────
v_openrouter() {
  [ "${#1}" -ge 20 ] || { warn "API key terlalu pendek."; return 1; }
  case "$1" in sk-or-*) ;; *) warn "Biasanya diawali 'sk-or-' (tetap dipakai).";; esac
}
v_helius() { [[ "$1" =~ ^[A-Za-z0-9-]{16,}$ ]] || { warn "Format Helius API key tidak valid."; return 1; }; }
v_rpc()    { [[ "$1" =~ ^https?://[^[:space:]]+$ ]] || { warn "RPC harus berupa URL (https://...)."; return 1; }; }
v_wallet() {
  [[ "$1" =~ ^[1-9A-HJ-NP-Za-km-z]{64,100}$ ]] || { warn "Bukan private key base58 (biasanya 87-88 karakter)."; return 1; }
  if [ -d node_modules/@solana/web3.js ]; then
    local pub
    if pub="$(KC_KEY="$1" node -e '
      const {Keypair}=require("@solana/web3.js");const bs58=require("bs58");
      const kp=Keypair.fromSecretKey(bs58.decode(process.env.KC_KEY));console.log(kp.publicKey.toBase58());' 2>/dev/null)"; then
      ok "Wallet terbaca: $pub"
    else
      warn "Private key tidak bisa didecode. Cek lagi."; return 1
    fi
  fi
}
v_token() {
  [[ "$1" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}$ ]] || { warn "Format bot token salah (contoh 123456789:AAH...)."; return 1; }
  local f
  for f in $(sibling_envs); do
    if grep -qF "TELEGRAM_BOT_TOKEN=$1" "$f"; then
      warn "Token ini sama dengan instance lain ($(dirname "$f")). Dua agent tidak boleh memakai bot yang sama, buat bot baru di @BotFather."
      return 1
    fi
  done
  local code
  code="$(curl -sS -m 10 -o /tmp/kc_getme.json -w '%{http_code}' "https://api.telegram.org/bot$1/getMe" 2>/dev/null)" || code=000
  if [ "$code" = 200 ]; then
    ok "Bot valid: @$(grep -o '"username":"[^"]*"' /tmp/kc_getme.json | head -1 | cut -d'"' -f4)"
  elif [ "$code" = 401 ] || [ "$code" = 404 ]; then
    warn "Telegram menolak token ini. Salin ulang dari @BotFather."; rm -f /tmp/kc_getme.json; return 1
  else
    warn "Tidak bisa memverifikasi token (HTTP $code), lanjut."
  fi
  rm -f /tmp/kc_getme.json
}
v_uid()  { [[ "$1" =~ ^[0-9]+$ ]] || { warn "ID user harus angka (dari @userinfobot)."; return 1; }; }
v_uids() { [[ "$1" =~ ^[0-9]+(,[0-9]+)*$ ]] || { warn "Isi angka saja, pisahkan koma (contoh 12345,67890)."; return 1; }; }

# ═════════════════════════════════════════════════════════════════════
#  1. Install dependensi sistem
# ═════════════════════════════════════════════════════════════════════
install_system() {
  command -v apt-get >/dev/null || die "Installer ini hanya untuk Ubuntu/Debian (apt-get tidak ditemukan)."
  export DEBIAN_FRONTEND=noninteractive

  step "Paket sistem"
  $SUDO apt-get update -y
  $SUDO apt-get install -y curl unzip ca-certificates git build-essential python3 python3-venv python3-pip
  ok "Paket dasar siap"

  step "Node.js"
  local major=0
  command -v node >/dev/null && major="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "$major" -lt 20 ]; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO -E bash -
    $SUDO apt-get install -y nodejs
  fi
  ok "Node $(node -v)"

  step "PM2"
  command -v pm2 >/dev/null || $SUDO npm install -g pm2
  ok "PM2 $(pm2 -v)"

  step "cloudflared (tunnel gratis)"
  if ! command -v cloudflared >/dev/null; then
    local arch
    case "$(uname -m)" in
      x86_64|amd64)  arch=amd64 ;;
      aarch64|arm64) arch=arm64 ;;
      armv7l|armv6l) arch=arm ;;
      *) die "Arsitektur $(uname -m) tidak didukung cloudflared." ;;
    esac
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch" -o /tmp/cloudflared
    $SUDO install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared
    rm -f /tmp/cloudflared
  fi
  ok "$(cloudflared --version 2>&1 | head -1)"

  step "Dependensi project (npm install)"
  npm install --no-audit --no-fund
  ok "npm install selesai"

  step "Python untuk laporan PnL"
  if python3 -m venv .venv >/dev/null 2>&1 && .venv/bin/pip install -q -r pnl-report/requirements.txt; then
    ok "Python venv siap (.venv)"
  else
    warn "Python venv gagal, laporan gambar PnL mungkin tidak jalan (agent tetap jalan)."
  fi
}

# ═════════════════════════════════════════════════════════════════════
#  2. Isi konfigurasi
# ═════════════════════════════════════════════════════════════════════
configure() {
  step "Konfigurasi (Enter = pakai nilai tersimpan)"

  # .env hasil envcrypt (ada "# encrypted") tidak aman ditimpa otomatis: cadangkan, mulai bersih.
  if [ -f .env ] && grep -qi '^# *encrypted' .env; then
    cp .env ".env.bak-$(date +%s)"
    : > .env
    warn ".env lama terenkripsi (envcrypt), dicadangkan ke .env.bak-*. Isi ulang kunci di bawah."
  fi

  echo "Siapkan: key OpenRouter, key Helius, bot token (@BotFather), ID Telegram (@userinfobot), private key wallet."
  echo

  ask_required secret "1/7 OpenRouter API key (sk-or-...)" "$(env_get LLM_API_KEY)" v_openrouter
  local llm_key="$REPLY"

  ask_required secret "2/7 Helius API key" "$(env_get HELIUS_API_KEY)" v_helius
  local helius="$REPLY"

  local cur_rpc rpc_default
  cur_rpc="$(env_get RPC_URL)"
  rpc_default="${cur_rpc:-https://mainnet.helius-rpc.com/?api-key=$helius}"
  ask_required plain "3/7 RPC URL" "$rpc_default" v_rpc
  local rpc="$REPLY"

  ask_required secret "4/7 Telegram bot token" "$(env_get TELEGRAM_BOT_TOKEN)" v_token
  local bot_token="$REPLY"

  ask_required plain "5/7 ID Telegram kamu (angka)" "$(env_get TELEGRAM_CHAT_ID)" v_uid
  local chat_id="$REPLY"

  local cur_allowed
  cur_allowed="$(env_get TELEGRAM_ALLOWED_USER_IDS)"
  ask_required plain "6/7 Allowed user ID (boleh banyak, pisah koma)" "${cur_allowed:-$chat_id}" v_uids
  local allowed="$REPLY"

  ask_required secret "7/7 Private key wallet Solana (base58)" "$(env_get WALLET_PRIVATE_KEY)" v_wallet
  local wallet="$REPLY"

  local cur_dry dry="true"
  cur_dry="$(env_get DRY_RUN)"
  echo
  echo "Mode trading sekarang: $([ "$cur_dry" = false ] && echo LIVE || echo 'DRY RUN (simulasi)')"
  read -r -p "Ketik LIVE untuk uang sungguhan, ketik DRY untuk simulasi, Enter = tidak diubah: " REPLY || true
  case "$(trim "${REPLY:-}" | tr '[:lower:]' '[:upper:]')" in
    LIVE) dry="false" ;;
    DRY)  dry="true" ;;
    *)    [ "$cur_dry" = false ] && dry="false" || dry="true" ;;
  esac

  env_set LLM_API_KEY "$llm_key"
  env_set LLM_BASE_URL "$(env_get LLM_BASE_URL | grep . || echo https://openrouter.ai/api/v1)"
  env_set HELIUS_API_KEY "$helius"
  env_set RPC_URL "$rpc"
  env_set TELEGRAM_BOT_TOKEN "$bot_token"
  env_set TELEGRAM_CHAT_ID "$chat_id"
  env_set TELEGRAM_ALLOWED_USER_IDS "$allowed"
  env_set WALLET_PRIVATE_KEY "$wallet"
  env_set DRY_RUN "$dry"
  local port
  port="$(env_get MINIAPP_PORT)"
  [ -n "$port" ] || port="$(pick_port 8787)"
  env_set MINIAPP_PORT "$port"
  ok "Instance '$INSTANCE' memakai port $port"
  env_set MINIAPP_HOST "$(env_get MINIAPP_HOST | grep . || echo 127.0.0.1)"
  [ -x .venv/bin/python ] && env_set PNL_PYTHON "$APP_DIR/.venv/bin/python"
  # MINIAPP_URL diisi otomatis oleh scripts/tunnel.js setiap start/restart.
  ok ".env tertulis (chmod 600)"

  # user-config.json menang atas .env untuk dryRun / chatId, jadi samakan.
  [ -f user-config.json ] || cp user-config.example.json user-config.json
  KC_DRY="$dry" KC_RPC="$rpc" KC_CHAT="$chat_id" node -e '
    const fs=require("fs"),p="user-config.json";let c={};
    try{c=JSON.parse(fs.readFileSync(p,"utf8"))}catch{}
    c.dryRun=process.env.KC_DRY==="true";
    c.rpcUrl=process.env.KC_RPC;
    c.telegramChatId=process.env.KC_CHAT;
    fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n");'
  ok "user-config.json disinkronkan (dryRun=$dry)"
}

# ═════════════════════════════════════════════════════════════════════
#  3. Jalankan (PM2 + tunnel otomatis + autostart saat reboot)
# ═════════════════════════════════════════════════════════════════════
start_services() {
  step "Menjalankan 24 jam (PM2 + tunnel gratis)"
  rm -f .tunnel-url
  pm2 startOrRestart ecosystem.config.cjs --only "$TUN_APP" --update-env >/dev/null
  ok "Tunnel dijalankan, agent akan start otomatis setelah alamat tunnel didapat"

  if [ "$CONFIG_ONLY" -eq 0 ]; then
    if [ "$(id -u)" -eq 0 ]; then
      pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || warn "pm2 startup gagal, jalankan manual: pm2 startup"
    else
      local cmd
      cmd="$(pm2 startup systemd -u "$USER" --hp "$HOME" 2>/dev/null | grep -E '^sudo ' | tail -n1 || true)"
      if [ -n "$cmd" ]; then eval "$cmd" >/dev/null 2>&1 || warn "pm2 startup gagal, jalankan manual: pm2 startup"; fi
    fi
  fi
  pm2 save >/dev/null
  ok "Auto-start saat VPS reboot aktif"

  if [ -e "/usr/local/bin/$INSTANCE" ] && [ "$(readlink -f "/usr/local/bin/$INSTANCE")" != "$APP_DIR/scripts/kantor.sh" ]; then
    warn "/usr/local/bin/$INSTANCE sudah dipakai program lain, perintah pendek tidak dipasang. Pakai: bash $APP_DIR/scripts/kantor.sh"
  else
    $SUDO ln -sf "$APP_DIR/scripts/kantor.sh" "/usr/local/bin/$INSTANCE"
  fi
  chmod +x "$APP_DIR/scripts/kantor.sh" "$APP_DIR/install.sh"

  step "Menunggu alamat tunnel"
  local url="" i
  for i in $(seq 1 45); do
    [ -s .tunnel-url ] && { url="$(head -1 .tunnel-url)"; break; }
    sleep 2
  done
  [ -n "$url" ] || { warn "Alamat belum muncul. Cek: $INSTANCE logs tunnel"; return 0; }
  ok "Alamat Mini App: $url"

  printf 'Memeriksa agent'
  for i in $(seq 1 30); do
    if curl -fsS -m 8 "$url/healthz" 2>/dev/null | grep -q ok; then echo; ok "Mini App online"; break; fi
    printf '.'; sleep 3
  done
  echo
}

summary() {
  local url=""; [ -s .tunnel-url ] && url="$(head -1 .tunnel-url)"
  cat <<EOF

${B}${G}Selesai.${N}
  Instance        : $INSTANCE (PM2: $AGENT_APP, $TUN_APP, port $(env_get MINIAPP_PORT))
  Alamat Mini App : ${url:-belum tersedia ($INSTANCE url)}
  Buka Telegram   : chat bot kamu -> kirim /start -> tombol "Kantor LP"
  Mode            : $([ "$(env_get DRY_RUN)" = false ] && echo "${R}LIVE${N}" || echo "DRY RUN (simulasi)")

Perintah berguna (instance "$INSTANCE"):
  $INSTANCE status         status + alamat saat ini
  $INSTANCE logs           log agent   ($INSTANCE logs tunnel = log tunnel)
  $INSTANCE restart        restart semua, alamat tunnel BARU dipasang otomatis
  $INSTANCE restart-agent  restart agent saja (alamat tetap)
  $INSTANCE config         ubah API key / token / wallet / mode
EOF
}

# ─── Main ────────────────────────────────────────────────────────────
if [ "$CONFIG_ONLY" -eq 0 ]; then install_system; fi
[ -d node_modules ] || { step "Dependensi project"; npm install --no-audit --no-fund; }
configure
if [ "$NO_START" -eq 0 ]; then start_services; summary; else ok "Konfigurasi selesai (tanpa start)."; fi
