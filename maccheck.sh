#!/bin/bash
#
# Mac Diagnostika – technická diagnostika Macu z terminálu.
# https://github.com/vojnvk/maccheck
#
# Skript na systému nic nemění: pouze čte informace. Dočasné soubory
# (rozpracovaný report, dočasně stažený smartctl) ukládá do vlastní
# složky v /tmp a při ukončení ji smaže.
#
# Kompatibilní s bash 3.2 (výchozí bash v macOS), bez závislostí.
# Licence: MIT

set -u

VERSION="1.0.0"
REPO_URL="https://github.com/vojnvk/maccheck"

OPT_QUICK=0
OPT_NO_SUDO=0
OPT_COLOR=1
STRESS_SECONDS=180

# Oficiální build smartmontools – stahuje se jen na vyžádání a jen do /tmp.
SMARTCTL_URL="https://github.com/smartmontools/smartmontools/releases/download/RELEASE_7_5/smartmontools-7.5.dmg"
SMARTCTL_SHA256="4aa176c161612488f3db053fdf3eee47bbc5178c8fe46afb2002d8dbdf563cc5"

usage() {
	cat <<'EOF'
Mac Diagnostika – technická kontrola stavu Macu (pouze čte, nic nemění)

Použití:
  bash <(curl -fsSL https://raw.githubusercontent.com/vojnvk/maccheck/main/maccheck.sh) [přepínače]
  bash maccheck.sh [přepínače]

Přepínače:
  --quick            jen automatické kontroly (bez zátěžového testu a kontrolního seznamu)
  --no-sudo          nežádat o heslo správce; kontroly vyžadující sudo se přeskočí
  --no-color         výstup bez barev
  --stress-time N    délka zátěžového testu v sekundách (výchozí 180)
  -h, --help         zobrazí tuto nápovědu
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--quick) OPT_QUICK=1 ;;
	--no-sudo) OPT_NO_SUDO=1 ;;
	--no-color) OPT_COLOR=0 ;;
	--stress-time | --stress-time=*)
		if [ "$1" = "--stress-time" ]; then
			shift
			val=${1:-}
		else
			val=${1#--stress-time=}
		fi
		case "$val" in
		'' | *[!0-9]*)
			echo "--stress-time vyžaduje počet sekund" >&2
			exit 2
			;;
		esac
		STRESS_SECONDS=$val
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "Neznámý přepínač: $1 (viz --help)" >&2
		exit 2
		;;
	esac
	shift
done

if [ "$(uname -s 2>/dev/null)" != "Darwin" ]; then
	echo "Mac Diagnostika běží pouze na macOS." >&2
	exit 1
fi

# Čísla vždy s desetinnou tečkou, texty v UTF-8 (kvůli zarovnání české diakritiky).
unset LC_ALL
export LC_NUMERIC=C
export LC_CTYPE=en_US.UTF-8
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

[ -t 1 ] || OPT_COLOR=0
[ -n "${NO_COLOR:-}" ] && OPT_COLOR=0

if [ "$OPT_COLOR" = 1 ]; then
	C_RESET=$'\033[0m'
	C_BOLD=$'\033[1m'
	C_DIM=$'\033[2m'
	C_RED=$'\033[31m'
	C_GREEN=$'\033[32m'
	C_YELLOW=$'\033[33m'
	C_CYAN=$'\033[36m'
else
	C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN=""
fi

# ---------------------------------------------------------------------------
# Dočasná složka, úklid a signály
# ---------------------------------------------------------------------------

WORKDIR=$(mktemp -d /tmp/macdiag.XXXXXX 2>/dev/null) || {
	echo "Nelze vytvořit dočasnou složku v /tmp." >&2
	exit 1
}
RESULTS="$WORKDIR/results.tsv"
BODY="$WORKDIR/body.md"
KEYS="$WORKDIR/keys.tsv"
: >"$RESULTS"
: >"$BODY"
: >"$KEYS"

STRESS_PIDS=""
STRESS_WATCHDOG=""
PM_PID=""
HAVE_SUDO=0

stop_stress() {
	local p
	{
		for p in $STRESS_PIDS; do kill "$p"; done
		if [ -n "$STRESS_WATCHDOG" ]; then
			pkill -P "$STRESS_WATCHDOG"
			kill "$STRESS_WATCHDOG"
		fi
		[ -n "$PM_PID" ] && kill "$PM_PID"
		# Pojistka: jakýkoliv `yes` spuštěný tímto skriptem.
		pkill -x -P $$ yes
		for p in $STRESS_PIDS $STRESS_WATCHDOG $PM_PID; do wait "$p"; done
	} >/dev/null 2>&1
	STRESS_PIDS=""
	STRESS_WATCHDOG=""
	PM_PID=""
}

cleanup() {
	stop_stress
	if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR/smart-mnt" ]; then
		hdiutil detach "$WORKDIR/smart-mnt" -force -quiet >/dev/null 2>&1
	fi
	[ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
}

on_signal() {
	trap - INT TERM HUP
	printf '\n%sPřerušeno – ukončuji všechny spuštěné procesy…%s\n' "$C_YELLOW" "$C_RESET"
	exit 130
}

trap cleanup EXIT
trap on_signal INT TERM HUP

# ---------------------------------------------------------------------------
# Vstup z terminálu (funguje i při spuštění přes curl | bash)
# ---------------------------------------------------------------------------

HAVE_TTY=0
if (exec 3</dev/tty) 2>/dev/null; then
	exec 3</dev/tty && HAVE_TTY=1
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ask_yn "Otázka" a|n – vrací 0 pro ano. Bez terminálu vždy „ne“.
ask_yn() {
	local q=$1 def=$2 hint ans
	if [ "$def" = a ]; then hint="[A/n]"; else hint="[a/N]"; fi
	if [ "$HAVE_TTY" != 1 ]; then
		printf '  %s %s %s→ ne (bez terminálu)%s\n' "$q" "$hint" "$C_DIM" "$C_RESET"
		return 1
	fi
	while :; do
		printf '  %s%s%s %s ' "$C_BOLD" "$q" "$C_RESET" "$hint"
		ans=""
		IFS= read -r ans <&3 || echo
		case "$(lower "$ans")" in
		'') [ "$def" = a ] && return 0 || return 1 ;;
		a | ano | y | yes) return 0 ;;
		n | ne | no) return 1 ;;
		esac
		echo "  Zadejte a (ano) nebo n (ne)."
	done
}

# ---------------------------------------------------------------------------
# Výstup a report
# ---------------------------------------------------------------------------

