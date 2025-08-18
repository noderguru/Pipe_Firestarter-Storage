set -u -o pipefail

# ===== Colors/Log =====
NC="\033[0m"; RED="\033[1;31m"; YEL="\033[1;33m"; GRN="\033[1;32m"; CYA="\033[1;36m"; MAG="\033[1;35m"; BLU="\033[1;34m"
info(){ echo -e "${CYA}[INFO]${NC} $*"; }
warn(){ echo -e "${YEL}[WARN]${NC} $*"; }
err (){ echo -e "${RED}[ERROR]${NC} $*"; }
ok  (){ echo -e "${GRN}[OK]${NC} $*"; }
note(){ echo -e "${MAG}[NOTE]${NC} $*"; }

# ===== Tunables =====
RETRY_PAUSE=8; MAX_RETRIES=3
SOL_WAIT_SECS=10; MAX_SOL_CHECKS=18
AVAIL_WAIT_SECS=10; MAX_AVAIL_CHECKS=30
POST_AVAIL_SLEEP=12   # grace pause after object becomes "available"

WORKDIR="/root/pipe/test-downloads"
PASS_DIR="/root/pipe"
PASS_LOG="${PASS_DIR}/passwords.log"
CONFIG_FILE="$HOME/.pipe-cli.json"
STATE_DIR="$HOME/.pipe-script"
STATE_USERNAME_FILE="$STATE_DIR/username.txt"

umask 077
mkdir -p "$STATE_DIR" "$WORKDIR" "$PASS_DIR"
touch "$PASS_LOG"

