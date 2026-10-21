#!/bin/bash
#
# Mac Diagnostika – technická diagnostika Macu z terminálu.
# https://github.com/vojnvk/maccheck
#
# Skript na systému nic nemění: pouze čte informace. Dočasné soubory
# (testovací HTML stránka, zvuky, rozpracovaný report) ukládá do vlastní
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

usage() {
	cat <<'EOF'
Mac Diagnostika – technická kontrola stavu Macu (pouze čte, nic nemění)

Použití:
  bash <(curl -fsSL https://raw.githubusercontent.com/vojnvk/maccheck/main/maccheck.sh) [přepínače]
  bash maccheck.sh [přepínače]

Přepínače:
  --quick            jen automatické kontroly (bez ručních testů a zátěžového testu)
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
: >"$RESULTS"
: >"$BODY"

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

# ask_test "Otázka" [o] – nastaví ANS na a|n|p (s volbou o i „opakovat“).
ANS=""
ask_test() {
	local q=$1 rep=${2:-} hint="[a/n/p]" ans
	[ -n "$rep" ] && hint="[a/n/p/o]"
	if [ "$HAVE_TTY" != 1 ]; then
		ANS=p
		return 0
	fi
	while :; do
		printf '  %s%s%s %s ' "$C_BOLD" "$q" "$C_RESET" "$hint"
		ans=""
		if ! IFS= read -r ans <&3; then
			echo
			ANS=p
			return 0
		fi
		case "$(lower "$ans")" in
		a | ano | y) ANS=a && return 0 ;;
		n | ne) ANS=n && return 0 ;;
		p | '') ANS=p && return 0 ;;
		o)
			if [ -n "$rep" ]; then
				ANS=o
				return 0
			fi
			;;
		esac
		if [ -n "$rep" ]; then
			echo "  a = funguje, n = nefunguje, p = přeskočit, o = opakovat"
		else
			echo "  a = funguje, n = nefunguje, p = přeskočit"
		fi
	done
}

wait_enter() {
	[ "$HAVE_TTY" = 1 ] || return 0
	printf '  %s%s%s' "$C_DIM" "${1:-Pokračujte klávesou Enter…}" "$C_RESET"
	IFS= read -r _ <&3 || echo
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
		record ok "Zdraví baterie" "macOS uvádí Maximum Capacity $maxcap (výpočet z ioreg není k dispozici)"
	else
		record skip "Zdraví baterie" "údaje o kapacitě nejsou k dispozici"
	fi

	local charge
	charge=$(spval "State of Charge (%)" "$bat_block")
	[ -n "$charge" ] && kv "Aktuální nabití" "$charge %"

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

	if command -v smartctl >/dev/null 2>&1; then
		local out used units tb spare
		out=$(smartctl -a disk0 2>/dev/null)
		[ -n "$out" ] || { [ "$HAVE_SUDO" = 1 ] && out=$(sudo -n smartctl -a disk0 2>/dev/null); }
		used=$(printf '%s\n' "$out" | awk -F: '/Percentage Used/ {gsub(/[ %]/, "", $2); print $2; exit}')
		units=$(printf '%s\n' "$out" | awk -F: '/Data Units Written/ {print $2; exit}' | sed 's/\[.*//; s/[ ,.]//g')
		spare=$(printf '%s\n' "$out" | awk -F: '/^Available Spare:/ {gsub(/ /, "", $2); print $2; exit}')
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
		[ -n "$used$units" ] || record skip "Opotřebení SSD (smartctl)" "smartctl nevrátil NVMe údaje"
	else
		record skip "Opotřebení SSD" "smartctl není nainstalován (neinstaluje se)"
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
# Ruční testy
# ---------------------------------------------------------------------------

# manual "Položka" "Otázka" – zeptá se na výsledek a zapíše ho.
manual() {
	ask_test "$2"
	case "$ANS" in
	a) record ok "$1" "funguje (ověřeno ručně)" ;;
	n) record err "$1" "nefunguje (ověřeno ručně)" ;;
	*) record skip "$1" "netestováno" ;;
	esac
}