# pad "text" šířka – doplní mezery podle počtu znaků (ne bajtů).
pad() {
	local s=$1 n=$(($2 - ${#1}))
	while [ $n -gt 0 ]; do
		s="$s "
		n=$((n - 1))
	done
	printf '%s' "$s"
}

section() {
	printf '\n%s%s━━ %s %s%s\n' "$C_BOLD" "$C_CYAN" "$1" "━━━━━━━━━━━━━━━━━━━━" "$C_RESET"
	printf '\n## %s\n\n' "$1" >>"$BODY"
}

note() {
	printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RESET"
}

# kv "Popisek" "hodnota" – informativní údaj (nezapočítává se do souhrnu).
kv() {
	local v=${2:-}
	[ -n "$v" ] || v="neznámé"
	printf '  %s%s%s %s\n' "$C_DIM" "$(pad "$1:" 24)" "$C_RESET" "$v"
	printf -- '- %s: %s\n' "$1" "$v" >>"$BODY"
}

# record ok|warn|err|skip "Kontrola" "Naměřená hodnota"
record() {
	local st=$1 label=$2 detail=$3 icon word color
	case "$st" in
	ok) icon="✅" word="OK" color=$C_GREEN ;;
	warn) icon="⚠️" word="Pozor" color=$C_YELLOW ;;
	err) icon="❌" word="Chyba" color=$C_RED ;;
	*) icon="⏭️" word="Přeskočeno" color=$C_DIM st=skip ;;
	esac
	printf '  %s %s%s%s %s%s:%s %s\n' "$icon" "$color$C_BOLD" "$(pad "$word" 10)" "$C_RESET" "$C_BOLD" "$label" "$C_RESET" "$detail"
	printf '%s\t%s\t%s\n' "$st" "$label" "$detail" >>"$RESULTS"
	printf -- '- %s %s – **%s:** %s\n' "$icon" "$word" "$label" "$detail" >>"$BODY"
}

# key "Údaj" "hodnota" – klíčový údaj pro blok na začátku souhrnu.
key() {
	printf "%s\t%s\n" "$1" "$2" >>"$KEYS"
}

# Spustí kontrolu v podprocesu, aby chyba v jedné kontrole nezastavila celý skript.
run_check() {
	local name=$1
	("$name")
	local rc=$?
	if [ $rc -ne 0 ] && [ $rc -ne 130 ]; then
		record skip "$name" "kontrola skončila neočekávanou chybou (kód $rc)"
	fi
}

# spval "Klíč" "text" – hodnota řádku „Klíč: hodnota“ z výstupu system_profiler.
spval() {
	printf '%s\n' "$2" | awk -v k="$1" '{
		key = $0; sub(/:.*/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", key)
		if (key == k) { v = $0; sub(/^[^:]*:[ \t]*/, "", v); print v; exit }
	}'
}

# num "Klíč" "text" – první číselná hodnota z ioreg ("Klíč" = 123 nebo "Klíč"=123).
num() {
	printf '%s\n' "$2" | grep -oE "\"$1\" ?= ?[0-9]+" | head -1 | grep -oE '[0-9]+$'
}

fmt_dur() {
	printf '%d:%02d' $(($1 / 60)) $(($1 % 60))
}

# ---------------------------------------------------------------------------
# Společná data
# ---------------------------------------------------------------------------

IS_ARM=0
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] && IS_ARM=1

SP_HW=$(system_profiler SPHardwareDataType 2>/dev/null) || SP_HW=""
MODEL_NAME=$(spval "Model Name" "$SP_HW")
IS_LAPTOP=0
case "$MODEL_NAME" in *MacBook*) IS_LAPTOP=1 ;; esac
SERIAL=$(spval "Serial Number (system)" "$SP_HW")
[ -n "$SERIAL" ] || SERIAL=$(spval "Serial Number" "$SP_HW")
DISK0=$(diskutil info disk0 2>/dev/null) || DISK0=""

# ---------------------------------------------------------------------------
# Automatické kontroly
# ---------------------------------------------------------------------------

check_hardware() {
	section "Hardware"
	local marketing="" chip cores gpu_cores ram ssd_size os
	if [ "$IS_ARM" = 1 ]; then
		marketing=$(ioreg -ar -d1 -k product-name 2>/dev/null |
			plutil -extract 0.product-name raw -o - - 2>/dev/null |
			base64 -D 2>/dev/null | tr -d '\000')
	fi
	chip=$(spval "Chip" "$SP_HW")
	if [ -z "$chip" ]; then
		chip=$(spval "Processor Name" "$SP_HW")
		local speed
		speed=$(spval "Processor Speed" "$SP_HW")
		[ -n "$speed" ] && chip="$chip, $speed"
	fi
	cores=$(spval "Total Number of Cores" "$SP_HW")
	gpu_cores=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Total Number of Cores/ {print $2; exit}')
	ram=$(spval "Memory" "$SP_HW")
	ssd_size=$(spval "Disk Size" "$DISK0" | sed 's/ (.*//')
	os="$(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"

	kv "Model" "${marketing:-$MODEL_NAME}"
	kv "Identifikátor modelu" "$(spval "Model Identifier" "$SP_HW")"
	kv "Číslo modelu" "$(spval "Model Number" "$SP_HW")"
	kv "Čip / procesor" "$chip"
	if [ "$IS_ARM" = 1 ]; then
		kv "Architektura" "Apple Silicon (arm64)"
	else
		kv "Architektura" "Intel (x86_64)"
	fi
	kv "Jádra CPU" "$cores"
	[ -n "$gpu_cores" ] && kv "Jádra GPU" "$gpu_cores"
	kv "Paměť (RAM)" "$ram"
	kv "SSD" "$ssd_size"
	kv "Sériové číslo" "$SERIAL"
	kv "macOS" "$os"
	return 0
}