# ===== Helpers =====
retry_run(){ local d="$1"; shift; local a=1; while :; do info "$d (attempt $a/$MAX_RETRIES)"; if eval "$@"; then ok "$d succeeded."; return 0; fi; ((a>=MAX_RETRIES))&&{ err "$d failed after $MAX_RETRIES attempts."; return 1; }; warn "$d failed. Retrying after ${RETRY_PAUSE}s…"; sleep "$RETRY_PAUSE"; a=$((a+1)); done; }
retry_capture(){ local d="$1" v="$2"; shift 2; local a=1 out rc; while :; do info "$d (attempt $a/$MAX_RETRIES)"; out="$(eval "$@" 2>&1)"; rc=$?; if [[ $rc -eq 0 ]]; then ok "$d succeeded."; printf -v "$v" "%s" "$out"; return 0; fi; ((a>=MAX_RETRIES))&&{ err "$d failed after $MAX_RETRIES attempts."; printf -v "$v" ""; return 1; }; warn "$d failed. Retrying after ${RETRY_PAUSE}s…"; sleep "$RETRY_PAUSE"; a=$((a+1)); done; }
gen_username(){ tr -dc 'a-z' </dev/urandom | head -c 8; }
gen_password(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8; }   # <= 8 chars
rand_suffix(){ tr -dc 'a-z0-9' </dev/urandom | head -c 6; }
rand_int_range(){ awk -v min="$1" -v max="$2" 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'; }
rand_sol_amount(){ n=$(rand_int_range 70 90); awk -v n="$n" 'BEGIN{printf("%.2f", n/100)}'; }

parse_sol_balance(){ awk '/^[[:space:]]*SOL:/{print $2; exit} /^[[:space:]]*Lamports:/{printf "%.9f\n",$2/1e9; exit}' | head -n1; }
parse_pubkey(){ awk '{l=tolower($0)} l~/^[[:space:]]*pubkey:/{print $2; exit}'; }
parse_next_line_after(){ awk -v pat="$1" 'BEGIN{f=0} index($0, pat){f=1; next} f && $0 !~ /^[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit}' | head -n1; }
parse_social_link(){ parse_next_line_after "Social media link"; }
parse_direct_link(){ parse_next_line_after "Direct link"; }

get_user_id_from_config(){ [[ -f "$CONFIG_FILE" ]] || return 1; sed -n 's/.*"user_id"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p' "$CONFIG_FILE" | head -n1; }
recover_username(){
  [[ -s "$STATE_USERNAME_FILE" ]] && { cat "$STATE_USERNAME_FILE"; return; }
  local out code uid prefix
  out="$(pipe referral show 2>/dev/null || true)"
  code="$(printf "%s" "$out" | sed -n 's/.*\b\([a-z]\{3,\}\)-[A-Za-z0-9]\{4,\}\b.*/\1/p' | head -n1)"
  [[ -n "$code" ]] && { echo "$code" | tee "$STATE_USERNAME_FILE"; return; }
  uid="$(get_user_id_from_config || true)"
  if [[ -n "$uid" ]]; then prefix="$(echo "$uid"|tr -d '-'|cut -c1-8)"; echo "pipeuser-${prefix}" | tee "$STATE_USERNAME_FILE"; return; fi
  gen_username | tee "$STATE_USERNAME_FILE"
}

has_encrypt_password_flag(){ pipe upload-file --help 2>/dev/null | grep -q -- '--password'; }
has_decrypt_password_flag(){ pipe download-file --help 2>/dev/null | grep -q -- '--password'; }
remote_exists(){ pipe file-info "$1" >/dev/null 2>&1; }

wait_until_available(){
  local name="$1" i=1; info "Waiting availability of '$name' (up to $((MAX_AVAIL_CHECKS*AVAIL_WAIT_SECS))s)…"
  while (( i<=MAX_AVAIL_CHECKS )); do
    if pipe file-info "$name" >/dev/null 2>&1; then ok "'$name' is available."; return 0; fi
    sleep "$AVAIL_WAIT_SECS"; ((i++))
  done
  err "'$name' still not available after waiting."; return 1
}

# ========================= Pre-flight =========================
command -v pipe >/dev/null 2>&1 || { err "CLI 'pipe' not found"; exit 1; }
mkdir -p "$WORKDIR"

# ========================= User ===============================
USERNAME=""
if [[ -f "$CONFIG_FILE" ]] && grep -q '"user_id"' "$CONFIG_FILE"; then
  ok "Existing Pipe user config detected: $CONFIG_FILE"
  USERNAME="$(recover_username)"
else
  USERNAME="$(gen_username)"
  retry_run "Create user" "pipe new-user ${USERNAME}" || { err "Cannot proceed without user."; exit 1; }
  echo "$USERNAME" > "$STATE_USERNAME_FILE"
fi

# Pubkey (best-effort)
SOL_CHECK_OUT="$(pipe check-sol 2>/dev/null || true)"
SOL_PUBKEY="$(printf "%s" "$SOL_CHECK_OUT" | parse_pubkey || true)"
[[ -n "$SOL_PUBKEY" ]] && ok "Solana Pubkey: ${SOL_PUBKEY}" || warn "Could not parse Solana Pubkey."

# ========================= Faucet prompt ======================
note "ACTION REQUIRED: Request DevNet SOL, then press Enter."
echo -e "${BLU}Faucets:${NC} https://faucet.solana.com  or  https://solfate.com/faucet"
[[ -n "$SOL_PUBKEY" ]] && echo -e "${BLU}Your Pubkey:${NC} ${SOL_PUBKEY}"
read -rp "$(echo -e "${CYA}[INPUT]${NC} Press Enter after requesting DevNet SOL…")" _

# ========================= Source file (50–150 MiB) ===========
SOURCE_MIN_MB=50; SOURCE_MAX_MB=150
RAND_MB="$(rand_int_range $SOURCE_MIN_MB $SOURCE_MAX_MB)"
BASE_NAME="${USERNAME}"
SRC_FILE="${WORKDIR}/${BASE_NAME}.bin"
if [[ -f "$SRC_FILE" ]]; then
  BASE_NAME="${USERNAME}-$(rand_suffix)"
  SRC_FILE="${WORKDIR}/${BASE_NAME}.bin"
fi
retry_run "Generate file" "dd if=/dev/urandom of='${SRC_FILE}' bs=1M count='${RAND_MB}' status=none"

# ========================= Wait for SOL =======================
SOL_BAL="0"; attempt=1
while (( attempt<=MAX_SOL_CHECKS )); do
  SOL_CHECK_OUT="$(pipe check-sol 2>/dev/null || true)"
  SOL_BAL="$(printf "%s" "$SOL_CHECK_OUT" | parse_sol_balance || echo 0)"
  info "SOL balance check #$attempt: ${SOL_BAL}"
  awk -v v="$SOL_BAL" 'BEGIN{exit !(v+0>0.0000001)}' && { ok "SOL balance is positive."; break; }
  info "No SOL yet. Sleeping ${SOL_WAIT_SECS}s…"; sleep "$SOL_WAIT_SECS"; ((attempt++))
done
(( attempt>MAX_SOL_CHECKS )) && warn "No SOL detected after waiting. Swap may fail."

# ========================= Swap SOL->PIPE (0.70–0.90) =========
SWAP_AMT="$(rand_sol_amount)"; attempt=1; SWAP_OK=0
while (( attempt<=MAX_RETRIES )); do
  info "Swap attempt ${attempt}/${MAX_RETRIES} for ${SWAP_AMT} SOL…"
  if pipe swap-sol-for-pipe "${SWAP_AMT}"; then ok "Swap succeeded."; SWAP_OK=1; break; fi
  warn "Swap failed. Decreasing amount and retrying after ${RETRY_PAUSE}s…"
  sleep "$RETRY_PAUSE"; SWAP_AMT=$(awk -v a="$SWAP_AMT" 'BEGIN{a=a-0.02; if(a<0.70)a=0.70; printf("%.2f", a)}'); ((attempt++))
done
(( SWAP_OK==0 )) && warn "Swap failed; continuing."

# ========================= Upload unencrypted =================
REMOTE_BASENAME="my-file"
REMOTE_PLAIN="$REMOTE_BASENAME"
if remote_exists "$REMOTE_PLAIN"; then
  note "Remote '$REMOTE_PLAIN' exists; creating a new name."
  REMOTE_PLAIN="${REMOTE_BASENAME}-$(rand_suffix)"
fi
retry_run "Upload unencrypted file" "pipe upload-file \"${SRC_FILE}\" \"${REMOTE_PLAIN}\" --tier normal"

wait_until_available "$REMOTE_PLAIN" || warn "Proceeding despite not-ready state."
sleep "$POST_AVAIL_SLEEP"

# ========================= Download back ======================
DST_FILE="${WORKDIR}/${BASE_NAME}.dl"
download_std(){ pipe download-file "$REMOTE_PLAIN" "$DST_FILE"; }
download_legacy(){ pipe download-file "$REMOTE_PLAIN" "$DST_FILE" --legacy; }

if ! retry_run "Download unencrypted file" "download_std"; then
  warn "Standard download failed; trying legacy after short wait…"
  sleep "$RETRY_PAUSE"
  retry_run "Download unencrypted file (legacy)" "download_legacy" || warn "Both streaming and legacy download failed. Skipping."
fi

# ========================= Public link ========================
PUBLINK_OUT=""; SOCIAL_LINK=""; DIRECT_LINK=""
if retry_capture "Create public link for '${REMOTE_PLAIN}'" PUBLINK_OUT "pipe create-public-link '${REMOTE_PLAIN}'"; then
  SOCIAL_LINK="$(printf "%s" "$PUBLINK_OUT" | parse_social_link || true)"
  DIRECT_LINK="$(printf "%s" "$PUBLINK_OUT" | parse_direct_link  || true)"
  if [[ -n "$SOCIAL_LINK" ]]; then ok "Social media link: $SOCIAL_LINK"
  elif [[ -n "$DIRECT_LINK" ]]; then ok "Direct link: $DIRECT_LINK"; SOCIAL_LINK="$DIRECT_LINK"
  else warn "Could not parse links from create-public-link output."; SOCIAL_LINK="N/A"
  fi
fi

# ========================= Encrypted upload (auto-pass) =======
SEC_REMOTE="secure-${BASE_NAME}"
ENC_PASS_FILE="${PASS_DIR}/${SEC_REMOTE}.pass"
ENC_PASS=""

ENC_PASS="$(gen_password)"
echo -e "${YEL}[WARNING]${NC} Generated encryption password (copy it now): ${BLU}${ENC_PASS}${NC}"

if has_encrypt_password_flag; then
  retry_run "Upload encrypted file" "pipe upload-file \"${SRC_FILE}\" \"${SEC_REMOTE}\" --encrypt --password \"${ENC_PASS}\""
else
  retry_run "Upload encrypted file" "{ printf '%s\n%s\n' \"${ENC_PASS}\" \"${ENC_PASS}\"; } | pipe upload-file \"${SRC_FILE}\" \"${SEC_REMOTE}\" --encrypt"
fi
# persist password
printf "%s" "$ENC_PASS" > "$ENC_PASS_FILE"; chmod 600 "$ENC_PASS_FILE"
echo "$(date -Is) ${SEC_REMOTE} ${ENC_PASS}" >> "$PASS_LOG"
note "Password saved: ${ENC_PASS_FILE} (logged in ${PASS_LOG})"

wait_until_available "$SEC_REMOTE" || warn "Encrypted object still not ready."
sleep "$POST_AVAIL_SLEEP"

# ========================= Download+decrypt (std->legacy) ====
DEC_FILE="${WORKDIR}/${BASE_NAME}.dec"
HAS_PASS_FLAG=""
has_decrypt_password_flag && HAS_PASS_FLAG=1
download_dec_std()    { pipe download-file "$SEC_REMOTE" "$DEC_FILE" --decrypt ${HAS_PASS_FLAG:+--password "$ENC_PASS"}; }
download_dec_legacy() { pipe download-file "$SEC_REMOTE" "$DEC_FILE" --decrypt --legacy ${HAS_PASS_FLAG:+--password "$ENC_PASS"}; }

if ! retry_run "Download+decrypt file" "download_dec_std"; then
  warn "Standard decrypt-download failed; trying legacy after short wait…"
  sleep "$RETRY_PAUSE"
  retry_run "Download+decrypt file (legacy)" "download_dec_legacy" || warn "Both streaming and legacy decrypt-download failed. Skipping."
fi

# ========================= SHA256 verify ======================
if [[ -f "$SRC_FILE" && -f "$DEC_FILE" ]]; then
  SUM_SRC="$(sha256sum "$SRC_FILE" | awk '{print $1}')"
  SUM_DEC="$(sha256sum "$DEC_FILE" | awk '{print $1}')"
  info "SHA256 src: $SUM_SRC"
  info "SHA256 dec: $SUM_DEC"
  [[ "$SUM_SRC" == "$SUM_DEC" ]] && ok "SHA256 verification PASSED" || err "SHA256 verification FAILED"
else
  warn "SHA256 verification skipped (files missing)."
fi

# ========================= Step 13: 3× random files =====
BULK_MIN_MB=20; BULK_MAX_MB=100
for i in 1 2 3; do
  RAND_BULK_MB="$(rand_int_range $BULK_MIN_MB $BULK_MAX_MB)"
  BULK_FILE="${WORKDIR}/bulk_${i}_$(rand_suffix).bin"
  info "Generating ${BULK_FILE} (${RAND_BULK_MB} MiB)…"
  retry_run "Generate bulk_${i}" "dd if=/dev/urandom of='${BULK_FILE}' bs=1M count='${RAND_BULK_MB}' status=none"
done
retry_run "Upload directory ${WORKDIR}" "pipe upload-directory '${WORKDIR}' --tier normal --skip-uploaded"

# ========================= Usage report =======================
retry_run "Token usage (30d detailed)" "pipe token-usage --period 30d --detailed || true"

echo -e "\n${GRN}==================== FINAL NOTICE ====================${NC}"
echo -e "To get the firestarter🔥 role in the Pipe Discord (https://discord.gg/e4YNnt5y4r):"
echo -e "1) Take screenshots of this script's console output and what it performed."
echo -e "2) Post on Twitter/X with the text:"
echo -e '   """Just launched my Pipe Firestarter node @pipenetwork #firestarter"""'
echo -e "   ❗️❗️❗️ also attach screenshots from the console to the post ❗️❗️❗️"
echo -e "   and include this Social media link (for sharing):"
echo -e "   ${BLU}${SOCIAL_LINK:-N/A}${NC}"
echo -e "3) Copy the link to your post, go to Discord → #🔥firestarter-storage-share and send it there."
echo -e "   Moderators review posts manually; the role will be assigned later."
echo -e ""
if [[ -f "$CONFIG_FILE" ]]; then
  echo -e "${YEL}[WARNING]${NC} Save this file to restore access on another server:"
  echo -e "  ${BLU}${CONFIG_FILE}${NC}  (contains user_id and user_app_key)"
else
  echo -e "${RED}[ERROR]${NC} Pipe CLI config not found: ${CONFIG_FILE}"
fi
echo -e "If this script was useful, please ⭐️ star ⭐️ the repo: https://github.com/noderguru/Pipe_Firestarter-Storage"
echo -e "${GRN}=======================================================${NC}"