le16() {
	# shellcheck disable=SC2059
	printf "\\$(printf '%03o' $(($1 & 255)))\\$(printf '%03o' $((($1 >> 8) & 255)))"
}

le32() {
	le16 $(($1 & 65535))
	le16 $((($1 >> 16) & 65535))
}

# Vytvoří 8bit stereo WAV s tónem 500 Hz jen v jednom kanálu (left|right).
make_tone() {
	local file=$1 side=$2 rate=8000 frames=9600 period="" chunk="" s i
	# Jedna perioda sinusovky (16 vzorků), bez nulových bajtů.
	for s in 200 227 252 267 274 267 252 227 200 151 126 111 104 111 126 151; do
		if [ "$side" = left ]; then period="$period\\$s\\200"; else period="$period\\200\\$s"; fi
	done
	i=0
	while [ $i -lt 60 ]; do
		chunk="$chunk$period"
		i=$((i + 1))
	done
	{
		printf 'RIFF'
		le32 $((36 + frames * 2))
		printf 'WAVEfmt '
		le32 16
		le16 1
		le16 2
		le32 $rate
		le32 $((rate * 2))
		le16 2
		le16 8
		printf 'data'
		le32 $((frames * 2))
		i=0
		while [ $i -lt 10 ]; do
			# shellcheck disable=SC2059
			printf "$chunk"
			i=$((i + 1))
		done
	} >"$file"
}

test_speakers() {
	local vol muted
	vol=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)
	muted=$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)
	echo
	note "Test reproduktorů – odpojte sluchátka/AirPods, aby zvuk šel do vestavěných reproduktorů."
	if [ "$muted" = "true" ]; then
		note "Zvuk je ztlumený – zapněte ho klávesou F10/F12."
	elif [ -n "$vol" ]; then
		note "Aktuální hlasitost: $vol % (případně ji zvyšte klávesou F12)."
	fi
	make_tone "$WORKDIR/left.wav" left
	make_tone "$WORKDIR/right.wav" right
	local side label file
	for side in left right; do
		if [ "$side" = left ]; then
			label="Levý reproduktor"
			file="$WORKDIR/left.wav"
		else
			label="Pravý reproduktor"
			file="$WORKDIR/right.wav"
		fi
		while :; do
			printf '  ▶ Přehrávám tón v kanálu: %s%s%s\n' "$C_BOLD" "$label" "$C_RESET"
			afplay "$file" 2>/dev/null
			ask_test "Ozval se tón jen z této strany a čistě (bez praskání)?" o
			[ "$ANS" = o ] || break
		done
		case "$ANS" in
		a) record ok "$label" "funguje (ověřeno ručně)" ;;
		n) record err "$label" "nefunguje (ověřeno ručně)" ;;
		*) record skip "$label" "netestováno" ;;
		esac
	done
}

# Otevře aplikaci a po testu ji zavře, ale jen pokud předtím neběžela.
with_app() {
	local app=$1 was_running=0
	pgrep -xq "$app" && was_running=1
	shift
	"$@"
	if [ "$was_running" = 0 ]; then
		osascript -e "tell application \"$app\" to quit saving no" >/dev/null 2>&1
	fi
}

camera_step() {
	open -a "Photo Booth" 2>/dev/null || {
		record skip "Kamera (obraz)" "Photo Booth nelze otevřít"
		return 0
	}
	note "Otevřel se Photo Booth – zkontrolujte obraz kamery (ostrost, barvy, kontrolka vedle kamery)."
	manual "Kamera (obraz)" "Kamera ukazuje čistý obraz a svítí zelená kontrolka?"
}