check_security() {
	section "Zámek aktivace, Najít a správa zařízení"

	# Activation Lock
	local al
	al=$(spval "Activation Lock Status" "$SP_HW")
	case "$al" in
	Enabled) record err "Activation Lock" "Zapnuto" ;;
	Disabled) record ok "Activation Lock" "Vypnuto" ;;
	'') record skip "Activation Lock" "údaj není k dispozici (vyžaduje Apple Silicon nebo čip T2)" ;;
	*) record warn "Activation Lock" "$al" ;;
	esac

	# Najít Mac (heuristika přes NVRAM token)
	local nv
	if nv=$(nvram -x -p 2>/dev/null); then
		if printf '%s' "$nv" | grep -q "fmm-mobileme-token-FMM"; then
			record warn "Najít Mac" "Zapnuto"
		else
			record ok "Najít Mac" "Vypnuto"
		fi
	else
		record skip "Najít Mac" "NVRAM nelze přečíst"
	fi

	# MDM / DEP
	local st dep mdm
	st=$(profiles status -type enrollment 2>/dev/null)
	if [ -n "$st" ]; then
		dep=$(spval "Enrolled via DEP" "$st")
		mdm=$(spval "MDM enrollment" "$st")
		case "$dep$mdm" in
		*Yes*) record err "Registrace MDM" "DEP: ${dep:-?}, MDM: ${mdm:-?}" ;;
		*) record ok "Registrace MDM" "DEP: ${dep:-?}, MDM: ${mdm:-?}" ;;
		esac
	else
		record skip "Registrace MDM" "příkaz profiles nevrátil výsledek"
	fi

	if [ "$HAVE_SUDO" = 1 ]; then
		local rec org
		rec=$(sudo -n profiles show -type enrollment 2>&1)
		org=$(printf '%s\n' "$rec" | awk -F' = ' '/OrganizationName/ {gsub(/[";]/, "", $2); print $2; exit}')
		if printf '%s' "$rec" | grep -qE 'ConfigurationURL|OrganizationName|IsMDMUnremovable'; then
			record err "Záznam DEP (Apple Business Manager)" "nalezen${org:+ – organizace: $org}"
		elif printf '%s' "$rec" | grep -qiE 'error|unable|failed|not connected|offline'; then
			record skip "Záznam DEP (Apple Business Manager)" "nelze ověřit (je Mac připojen k internetu?)"
		else
			record ok "Záznam DEP (Apple Business Manager)" "nenalezen"
		fi

		local prof ids cnt
		prof=$(sudo -n profiles list -all 2>/dev/null)
		ids=$(printf '%s\n' "$prof" | sed -n 's/.*profileIdentifier: *//p' | sort -u)
		cnt=$(printf '%s\n' "$ids" | grep -c . | tr -d ' ')
		if [ "$cnt" -gt 0 ]; then
			record warn "Konfigurační profily" "$cnt nainstalováno: $(printf '%s' "$ids" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
		else
			record ok "Konfigurační profily" "žádné"
		fi
	else
		local prof ids cnt
		prof=$(profiles list 2>/dev/null)
		ids=$(printf '%s\n' "$prof" | sed -n 's/.*profileIdentifier: *//p' | sort -u)
		cnt=$(printf '%s\n' "$ids" | grep -c . | tr -d ' ')
		if [ "$cnt" -gt 0 ]; then
			record warn "Konfigurační profily (uživatel)" "$cnt nainstalováno: $(printf '%s' "$ids" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
		else
			record ok "Konfigurační profily (uživatel)" "žádné"
		fi
		record skip "Záznam DEP a systémové profily" "vyžaduje sudo"
	fi

	# SIP
	local sip
	sip=$(csrutil status 2>/dev/null)
	case "$sip" in
	*"status: enabled."*) record ok "SIP (System Integrity Protection)" "zapnuto" ;;
	*disabled*) record warn "SIP (System Integrity Protection)" "vypnuto" ;;
	'') record skip "SIP (System Integrity Protection)" "stav nelze zjistit" ;;
	*) record warn "SIP (System Integrity Protection)" "$(printf '%s' "$sip" | head -1)" ;;
	esac
	return 0
}

check_battery() {
	section "Baterie a napájení"
	local io sp
	io=$(ioreg -rn AppleSmartBattery -w0 2>/dev/null)
	if [ -z "$io" ]; then
		record skip "Baterie" "nenalezena (stolní Mac)"
		return 0
	fi
	sp=$(system_profiler SPPowerDataType 2>/dev/null)
	local bat_block ac_block
	bat_block=$(printf '%s\n' "$sp" | sed -n '/Battery Information:/,/System Power Settings:/p')
	ac_block=$(printf '%s\n' "$sp" | sed -n '/AC Charger Information:/,/Power Events:/p')

	# Cykly
	local cycles
	cycles=$(spval "Cycle Count" "$bat_block")
	[ -n "$cycles" ] || cycles=$(num CycleCount "$io")
	if [ -n "$cycles" ]; then
		if [ "$cycles" -lt 300 ]; then
			record ok "Počet cyklů" "$cycles (návrhový limit 1000)"
		elif [ "$cycles" -le 700 ]; then
			record warn "Počet cyklů" "$cycles (návrhový limit 1000)"
		else
			record err "Počet cyklů" "$cycles (návrhový limit 1000)"
		fi
	else
		record skip "Počet cyklů" "údaj není k dispozici"
	fi
	key "Cykly baterie" "${cycles:-nezjištěno}"

	# Stav podle macOS
	local cond
	cond=$(spval "Condition" "$bat_block")
	case "$cond" in
	'') record skip "Stav baterie (macOS)" "údaj není k dispozici" ;;
	Normal) record ok "Stav baterie (macOS)" "Normal" ;;
	*Service* | *Replace* | *Poor*) record err "Stav baterie (macOS)" "$cond" ;;
	*) record warn "Stav baterie (macOS)" "$cond" ;;
	esac

	# Skutečná kapacita z ioreg
	local design raw maxcap health
	design=$(num DesignCapacity "$io")
	raw=$(num AppleRawMaxCapacity "$io")
	[ -n "$raw" ] || raw=$(num NominalChargeCapacity "$io")
	[ -n "$raw" ] || raw=$(num FullChargeCapacity "$io")
	maxcap=$(spval "Maximum Capacity" "$bat_block")
	if [ -n "$design" ] && [ -n "$raw" ] && [ "$design" -gt 0 ]; then
		health=$(awk -v r="$raw" -v d="$design" 'BEGIN { printf "%.1f", r * 100 / d }')
		key "Kapacita baterie" "${maxcap:-$health %} (výpočet z ioreg: $health %)"
		local detail="kapacita $health % návrhové ($raw / $design mAh)"
		[ -n "$maxcap" ] && detail="$detail; macOS uvádí Maximum Capacity $maxcap"
		if awk -v h="$health" 'BEGIN { exit !(h >= 90) }'; then
			record ok "Zdraví baterie" "$detail"
		elif awk -v h="$health" 'BEGIN { exit !(h >= 80) }'; then
			record warn "Zdraví baterie" "$detail"
		else
			record err "Zdraví baterie" "$detail"
		fi
	elif [ -n "$maxcap" ]; then
		key "Kapacita baterie" "$maxcap"
		record ok "Zdraví baterie" "macOS uvádí Maximum Capacity $maxcap (výpočet z ioreg není k dispozici)"
	else
		record skip "Zdraví baterie" "údaje o kapacitě nejsou k dispozici"
	fi

	local charge
	charge=$(spval "State of Charge (%)" "$bat_block")
	if [ -n "$charge" ]; then
		kv "Aktuální nabití" "$charge %"
		key "Nabití baterie" "$charge %"
	fi

	# Nabíječka
	local connected watts charging name
	connected=$(spval "Connected" "$ac_block")
	if [ "$connected" = "Yes" ]; then
		watts=$(spval "Wattage (W)" "$ac_block")
		[ -n "$watts" ] || watts=$(num Watts "$io")
		charging=$(spval "Charging" "$ac_block")
		name=$(spval "Name" "$ac_block")
		local d="připojena"
		[ -n "$watts" ] && d="$d, $watts W"
		[ -n "$name" ] && d="$d, $name"
		case "$charging" in
		Yes) d="$d, nabíjí" ;;
		No) d="$d, nenabíjí (při plné baterii nebo optimalizovaném nabíjení je to běžné)" ;;
		esac
		kv "Nabíječka" "$d"
	else
		kv "Nabíječka" "nepřipojena"
	fi
	return 0
}

# Stáhne oficiální smartmontools do WORKDIR a vypíše cestu k smartctl.
# Nic neinstaluje: obraz se připojí jen pro čtení, balíček se rozbalí do /tmp.
# Návratový kód: 0 = OK, 1 = stažení/rozbalení selhalo, 2 = nesouhlasí SHA-256.
fetch_smartctl() {
	local dmg="$WORKDIR/smartmontools.dmg" mnt="$WORKDIR/smart-mnt" dest="$WORKDIR/smart-pkg" sum bin
	curl -fsSL --max-time 60 -o "$dmg" "$SMARTCTL_URL" 2>/dev/null || return 1
	sum=$(shasum -a 256 "$dmg" 2>/dev/null | awk '{print $1}')
	[ "$sum" = "$SMARTCTL_SHA256" ] || return 2
	mkdir -p "$mnt" || return 1
	hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null 2>&1 || return 1
	pkgutil --expand-full "$mnt"/*.pkg "$dest" >/dev/null 2>&1
	hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || hdiutil detach "$mnt" -force -quiet >/dev/null 2>&1
	bin=$(find "$dest" -name smartctl -type f 2>/dev/null | head -1)
	[ -n "$bin" ] && [ -x "$bin" ] || return 1
	printf '%s\n' "$bin"
}

check_ssd() {
	section "Úložiště (SSD)"
	if [ -z "$DISK0" ]; then
		record skip "SSD" "diskutil info disk0 nevrátil výsledek"
		return 0
	fi
	kv "Model" "$(spval "Device / Media Name" "$DISK0")"
	kv "Kapacita" "$(spval "Disk Size" "$DISK0" | sed 's/ (.*//')"
	kv "Rozhraní" "$(spval "Protocol" "$DISK0")"
	local smart
	smart=$(spval "SMART Status" "$DISK0")
	case "$smart" in
	Verified) record ok "SMART" "Verified" ;;
	*Fail*) record err "SMART" "$smart" ;;
	'' | "Not Supported") record skip "SMART" "není podporováno" ;;
	*) record warn "SMART" "$smart" ;;
	esac

	local smartctl_bin
	smartctl_bin=$(command -v smartctl 2>/dev/null)
	if [ -z "$smartctl_bin" ]; then
		note "Opotřebení SSD (Percentage Used, zapsaná data) umí přečíst smartctl ze smartmontools."
		note "Nic se neinstaluje: oficiální balíček (1,6 MB, GitHub smartmontools) se ověří a rozbalí jen do /tmp."
		if ask_yn "Stáhnout smartctl dočasně do /tmp?" a; then
			smartctl_bin=$(fetch_smartctl)
			case $? in
			0) ;;
			2) note "Kontrolní součet staženého souboru nesouhlasí – smartctl se nepoužije." ;;
			*) note "smartctl se nepodařilo stáhnout (je Mac připojen k internetu?)." ;;
			esac
		fi
	fi

	if [ -n "$smartctl_bin" ]; then
		local out used units tb spare hours unsafe media crit
		out=$("$smartctl_bin" -a disk0 2>/dev/null)
		[ -n "$out" ] || { [ "$HAVE_SUDO" = 1 ] && out=$(sudo -n "$smartctl_bin" -a disk0 2>/dev/null); }
		used=$(printf '%s\n' "$out" | awk -F: '/Percentage Used/ {gsub(/[ %]/, "", $2); print $2; exit}')
		units=$(printf '%s\n' "$out" | awk -F: '/Data Units Written/ {print $2; exit}' | sed 's/\[.*//; s/[ ,.]//g')
		spare=$(printf '%s\n' "$out" | awk -F: '/^Available Spare:/ {gsub(/ /, "", $2); print $2; exit}')
		hours=$(printf '%s\n' "$out" | awk -F: '/^Power On Hours:/ {gsub(/[ ,]/, "", $2); print $2; exit}')
		unsafe=$(printf '%s\n' "$out" | awk -F: '/^Unsafe Shutdowns:/ {gsub(/[ ,]/, "", $2); print $2; exit}')
		media=$(printf '%s\n' "$out" | awk -F: '/^Media and Data Integrity Errors:/ {gsub(/[ ,]/, "", $2); print $2; exit}')
		crit=$(printf '%s\n' "$out" | awk -F: '/^Critical Warning:/ {gsub(/ /, "", $2); print $2; exit}')
		case "$crit" in
		'') ;;
		0x00) record ok "Kritické varování SSD (smartctl)" "žádné (0x00)" ;;
		*) record err "Kritické varování SSD (smartctl)" "$crit" ;;
		esac
		case "$media" in
		'') ;;
		0) record ok "Chyby integrity dat SSD (smartctl)" "0" ;;
		*) record err "Chyby integrity dat SSD (smartctl)" "$media" ;;
		esac
		if [ -n "$used" ]; then
			if [ "$used" -lt 80 ]; then
				record ok "Opotřebení SSD (smartctl)" "Percentage Used $used %${spare:+, Available Spare $spare}"
			elif [ "$used" -lt 100 ]; then
				record warn "Opotřebení SSD (smartctl)" "Percentage Used $used %${spare:+, Available Spare $spare}"
			else
				record err "Opotřebení SSD (smartctl)" "Percentage Used $used %${spare:+, Available Spare $spare}"
			fi
		fi
		if [ -n "$units" ]; then
			# 1 NVMe data unit = 1000 × 512 B
			tb=$(awk -v u="$units" 'BEGIN { printf "%.2f", u * 512000 / 1e12 }')
			kv "Zapsáno celkem" "$tb TB"
		fi
		if [ -n "$hours" ]; then
			kv "Doba provozu SSD" "$hours h"
			key "Hodiny provozu SSD" "$hours h"
		else
			key "Hodiny provozu SSD" "nezjištěno"
		fi
		[ -n "$unsafe" ] && kv "Nečistá vypnutí" "$unsafe"
		[ -n "$used$units" ] || record skip "Opotřebení SSD (smartctl)" "smartctl nevrátil NVMe údaje"

		# Kolikrát se zapsala celá kapacita disku
		local bytes rewrites
		bytes=$(spval "Disk Size" "$DISK0" | sed -n 's/.*(\([0-9]*\) Bytes).*/\1/p')
		if [ -n "$units" ] && [ -n "$bytes" ] && [ "$bytes" -gt 0 ]; then
			rewrites=$(awk -v u="$units" -v b="$bytes" 'BEGIN { printf "%.0f", u * 512000 / b }')
			kv "Přepsání celé kapacity" "${rewrites}×"
		fi

		# Celkové hodnocení: 0 = výborný, 1 = dobrý, 2 = opotřebený, 3 = kritický
		local thr lvl=0 why="" grade
		thr=$(printf '%s\n' "$out" | awk -F: '/^Available Spare Threshold:/ {gsub(/[ %]/, "", $2); print $2; exit}')
		spare=${spare%\%}
		case "$smart" in *Fail*)
			lvl=3
			why="$why, SMART: $smart"
			;;
		esac
		if [ -n "$crit" ] && [ "$crit" != "0x00" ]; then
			lvl=3
			why="$why, kritické varování $crit"
		fi
		if [ -n "$media" ] && [ "$media" -gt 0 ]; then
			lvl=3
			why="$why, chyby integrity dat: $media"
		fi
		if [ -n "$spare" ] && [ -n "$thr" ] && [ "$spare" -lt "$thr" ]; then
			lvl=3
			why="$why, rezerva bloků $spare % pod prahem $thr %"
		elif [ -n "$spare" ] && [ "$spare" -lt 50 ] && [ "$lvl" -lt 2 ]; then
			lvl=2
			why="$why, rezerva bloků $spare %"
		fi
		if [ -n "$used" ]; then
			if [ "$used" -ge 100 ]; then
				lvl=3
			elif [ "$used" -ge 80 ] && [ "$lvl" -lt 2 ]; then
				lvl=2
			elif [ "$used" -ge 10 ] && [ "$lvl" -lt 1 ]; then
				lvl=1
			fi
			why="$why, opotřebení $used %, zbývá ~$((used < 100 ? 100 - used : 0)) % odhadované životnosti"
		fi
		why=${why#, }
		case $lvl in
		0) grade="Výborný" ;;
		1) grade="Dobrý" ;;
		2) grade="Opotřebený" ;;
		*) grade="Kritický" ;;
		esac
		if [ -n "$used$crit$media" ]; then
			case $lvl in
			0 | 1) record ok "Celkový stav SSD" "$grade – $why" ;;
			2) record warn "Celkový stav SSD" "$grade – $why" ;;
			*) record err "Celkový stav SSD" "$grade – $why" ;;
			esac
			key "Stav SSD" "$grade – $why"
		fi
	else
		record skip "Opotřebení SSD" "smartctl není k dispozici"
		key "Stav SSD" "SMART: ${smart:-nezjištěno} (podrobné hodnocení vyžaduje smartctl)"
		key "Hodiny provozu SSD" "nezjištěno (bez smartctl)"
	fi
	return 0
}