mic_step() {
	if osascript -e 'tell application "QuickTime Player" to activate' \
		-e 'tell application "QuickTime Player" to new audio recording' >/dev/null 2>&1; then
		note "V QuickTime se otevřel záznam zvuku (nic se nenahrává ani neukládá)."
		note "Mluvte do Macu a sledujte ukazatel hlasitosti v okně."
	else
		note "QuickTime nelze otevřít – mikrofon můžete vyzkoušet nahráním videa v Photo Booth."
	fi
	manual "Mikrofon (záznam)" "Ukazatel hlasitosti reaguje na hlas?"
}

ports_checklist() {
	local tbports
	tbports=$(system_profiler SPThunderboltDataType 2>/dev/null | grep -c 'Receptacle:' | tr -d ' ')
	echo
	note "Porty – vyzkoušejte každý port (p = model port nemá / netestováno):"
	note "  • USB‑C / Thunderbolt: nabíječka nebo flash disk v každém portu${tbports:+ (nalezeno portů: $tbports)}"
	note "  • MagSafe: nabíječka se uchytí magnetem a kontrolka svítí"
	note "  • HDMI: obraz na externím monitoru/TV"
	note "  • Čtečka SD karet: karta se připojí ve Finderu"
	note "  • 3,5mm jack: zvuk ve sluchátkách"
	manual "Porty USB‑C / Thunderbolt" "Všechny USB‑C / Thunderbolt porty fungují?"
	manual "Port MagSafe" "MagSafe nabíjí?"
	manual "Port HDMI" "HDMI zobrazuje obraz?"
	manual "Čtečka SD karet" "SD karta se načte?"
	manual "Konektor 3,5 mm" "Sluchátka v jacku hrají?"
}

write_html() {
	cat >"$1" <<'HTML'
<!doctype html>
<html lang="cs">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mac Diagnostika – ruční testy</title>
<style>
:root { --bg:#f5f5f7; --fg:#1d1d1f; --muted:#6e6e73; --card:#fff; --line:#d2d2d7; --key:#fbfbfd; --ok:#34c759; --accent:#0071e3; }
@media (prefers-color-scheme: dark) { :root { --bg:#161617; --fg:#f5f5f7; --muted:#a1a1a6; --card:#232325; --line:#3a3a3c; --key:#2c2c2e; --accent:#2997ff; } }
* { box-sizing:border-box; }
body { margin:0; font:15px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; background:var(--bg); color:var(--fg); -webkit-user-select:none; user-select:none; }
header { padding:20px 24px 0; max-width:1100px; margin:0 auto; }
h1 { font-size:22px; margin:0 0 4px; }
header p { margin:0; color:var(--muted); }
nav { display:flex; gap:8px; padding:16px 24px; max-width:1100px; margin:0 auto; flex-wrap:wrap; }
nav button { font:inherit; border:1px solid var(--line); background:var(--card); color:var(--fg); padding:8px 16px; border-radius:999px; cursor:pointer; }
nav button.active { background:var(--accent); border-color:var(--accent); color:#fff; }
main { max-width:1100px; margin:0 auto; padding:0 24px 32px; }
section { display:none; background:var(--card); border:1px solid var(--line); border-radius:14px; padding:20px; }
section.active { display:block; }
h2 { margin:0 0 6px; font-size:18px; }
.hint { color:var(--muted); margin:0 0 14px; }
.btn { font:inherit; background:var(--accent); color:#fff; border:0; border-radius:8px; padding:10px 18px; cursor:pointer; }
.btn.secondary { background:transparent; color:var(--accent); border:1px solid var(--line); }
#screen { position:fixed; inset:0; display:none; cursor:none; z-index:10; }
#screen.on { display:block; }
#screenLabel { position:absolute; top:24px; left:50%; transform:translateX(-50%); padding:6px 14px; border-radius:8px; background:rgba(0,0,0,.55); color:#fff; font-size:14px; transition:opacity .6s; }
.kb { display:flex; flex-direction:column; gap:6px; margin-top:8px; overflow-x:auto; padding-bottom:4px; }
.row { display:flex; gap:6px; }
.k { flex:0 0 auto; height:46px; min-width:46px; border:1px solid var(--line); border-radius:7px; background:var(--key); display:flex; align-items:flex-end; justify-content:flex-start; padding:4px 6px; font-size:12px; color:var(--muted); transition:background .1s; }
.row.f .k { height:30px; }
.k.down { background:var(--ok); color:#fff; border-color:var(--ok); }
.k.done { background:color-mix(in srgb, var(--ok) 70%, var(--key)); color:#fff; border-color:var(--ok); }
.k.opt { border-style:dashed; }
.k.na { opacity:.35; }
.arrows { display:flex; flex-direction:column; gap:2px; }
.arrows .k { height:22px; }
.stats { display:flex; gap:20px; flex-wrap:wrap; margin:12px 0; color:var(--muted); }
.stats b { color:var(--fg); }
#pad { width:100%; height:60vh; min-height:320px; border:1px solid var(--line); border-radius:12px; background:var(--key); touch-action:none; display:block; }
ul { margin:8px 0 0; padding-left:20px; }
</style>
</head>
<body>
<header>
  <h1>Mac Diagnostika – ruční testy</h1>
  <p>Stránka běží lokálně a nic neodesílá. Výsledky zadávejte v terminálu.</p>
</header>
<nav>
  <button data-tab="display" class="active">1. Displej</button>
  <button data-tab="keyboard">2. Klávesnice</button>
  <button data-tab="trackpad">3. Trackpad</button>
</nav>
<main>
  <section id="display" class="active">
    <h2>Test displeje</h2>
    <p class="hint">Celoobrazovkové barvy pro hledání vadných pixelů, skvrn, pruhů a nerovnoměrného podsvícení. Další barva: klik, mezerník nebo šipka. Konec: Esc.</p>
    <button class="btn" id="startDisplay">Spustit test na celou obrazovku</button>
    <ul>
      <li><b>Bílá</b> – skvrny, žluté okraje, tmavé (mrtvé) pixely</li>
      <li><b>Černá</b> – svítící pixely, prosvítání podsvícení v rozích</li>
      <li><b>Červená, zelená, modrá</b> – subpixely, které nesvítí nebo svítí stále</li>
      <li><b>Šedá a přechod</b> – pruhy, stíny, nerovnoměrnost</li>
    </ul>
  </section>

  <section id="keyboard">
    <h2>Test klávesnice</h2>
    <p class="hint">Stiskněte postupně všechny klávesy – vyzkoušené zezelenají. F1–F12 držte spolu s klávesou fn. Klávesy fn/🌐 a Touch ID prohlížeč nezachytí. Pozor: Cmd+W a Cmd+Q zavřou okno.</p>
    <div class="stats"><span>Otestováno: <b id="kbCount">0</b> / <b id="kbTotal">0</b></span><span>Poslední klávesa: <b id="kbLast">–</b></span><button class="btn secondary" id="kbReset">Vynulovat</button></div>
    <div class="kb" id="kb"></div>
  </section>

  <section id="trackpad">
    <h2>Test trackpadu</h2>
    <p class="hint">Přejeďte prstem po celé ploše trackpadu – stopa by měla být plynulá a bez skoků, i v rozích. Vyzkoušejte klik v různých místech, pravé kliknutí (dvěma prsty), posun dvěma prsty, zoom a silné stisknutí (Force Touch).</p>
    <div class="stats">
      <span>Kliknutí: <b id="tpClick">0</b></span>
      <span>Pravé kliknutí: <b id="tpRight">0</b></span>
      <span>Posun dvěma prsty: <b id="tpScroll">0</b></span>
      <span>Zoom: <b id="tpZoom">0</b></span>
      <span>Force Touch: <b id="tpForce">0</b></span>
      <button class="btn secondary" id="tpClear">Vymazat</button>
    </div>
    <canvas id="pad"></canvas>
  </section>
</main>
<div id="screen"><div id="screenLabel"></div></div>
<script>
(function () {
  // Záložky
  var tabs = document.querySelectorAll('nav button');
  function showTab(id) {
    tabs.forEach(function (b) { b.classList.toggle('active', b.dataset.tab === id); });
    document.querySelectorAll('section').forEach(function (s) { s.classList.toggle('active', s.id === id); });
    if (id === 'trackpad') resizePad();
  }
  tabs.forEach(function (b) { b.addEventListener('click', function () { showTab(b.dataset.tab); b.blur(); }); });
  function activeTab() { return document.querySelector('section.active').id; }

  // Displej
  var colors = [
    ['#ffffff', 'Bílá'], ['#000000', 'Černá'], ['#ff0000', 'Červená'], ['#00ff00', 'Zelená'],
    ['#0000ff', 'Modrá'], ['#808080', 'Šedá'], ['linear-gradient(90deg,#000,#fff)', 'Šedý přechod']
  ];
  var screen = document.getElementById('screen'), label = document.getElementById('screenLabel');
  var ci = 0, labelTimer = null;
  function paint() {
    screen.style.background = colors[ci][0];
    label.textContent = (ci + 1) + ' / ' + colors.length + ' – ' + colors[ci][1] + ' (Esc = konec)';
    label.style.opacity = 1;
    clearTimeout(labelTimer);
    labelTimer = setTimeout(function () { label.style.opacity = 0; }, 1500);
  }
  function step(d) { ci = (ci + d + colors.length) % colors.length; paint(); }
  function closeScreen() {
    screen.classList.remove('on');
    if (document.fullscreenElement && document.exitFullscreen) document.exitFullscreen();
    else if (document.webkitFullscreenElement && document.webkitExitFullscreen) document.webkitExitFullscreen();
  }
  document.getElementById('startDisplay').addEventListener('click', function () {
    ci = 0; screen.classList.add('on'); paint();
    if (screen.requestFullscreen) screen.requestFullscreen().catch(function () {});
    else if (screen.webkitRequestFullscreen) screen.webkitRequestFullscreen();
  });
  screen.addEventListener('click', function () { step(1); });
  function fsChange() { if (!document.fullscreenElement && !document.webkitFullscreenElement) screen.classList.remove('on'); }
  document.addEventListener('fullscreenchange', fsChange);
  document.addEventListener('webkitfullscreenchange', fsChange);

  // Klávesnice (fyzické rozložení MacBooku; popisky se přepíšou skutečně zadaným znakem)
  // [kód, popisek, šířka, příznak] – příznak: o = jen některá rozložení, n = nelze zachytit
  var rows = [
    { cls: 'f', keys: [['Escape','esc',1.5],['F1','F1'],['F2','F2'],['F3','F3'],['F4','F4'],['F5','F5'],['F6','F6'],['F7','F7'],['F8','F8'],['F9','F9'],['F10','F10'],['F11','F11'],['F12','F12'],['TouchID','●',1,'n']] },
    { keys: [['Backquote','`'],['Digit1','1'],['Digit2','2'],['Digit3','3'],['Digit4','4'],['Digit5','5'],['Digit6','6'],['Digit7','7'],['Digit8','8'],['Digit9','9'],['Digit0','0'],['Minus','-'],['Equal','='],['Backspace','delete',1.5]] },
    { keys: [['Tab','tab',1.5],['KeyQ','Q'],['KeyW','W'],['KeyE','E'],['KeyR','R'],['KeyT','T'],['KeyY','Y'],['KeyU','U'],['KeyI','I'],['KeyO','O'],['KeyP','P'],['BracketLeft','['],['BracketRight',']'],['Backslash','\\']] },
    { keys: [['CapsLock','caps lock',1.8],['KeyA','A'],['KeyS','S'],['KeyD','D'],['KeyF','F'],['KeyG','G'],['KeyH','H'],['KeyJ','J'],['KeyK','K'],['KeyL','L'],['Semicolon',';'],['Quote',"'"],['Enter','return',1.7]] },
    { keys: [['ShiftLeft','shift',1.3],['IntlBackslash','§',1,'o'],['KeyZ','Z'],['KeyX','X'],['KeyC','C'],['KeyV','V'],['KeyB','B'],['KeyN','N'],['KeyM','M'],['Comma',','],['Period','.'],['Slash','/'],['ShiftRight','shift',2.3]] },
    { keys: [['Fn','fn',1,'n'],['ControlLeft','control'],['AltLeft','option'],['MetaLeft','command',1.3],['Space','',5.6],['MetaRight','command',1.3],['AltRight','option'],['ArrowLeft','←'],['Arrows'],['ArrowRight','→']] }
  ];
  var kb = document.getElementById('kb'), keyEls = {}, pressed = {}, required = 0;
  var U = 46, GAP = 6;
  function mkKey(k) {
    var el = document.createElement('div');
    el.className = 'k' + (k[3] === 'o' ? ' opt' : '') + (k[3] === 'n' ? ' na' : '');
    var w = k[2] || 1;
    el.style.width = (U * w + GAP * (w - 1)) + 'px';
    el.textContent = k[1];
    if (k[3] === 'o') el.title = 'Jen na klávesnici s ISO rozložením';
    keyEls[k[0]] = el;
    if (!k[3]) required++;
    return el;
  }
  rows.forEach(function (r) {
    var row = document.createElement('div');
    row.className = 'row' + (r.cls ? ' ' + r.cls : '');
    r.keys.forEach(function (k) {
      if (k[0] === 'Arrows') {
        var a = document.createElement('div'); a.className = 'arrows';
        a.appendChild(mkKey(['ArrowUp', '↑'])); a.appendChild(mkKey(['ArrowDown', '↓']));
        row.appendChild(a);
      } else row.appendChild(mkKey(k));
    });
    kb.appendChild(row);
  });
  document.getElementById('kbTotal').textContent = required;
  function updateCount() {
    var n = 0;
    for (var c in pressed) if (keyEls[c] && keyEls[c].className.indexOf(' opt') < 0 && keyEls[c].className.indexOf(' na') < 0) n++;
    document.getElementById('kbCount').textContent = n;
  }
  function keyName(e) {
    if (e.key === ' ') return 'mezerník';
    return e.key.length === 1 ? e.key.toUpperCase() : e.key;
  }
  document.addEventListener('keydown', function (e) {
    if (screen.classList.contains('on')) {
      if (e.key === 'Escape') closeScreen();
      else if (e.key === ' ' || e.key === 'ArrowRight' || e.key === 'ArrowDown' || e.key === 'Enter') step(1);
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') step(-1);
      e.preventDefault();
      return;
    }
    if (activeTab() !== 'keyboard') return;
    e.preventDefault();
    var el = keyEls[e.code];
    document.getElementById('kbLast').textContent = keyName(e) + ' (' + e.code + ')';
    if (!el) return;
    if (e.key && e.key.length === 1 && e.key !== ' ') el.textContent = e.key.toUpperCase();
    el.classList.add('down', 'done');
    pressed[e.code] = true;
    updateCount();
    if (e.code === 'CapsLock') setTimeout(function () { el.classList.remove('down'); }, 200);
  });
  document.addEventListener('keyup', function (e) {
    var el = keyEls[e.code];
    if (el) {
      el.classList.remove('down');
      if (e.code === 'CapsLock') { el.classList.add('done'); pressed[e.code] = true; updateCount(); }
    }
    // Při držení Cmd macOS neposílá keyup ostatních kláves.
    if (e.key === 'Meta') Object.keys(keyEls).forEach(function (c) { keyEls[c].classList.remove('down'); });
  });
  document.getElementById('kbReset').addEventListener('click', function (e) {
    pressed = {};
    Object.keys(keyEls).forEach(function (c) { keyEls[c].classList.remove('down', 'done'); });
    updateCount();
    e.target.blur();
  });

  // Trackpad
  var pad = document.getElementById('pad'), ctx = pad.getContext('2d'), last = null, hue = 200;
  var counts = { tpClick: 0, tpRight: 0, tpScroll: 0, tpZoom: 0, tpForce: 0 };
  function bump(id) { counts[id]++; document.getElementById(id).textContent = counts[id]; }
  function resizePad() {
    var r = pad.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    if (!r.width) return;
    pad.width = r.width * dpr; pad.height = r.height * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    last = null;
  }
  window.addEventListener('resize', resizePad);
  function pos(e) { var r = pad.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }
  pad.addEventListener('pointermove', function (e) {
    var p = pos(e);
    if (last) {
      hue = (hue + 0.6) % 360;
      ctx.strokeStyle = e.buttons ? '#ff3b30' : 'hsl(' + hue + ',80%,55%)';
      ctx.lineWidth = e.buttons ? 6 : 3;
      ctx.beginPath(); ctx.moveTo(last.x, last.y); ctx.lineTo(p.x, p.y); ctx.stroke();
    }
    last = p;
  });
  pad.addEventListener('pointerleave', function () { last = null; });
  pad.addEventListener('click', function (e) {
    var p = pos(e);
    ctx.fillStyle = '#ff3b30'; ctx.beginPath(); ctx.arc(p.x, p.y, 7, 0, 6.3); ctx.fill();
    bump('tpClick');
  });
  pad.addEventListener('contextmenu', function (e) {
    e.preventDefault();
    var p = pos(e);
    ctx.fillStyle = '#0071e3'; ctx.beginPath(); ctx.arc(p.x, p.y, 7, 0, 6.3); ctx.fill();
    bump('tpRight');
  });
  var scrollTimer = null;
  pad.addEventListener('wheel', function (e) {
    e.preventDefault();
    if (e.ctrlKey) { if (!scrollTimer) bump('tpZoom'); }
    else if (!scrollTimer) bump('tpScroll');
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(function () { scrollTimer = null; }, 300);
  }, { passive: false });
  pad.addEventListener('gesturestart', function (e) { e.preventDefault(); bump('tpZoom'); });
  pad.addEventListener('webkitmouseforcedown', function () { bump('tpForce'); });
  document.getElementById('tpClear').addEventListener('click', function (e) {
    ctx.clearRect(0, 0, pad.width, pad.height);
    for (var k in counts) { counts[k] = 0; document.getElementById(k).textContent = 0; }
    e.target.blur();
  });
})();
</script>
</body>
</html>
HTML
}

interactive_tests() {
	section "Ruční testy"
	note "Průvodce otevře v Safari lokální testovací stránku, přehraje zvuk a otevře Photo Booth."
	note "U každého testu odpovězte: a = funguje, n = nefunguje, p = přeskočit."
	if ! ask_yn "Spustit ruční testy?" a; then
		record skip "Ruční testy" "nespuštěny"
		return 0
	fi

	local html="$WORKDIR/test.html"
	write_html "$html"
	if open -a Safari "$html" 2>/dev/null || open "$html" 2>/dev/null; then
		echo
		note 'V Safari se otevřela stránka „Mac Diagnostika – ruční testy“.'
		note "1) Záložka Displej: spusťte test na celou obrazovku a projděte všechny barvy."
		manual "Displej" "Displej je bez vadných pixelů, skvrn a pruhů?"
		note "2) Záložka Klávesnice: stiskněte všechny klávesy."
		manual "Klávesnice" "Všechny klávesy reagují?"
		note "3) Záložka Trackpad: přejeďte celou plochu, klikněte v rozích, zkuste gesta."
		manual "Trackpad" "Trackpad reaguje plynule na celé ploše a klik funguje všude?"
	else
		record skip "Displej, klávesnice, trackpad" "testovací stránku nelze otevřít"
	fi

	test_speakers
	echo
	with_app "Photo Booth" camera_step
	echo
	with_app "QuickTime Player" mic_step
	ports_checklist
	return 0
}

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

	section "Souhrn"
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
	run_check interactive_tests
	run_check physical_checklist
fi

summary_and_report
echo