check_panics() {
	section "Kernel panic a pády systému"
	local dir=/Library/Logs/DiagnosticReports files
	if [ -r "$dir" ] && [ -x "$dir" ]; then
		files=$(find "$dir" -maxdepth 2 -type f 2>/dev/null)
	elif [ "$HAVE_SUDO" = 1 ]; then
		files=$(sudo -n find "$dir" -maxdepth 2 -type f 2>/dev/null)
	else
		record skip "Kernel panic" "složku $dir nelze číst bez sudo"
		return 0
	fi

	local panics recent_list total recent f d
	panics=$(printf '%s\n' "$files" | grep -iE '/[^/]*panic[^/]*$|/Kernel[-_][^/]*$')
	total=$(printf '%s\n' "$panics" | grep -c . | tr -d ' ')
	recent=0
	recent_list=""
	if [ "$total" -gt 0 ]; then
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			if [ -n "$(find "$f" -mtime -90 2>/dev/null)" ] ||
				{ [ "$HAVE_SUDO" = 1 ] && [ -n "$(sudo -n find "$f" -mtime -90 2>/dev/null)" ]; }; then
				recent=$((recent + 1))
				d=$(stat -f '%Sm' -t '%Y-%m-%d' "$f" 2>/dev/null)
				recent_list="$recent_list${recent_list:+, }${d:-?}"
			fi
		done <<EOF
$panics
EOF
	fi
	recent_list=$(printf '%s' "$recent_list" | tr ',' '\n' | sed 's/^ //' | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')

	local detail="za posledních 90 dní: $recent${recent_list:+ ($recent_list)}; celkem v záznamech: $total"
	if [ "$recent" -ge 2 ]; then
		record err "Kernel panic" "$detail"
	elif [ "$recent" -eq 1 ]; then
		record warn "Kernel panic" "$detail"
	else
		record ok "Kernel panic" "$detail"
	fi

	local resets crashes
	resets=$(printf '%s\n' "$files" | grep -ciE '/forceReset[^/]*$' | tr -d ' ')
	kv "Vynucená vypnutí (záznamy)" "$resets"
	crashes=$(cd "$dir" 2>/dev/null && find . -maxdepth 2 -type f \( -name '*.ips' -o -name '*.crash' \) -mtime -90 2>/dev/null | grep -vic panic | tr -d ' ')
	kv "Pády aplikací (90 dní)" "${crashes:-0}"
	return 0
}

check_peripherals() {
	section "Periferie"

	# Displej
	local disp internal ext_count
	disp=$(system_profiler SPDisplaysDataType 2>/dev/null | awk '
		/^        [^ ].*:[ \t]*$/ { n = $0; gsub(/^ +|:[ \t]*$/, "", n); names[++cnt] = n }
		/Resolution:/ { r = $0; sub(/^[^:]*:[ \t]*/, "", r); res[n] = r }
		/Display Type: Built-in|Connection Type: Internal|Built-In: Yes/ { intl[n] = 1 }
		END { for (i = 1; i <= cnt; i++) { k = names[i]; if (k in res) print (k in intl ? "int" : "ext") "|" k "|" res[k] } }')
	internal=$(printf '%s\n' "$disp" | awk -F'|' '$1 == "int" {print $2 " – " $3; exit}')
	ext_count=$(printf '%s\n' "$disp" | grep -c '^ext|' | tr -d ' ')
	if [ -n "$internal" ]; then
		record ok "Vestavěný displej" "$internal"
	elif [ "$IS_LAPTOP" = 1 ]; then
		record warn "Vestavěný displej" "nenalezen (zavřené víko?)"
	fi
	[ "$ext_count" -gt 0 ] && kv "Externí displeje" "$ext_count"

	# Kamera
	local cams
	cams=$(system_profiler SPCameraDataType 2>/dev/null | sed -n 's/^    \([^ ].*\):[[:space:]]*$/\1/p')
	if printf '%s\n' "$cams" | grep -qi facetime; then
		record ok "Kamera" "$(printf '%s\n' "$cams" | grep -i facetime | head -1)"
	elif [ -n "$cams" ]; then
		record warn "Kamera" "vestavěná FaceTime kamera nenalezena (nalezeno: $(printf '%s' "$cams" | tr '\n' ',' | sed 's/,/, /g'))"
	elif [ "$IS_LAPTOP" = 1 ]; then
		record warn "Kamera" "nenalezena"
	else
		record skip "Kamera" "nenalezena (stolní Mac)"
	fi

	# Audio – vestavěné reproduktory a mikrofon
	local audio spk mic
	audio=$(system_profiler SPAudioDataType 2>/dev/null | awk '
		function flush() { if (n != "" && t == "Built-in") print n "|" i "|" o }
		/^        [^ ].*:[ \t]*$/ { flush(); n = $0; gsub(/^ +|:[ \t]*$/, "", n); t = ""; i = 0; o = 0 }
		/Transport:/ { t = $0; sub(/^[^:]*:[ \t]*/, "", t) }
		/Input Channels:/ { i = $NF }
		/Output Channels:/ { o = $NF }
		END { flush() }')
	spk=$(printf '%s\n' "$audio" | awk -F'|' '$3 > 0 {print $1 " (" $3 " kanály)"; exit}')
	mic=$(printf '%s\n' "$audio" | awk -F'|' '$2 > 0 {print $1; exit}')
	if [ -n "$spk" ]; then record ok "Reproduktory" "$spk"; else record warn "Reproduktory" "vestavěné nenalezeny"; fi
	if [ -n "$mic" ]; then record ok "Mikrofon" "$mic"; else record warn "Mikrofon" "vestavěný nenalezen"; fi

	# Wi-Fi
	local wdev wstat
	wdev=$(networksetup -listallhardwareports 2>/dev/null | awk '/Hardware Port: (Wi-Fi|AirPort)/ {getline; print $2; exit}')
	if [ -n "$wdev" ]; then
		wstat=$(ifconfig "$wdev" 2>/dev/null | awk '/status:/ {print $2; exit}')
		record ok "Wi‑Fi" "rozhraní $wdev, stav: ${wstat:-neznámý}"
	else
		record err "Wi‑Fi" "rozhraní nenalezeno"
	fi

	# Bluetooth
	local bt bst chip
	bt=$(system_profiler SPBluetoothDataType 2>/dev/null)
	bst=$(spval "State" "$bt")
	[ -n "$bst" ] || bst=$(spval "Bluetooth Power" "$bt")
	chip=$(spval "Chipset" "$bt")
	if [ -n "$bst$chip" ]; then
		record ok "Bluetooth" "řadič nalezen${chip:+ ($chip)}, stav: ${bst:-?}"
	else
		record err "Bluetooth" "řadič nenalezen"
	fi

	# Touch ID
	if [ "$IS_ARM" = 1 ]; then
		if ioreg -rc AppleBiometricSensor 2>/dev/null | grep -q "<class"; then
			record ok "Touch ID" "senzor nalezen"
		elif [ "$IS_LAPTOP" = 1 ]; then
			record warn "Touch ID" "senzor nenalezen"
		else
			record skip "Touch ID" "senzor nenalezen (stolní Mac / externí klávesnice)"
		fi
	else
		record skip "Touch ID" "na Intel Macu nelze ověřit"
	fi

	# Vestavěná klávesnice a trackpad
	if [ "$IS_LAPTOP" = 1 ]; then
		if ioreg -l -w0 2>/dev/null | grep -q '"Apple Internal Keyboard / Trackpad"'; then
			record ok "Klávesnice a trackpad" "vestavěné zařízení nalezeno"
		else
			record warn "Klávesnice a trackpad" "vestavěné zařízení nenalezeno"
		fi
	fi

	# Thunderbolt / USB4
	local tb buses ports conn
	tb=$(system_profiler SPThunderboltDataType 2>/dev/null)
	buses=$(printf '%s\n' "$tb" | grep -cE '^    Thunderbolt.*Bus' | tr -d ' ')
	ports=$(printf '%s\n' "$tb" | grep -c 'Receptacle:' | tr -d ' ')
	conn=$(printf '%s\n' "$tb" | grep -c 'Status: Device connected' | tr -d ' ')
	if [ "$buses" -gt 0 ]; then
		record ok "Thunderbolt / USB4" "sběrnice: $buses, porty: $ports, připojená zařízení: $conn"
	else
		record skip "Thunderbolt / USB4" "sběrnice nenalezena"
	fi
	return 0
}

check_system_info() {
	section "Provoz systému"
	local boot now up days hours mins
	boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*{ *sec = \([0-9]*\).*/\1/p')
	now=$(date +%s)
	if [ -n "$boot" ]; then
		up=$((now - boot))
		days=$((up / 86400))
		hours=$((up % 86400 / 3600))
		mins=$((up % 3600 / 60))
		kv "Doba běhu (uptime)" "$days d $hours h $mins min (od $(date -r "$boot" '+%Y-%m-%d %H:%M'))"
	fi
	if [ -e /var/db/.AppleSetupDone ]; then
		kv "První nastavení systému" "$(stat -f '%Sm' -t '%Y-%m-%d' /var/db/.AppleSetupDone 2>/dev/null)"
	fi
	local users
	users=$(dscl . list /Users UniqueID 2>/dev/null | awk '$2 >= 501 && $2 < 1000 {c++} END {print c + 0}')
	kv "Uživatelské účty" "$users"
	return 0
}

show_serial() {
	section "Sériové číslo a záruka"
	kv "Sériové číslo" "${SERIAL:-neznámé}"
	kv "Ověření záruky" "https://checkcoverage.apple.com/"
	if [ -n "$SERIAL" ] && [ "$OPT_QUICK" = 0 ]; then
		if ask_yn "Zkopírovat sériové číslo do schránky a otevřít checkcoverage.apple.com?" n; then
			printf '%s' "$SERIAL" | pbcopy && note "Sériové číslo je ve schránce – na stránce ho vložte Cmd+V (stránka vyžaduje opsání CAPTCHA)."
			open "https://checkcoverage.apple.com/" 2>/dev/null
		fi
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Zátěžový test
# ---------------------------------------------------------------------------

THERMAL_NAMES="Nominal Moderate Heavy Trapping Sleeping"

thermal_level() {
	local v
	v=$(notifyutil -g com.apple.system.thermalpressurelevel 2>/dev/null | awk '{print $2}')
	case "$v" in '' | *[!0-9]*) echo -1 ;; *) echo "$v" ;; esac
}

level_name() {
	[ "$1" -ge 0 ] 2>/dev/null || {
		echo "neznámý"
		return
	}
	# shellcheck disable=SC2086
	set -- $1 $THERMAL_NAMES
	local i=$1
	shift
	while [ "$i" -gt 0 ] && [ $# -gt 1 ]; do
		shift
		i=$((i - 1))
	done
	echo "$1"
}

stress_test() {
	section "Zátěžový test CPU"
	local n
	n=$(sysctl -n hw.ncpu 2>/dev/null)
	case "$n" in '' | *[!0-9]*) n=4 ;; esac
	note "Zatíží všech $n jader po dobu $(fmt_dur "$STRESS_SECONDS") a sleduje tepelný tlak."
	note "Ctrl+C test kdykoliv bezpečně ukončí (všechny procesy zátěže se zastaví)."
	if ! ask_yn "Spustit zátěžový test?" n; then
		record skip "Zátěžový test" "nespuštěn"
		return 0
	fi

	local use_pm=0
	if [ "$HAVE_SUDO" = 1 ] && sudo -n true 2>/dev/null; then
		local samplers="thermal,cpu_power"
		[ "$IS_ARM" = 1 ] || samplers="thermal,smc,cpu_power"
		# Výstup zapisuje uživatel do vlastní složky v /tmp, root ho nepotřebuje.
		# shellcheck disable=SC2024
		sudo -n powermetrics --samplers "$samplers" -i 5000 >"$WORKDIR/powermetrics.txt" 2>/dev/null &
		PM_PID=$!
		use_pm=1
	fi

	local i=0
	while [ $i -lt "$n" ]; do
		yes >/dev/null 2>&1 &
		STRESS_PIDS="$STRESS_PIDS $!"
		i=$((i + 1))
	done
	# Pojistka pro případ, že by skript skončil bez úklidu (např. kill -9).
	# shellcheck disable=SC2086
	(sleep $((STRESS_SECONDS + 15)) && kill $STRESS_PIDS) >/dev/null 2>&1 &
	STRESS_WATCHDOG=$!

	local start=$SECONDS el=0 cur max=-1 died=0 p
	while [ $el -lt "$STRESS_SECONDS" ]; do
		cur=$(thermal_level)
		[ "$cur" -gt "$max" ] && max=$cur
		printf '\r  ⏱  zbývá %s   tepelný tlak: %s   (max: %s)        ' \
			"$(fmt_dur $((STRESS_SECONDS - el)))" "$(level_name "$cur")" "$(level_name "$max")"
		sleep 1
		el=$((SECONDS - start))
	done
	printf '\r  ⏱  hotovo%60s\n' ""

	for p in $STRESS_PIDS; do
		kill -0 "$p" 2>/dev/null || died=$((died + 1))
	done
	stop_stress

	# Výsledky z powermetrics (pokud běžel se sudo)
	local pm_level="" cpu_power fan
	if [ "$use_pm" = 1 ] && [ -s "$WORKDIR/powermetrics.txt" ]; then
		local lv idx
		while IFS= read -r lv; do
			[ -n "$lv" ] || continue
			idx=0
			for p in $THERMAL_NAMES; do
				[ "$p" = "$lv" ] && [ $idx -gt "$max" ] && max=$idx
				idx=$((idx + 1))
			done
			pm_level="$pm_level${pm_level:+, }$lv"
		done <<EOF
$(awk -F": " "/pressure level/ {print \$2}" "$WORKDIR/powermetrics.txt" | sort -u)
EOF
		cpu_power=$(awk '/^CPU Power:/ {gsub(/[^0-9]/, "", $3); if ($3 > m) m = $3} END {if (m) printf "%.1f W", m / 1000}' "$WORKDIR/powermetrics.txt")
		fan=$(awk '/^Fan:/ {print $2; exit}' "$WORKDIR/powermetrics.txt")
		[ -n "$pm_level" ] && kv "powermetrics – úrovně" "$pm_level"
		[ -n "$cpu_power" ] && kv "Max. příkon CPU" "$cpu_power"
		[ -n "$fan" ] && kv "Ventilátor" "$fan rpm"
	elif [ "$use_pm" = 0 ]; then
		local therm
		therm=$(pmset -g therm 2>/dev/null | grep -E 'CPU_Speed_Limit|Scheduler_Limit' | tr -s ' \t' ' ' | tr '\n' ';')
		[ -n "$therm" ] && kv "pmset -g therm" "$therm"
	fi

	local mx
	mx=$(level_name "$max")
	if [ "$max" -lt 0 ]; then
		record skip "Tepelný tlak při zátěži" "nelze zjistit"
	elif [ "$max" -le 1 ]; then
		record ok "Tepelný tlak při zátěži" "max. $mx"
	elif [ "$max" -eq 2 ]; then
		local extra=""
		case "$MODEL_NAME" in *Air*) extra=" (model bez ventilátoru – při plné zátěži je zvýšený tlak běžný)" ;; esac
		record warn "Tepelný tlak při zátěži" "max. $mx$extra"
	else
		record err "Tepelný tlak při zátěži" "max. $mx"
	fi

	if [ "$died" -eq 0 ]; then
		record ok "Stabilita při zátěži" "$n vláken běželo $(fmt_dur "$STRESS_SECONDS") bez přerušení"
	else
		record err "Stabilita při zátěži" "$died z $n procesů zátěže skončilo předčasně"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Vizuální kontrola a Apple Diagnostics
# ---------------------------------------------------------------------------

physical_checklist() {
	section "Vizuální a mechanická kontrola"
	local items="Šasi: promáčkliny, praskliny, ohnuté rohy
Šasi leží na rovném stole rovně, neviklá se
Pant: displej drží v libovolném úhlu, bez vůle a skřípání
Šroubky na spodním krytu: neporušené hlavy (stopy po otevírání)
Klávesnice a okolí: stopy po tekutině, lepivé klávesy, oxidace v portech
Displej: škrábance, otlaky od klávesnice, odlupující se antireflexní vrstva
Nabíječka a kabel: originální Apple, odpovídající wattáž, bez poškození"
	printf '%s\n' "$items" | while IFS= read -r line; do
		printf '  ☐ %s\n' "$line"
		printf -- '- [ ] %s\n' "$line" >>"$BODY"
	done

	section "Apple Diagnostics (vestavěný hardwarový test)"
	if [ "$IS_ARM" = 1 ]; then
		note 'Mac vypněte → podržte tlačítko napájení, dokud se neobjeví „Načítání možností spuštění“ → stiskněte Cmd+D.'
		printf -- '- Apple Silicon: vypnout → podržet tlačítko napájení → Cmd+D\n' >>"$BODY"
	else
		note "Mac vypněte → zapněte a ihned držte klávesu D, dokud se nespustí Apple Diagnostics."
		printf -- '- Intel: vypnout → zapnout a držet D\n' >>"$BODY"
	fi
	note "Test trvá několik minut; výsledné kódy (např. PPT001) lze dohledat na support.apple.com/HT203747."
}

# ---------------------------------------------------------------------------
# Souhrn a report
# ---------------------------------------------------------------------------

summary_and_report() {
	local n_ok n_warn n_err n_skip
	n_ok=$(grep -c '^ok	' "$RESULTS" | tr -d ' ')
	n_warn=$(grep -c '^warn	' "$RESULTS" | tr -d ' ')
	n_err=$(grep -c '^err	' "$RESULTS" | tr -d ' ')
	n_skip=$(grep -c '^skip	' "$RESULTS" | tr -d ' ')

	# Klíčové údaje v pevném pořadí
	local keys="" k v
	for k in "Kapacita baterie" "Nabití baterie" "Cykly baterie" "Stav SSD" "Hodiny provozu SSD"; do
		v=$(awk -F"\t" -v k="$k" '$1 == k {print $2; exit}' "$KEYS")
		[ -n "$v" ] && keys="$keys$k|$v
"
	done

	section "Souhrn"
	if [ -n "$keys" ]; then
		printf '%s' "$keys" | while IFS='|' read -r k v; do
			[ -n "$k" ] || continue
			printf '  %s%s%s %s\n' "$C_BOLD" "$(pad "$k:" 24)" "$C_RESET" "$v"
		done
		echo
	fi
	printf '  ✅ %sOK: %s%s   ⚠️  %sPozor: %s%s   ❌ %sChyba: %s%s   ⏭️  Přeskočeno: %s\n' \
		"$C_GREEN" "$n_ok" "$C_RESET" "$C_YELLOW" "$n_warn" "$C_RESET" "$C_RED" "$n_err" "$C_RESET" "$n_skip"

	local issues
	issues=$(awk -F'\t' '$1 == "err" {print "❌ " $2 ": " $3}' "$RESULTS"
		awk -F'\t' '$1 == "warn" {print "⚠️  " $2 ": " $3}' "$RESULTS")
	if [ -n "$issues" ]; then
		echo
		printf '%s\n' "$issues" | sed 's/^/  /'
	else
		echo
		note "Žádná položka se stavem Pozor nebo Chyba."
	fi

	local report="$WORKDIR/report.md"
	{
		printf '# Mac Diagnostika – report\n\n'
		printf -- '- Datum: %s\n' "$(date '+%Y-%m-%d %H:%M')"
		printf -- '- Model: %s\n' "${MODEL_NAME:-?}"
		printf -- '- Sériové číslo: %s\n' "${SERIAL:-?}"
		printf -- '- Verze nástroje: %s (%s)\n\n' "$VERSION" "$REPO_URL"
		printf '## Souhrn\n\n'
		printf '%s' "$keys" | while IFS='|' read -r k v; do
			[ -n "$k" ] && printf -- '- **%s:** %s\n' "$k" "$v"
		done
		[ -n "$keys" ] && echo
		printf 'OK: %s · Pozor: %s · Chyba: %s · Přeskočeno: %s\n\n' "$n_ok" "$n_warn" "$n_err" "$n_skip"
		if [ -n "$issues" ]; then
			printf '%s\n' "$issues" | sed 's/^/- /; s/⚠️  /⚠️ /'
		else
			printf 'Žádná položka se stavem Pozor nebo Chyba.\n'
		fi
		cat "$BODY"
	} >"$report"

	echo
	if ask_yn "Zkopírovat report (Markdown) do schránky?" a; then
		if pbcopy <"$report"; then
			note "Report je ve schránce."
		else
			note "Kopírování do schránky se nepodařilo."
		fi
	fi
	if ask_yn "Uložit kopii reportu do /tmp?" n; then
		local out
		out="/tmp/mac-diagnostika-$(date '+%Y%m%d-%H%M%S').md"
		cp "$report" "$out" && note "Uloženo: $out (složka /tmp se při restartu maže)."
	fi
}

# ---------------------------------------------------------------------------
# Hlavní běh
# ---------------------------------------------------------------------------

printf '\n%s%s  Mac Diagnostika %s%s\n' "$C_BOLD" "$C_CYAN" "$VERSION" "$C_RESET"
note "Technická diagnostika hardwaru a systému. Skript pouze čte, nic nemění ani neinstaluje."
if [ "$OPT_QUICK" = 1 ]; then
	note "Režim --quick: jen automatické kontroly."
fi
if [ "$HAVE_TTY" != 1 ]; then
	note "Terminál není k dispozici – interaktivní části se přeskočí."
fi

if [ "$(id -u)" = 0 ]; then
	# Spuštěno jako root – rozšířené kontroly jsou dostupné bez dalšího dotazu.
	[ "$OPT_NO_SUDO" = 0 ] && HAVE_SUDO=1
elif [ "$OPT_NO_SUDO" = 0 ] && [ "$HAVE_TTY" = 1 ]; then
	echo
	note "Některé kontroly (záznam DEP, systémové profily, powermetrics) vyžadují heslo správce."
	if ask_yn "Použít sudo pro rozšířené kontroly?" n; then
		if sudo -v <&3; then
			HAVE_SUDO=1
		else
			note "sudo se nepodařilo – pokračuji bez něj."
		fi
	fi
fi

run_check check_hardware
run_check check_security
run_check check_battery
run_check check_ssd
run_check check_panics
run_check check_peripherals
run_check check_system_info
run_check show_serial

if [ "$OPT_QUICK" = 0 ]; then
	stress_test
	run_check physical_checklist
fi

summary_and_report
echo
