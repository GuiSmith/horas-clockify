#!/usr/bin/env bash
#
# horas — relatório de horas do Clockify por mês de faturamento.
# Regras de negócio completas: ver README.md.

set -euo pipefail
# Faz erros dentro de $(...) também encerrarem o script.
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly ENV_FILE="$SCRIPT_DIR/.env"

readonly CLOCKIFY_API="https://api.clockify.me/api/v1"
readonly HOLIDAYS_API="https://brasilapi.com.br/api/feriados/v1"
readonly HTTP_TIMEOUT_SECONDS=15
readonly PAGE_SIZE=200

readonly MIN_BAR_WIDTH=10
readonly HALF_HOUR_MINUTES=30
readonly MONTH_NAMES=(Janeiro Fevereiro Março Abril Maio Junho Julho Agosto Setembro Outubro Novembro Dezembro)

# Feriados por data (AAAA-MM-DD => nome) e anos já consultados (ano => ok|falhou).
declare -A HOLIDAYS=()
declare -A HOLIDAY_YEARS=()

# Dias de cada período já calculado (AAAA-MM-01 => linhas "data dia_da_semana segundos").
declare -A PERIOD_CACHE=()

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

die() {
  printf '%serro:%s %s\n' "${RED:-}" "${RESET:-}" "$*" >&2
  exit 1
}

setup_colors() {
  if [[ -t 1 ]]; then
    GREEN=$'\e[32m' RED=$'\e[31m' YELLOW=$'\e[33m' GRAY=$'\e[90m' BOLD=$'\e[1m' RESET=$'\e[0m'
  else
    GREEN='' RED='' YELLOW='' GRAY='' BOLD='' RESET=''
  fi
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || die "comando '$cmd' não encontrado"
  done
}

# Converte horas decimais ("7.5") em minutos inteiros (450).
hours_to_minutes() {
  awk -v hours="$1" 'BEGIN { printf "%d", hours * 60 + 0.5 }'
}

# Formata minutos como HH:MM; o 2º argumento define os dígitos das horas.
format_hhmm() {
  local minutes=$1 hour_digits=${2:-2}
  printf '%0*d:%02d' "$hour_digits" $((minutes / 60)) $((minutes % 60))
}

# Repete um caractere N vezes.
repeat_char() {
  local char=$1 count=$2 spaces
  printf -v spaces '%*s' "$count" ''
  printf '%s' "${spaces// /$char}"
}

clear_screen() {
  printf '\e[H\e[2J\e[3J'
}

iso_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

# ---------------------------------------------------------------------------
# Configuração
# ---------------------------------------------------------------------------

require_var() {
  [[ -n ${!1:-} ]] || die "variável $1 não definida no .env"
}

require_positive_number() {
  local name=$1
  require_var "$name"
  if [[ ! ${!name} =~ ^[0-9]+([.][0-9]+)?$ ]] || (($(hours_to_minutes "${!name}") <= 0)); then
    die "$name deve ser um número maior que zero (decimal com ponto)"
  fi
}

load_config() {
  [[ -f $ENV_FILE ]] || die "arquivo .env não encontrado (copie o .env.example para .env)"
  # shellcheck source=/dev/null
  source "$ENV_FILE"

  require_var CLOCKIFY_API_KEY
  require_var CLOCKIFY_WORKSPACE_ID
  require_positive_number HORAS_MAX_MES
  require_positive_number HORAS_META_DIA

  if [[ ! ${FATURAMENTO_DIA_INICIAL:-} =~ ^[0-9]+$ ]] ||
    ((10#$FATURAMENTO_DIA_INICIAL < 1 || 10#$FATURAMENTO_DIA_INICIAL > 28)); then
    die "FATURAMENTO_DIA_INICIAL deve ser um inteiro de 1 a 28"
  fi

  START_DAY=$((10#$FATURAMENTO_DIA_INICIAL))
  MAX_MONTH_MINUTES=$(hours_to_minutes "$HORAS_MAX_MES")
  DAILY_GOAL_MINUTES=$(hours_to_minutes "$HORAS_META_DIA")
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# GET que imprime o corpo da resposta. Os headers vão por stdin para a
# API key não aparecer na lista de processos.
http_get() {
  local url=$1 headers=${2:-} response status
  response=$(curl -sS --max-time "$HTTP_TIMEOUT_SECONDS" -H @- -w '\n%{http_code}' "$url" <<<"$headers") || return 1
  status=${response##*$'\n'}
  if [[ $status != 2?? ]]; then
    printf 'HTTP %s em %s\n' "$status" "${url%%\?*}" >&2
    return 1
  fi
  printf '%s\n' "${response%$'\n'*}"
}

clockify_get() {
  http_get "$CLOCKIFY_API$1" "X-Api-Key: $CLOCKIFY_API_KEY" ||
    die "falha ao consultar o Clockify (confira CLOCKIFY_API_KEY, CLOCKIFY_WORKSPACE_ID e a conexão)"
}

# ---------------------------------------------------------------------------
# Dados: usuário, workspace, feriados e entradas de horas
# ---------------------------------------------------------------------------

# Define USER_ID, USER_NAME e passa a usar o fuso horário do perfil do Clockify.
load_user() {
  local user timezone
  user=$(clockify_get "/user")
  USER_ID=$(jq -r '.id' <<<"$user")
  USER_NAME=$(jq -r '.name' <<<"$user")
  timezone=$(jq -r '.settings.timeZone // empty' <<<"$user")
  if [[ -n $timezone ]]; then
    export TZ=$timezone
  fi
}

load_workspace_name() {
  WORKSPACE_NAME=$(clockify_get "/workspaces/$CLOCKIFY_WORKSPACE_ID" | jq -r '.name')
}

# Carrega os feriados nacionais do ano uma única vez. Falha não interrompe o
# script: o ano fica marcado e o relatório avisa no rodapé.
load_holidays() {
  local year=$1 json date name
  if [[ -n ${HOLIDAY_YEARS[$year]:-} ]]; then
    return
  fi

  if json=$(http_get "$HOLIDAYS_API/$year" 2>/dev/null) &&
    jq -e "type == \"array\"" <<<"$json" >/dev/null 2>&1; then
    while IFS=$'\t' read -r date name; do
      HOLIDAYS[$date]=$name
    done < <(jq -r '.[] | [.date, .name] | @tsv' <<<"$json")
    HOLIDAY_YEARS[$year]=ok
  else
    HOLIDAY_YEARS[$year]=falhou
  fi
}

# Imprime "início fim" (epoch) de cada entrada de horas no intervalo.
# Timer em andamento (sem fim) conta até agora.
fetch_entries() {
  local from_epoch=$1 to_epoch=$2 page=1 now json count
  local path="/workspaces/$CLOCKIFY_WORKSPACE_ID/user/$USER_ID/time-entries"
  local query
  query="start=$(iso_utc "$from_epoch")&end=$(iso_utc "$to_epoch")&page-size=$PAGE_SIZE"
  now=$(date +%s)

  while true; do
    json=$(clockify_get "$path?$query&page=$page")
    if ! jq -e 'type == "array"' <<<"$json" >/dev/null 2>&1; then
      die "resposta inesperada do Clockify ao buscar as entradas de horas"
    fi
    jq -r --argjson now "$now" '
      def to_epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
      .[] | .timeInterval
        | [(.start | to_epoch), (if .end then (.end | to_epoch) else $now end)]
        | @tsv' <<<"$json"

    count=$(jq 'length' <<<"$json")
    if ((count < PAGE_SIZE)); then
      break
    fi
    page=$((page + 1))
  done
}

# ---------------------------------------------------------------------------
# Período de faturamento
# Um período é identificado pelo mês que lhe dá nome, no formato AAAA-MM-01.
# ---------------------------------------------------------------------------

shift_month() {
  date -d "$1 $2 month" +%Y-%m-01
}

current_period_month() {
  local this_month
  this_month=$(date +%Y-%m-01)
  if ((START_DAY > 1 && 10#$(date +%d) >= START_DAY)); then
    shift_month "$this_month" +1
  else
    echo "$this_month"
  fi
}

period_start() {
  local month=$1 previous
  if ((START_DAY == 1)); then
    echo "$month"
  else
    previous=$(shift_month "$month" -1)
    printf '%s-%02d\n' "${previous:0:7}" "$START_DAY"
  fi
}

period_end() {
  date -d "$(period_start "$(shift_month "$1" +1)") -1 day" +%F
}

period_label() {
  local month=$1
  echo "${MONTH_NAMES[10#${month:5:2} - 1]}/${month:0:4}"
}

# Imprime "data dia_da_semana epoch_da_meia_noite" para cada dia do intervalo.
list_days() {
  local day=$1 last=$2
  while [[ ! $day > $last ]]; do
    echo "$day"
    day=$(date -d "$day +1 day" +%F)
  done | date -f - '+%F %u %s'
}

# Calcula os segundos trabalhados em cada dia do período e guarda no cache.
# Entradas que atravessam a meia-noite são divididas entre os dias.
build_period() {
  local month=$1 start end
  start=$(period_start "$month")
  end=$(period_end "$month")
  load_holidays "${start:0:4}"
  load_holidays "${end:0:4}"

  # Atribuição direta (e não "< <(...)") para que um erro aqui encerre o script.
  local days entries
  days=$(list_days "$start" "$end")

  local -a dates=() weekdays=() midnights=() seconds=()
  local date weekday midnight
  while read -r date weekday midnight; do
    dates+=("$date")
    weekdays+=("$weekday")
    midnights+=("$midnight")
    seconds+=(0)
  done <<<"$days"
  midnights+=("$(date -d "$end +1 day" +%s)")

  # Busca desde um dia antes para pegar entradas iniciadas antes do período.
  # Sem "|| ...": isso desligaria o set -e dentro de fetch_entries.
  entries=$(fetch_entries $((midnights[0] - 86400)) "${midnights[-1]}")

  local entry_start entry_end i from to
  while read -r entry_start entry_end; do
    if [[ -z $entry_start ]]; then
      continue
    fi
    for i in "${!dates[@]}"; do
      from=$((entry_start > midnights[i] ? entry_start : midnights[i]))
      to=$((entry_end < midnights[i + 1] ? entry_end : midnights[i + 1]))
      if ((to > from)); then
        seconds[i]=$((seconds[i] + to - from))
      fi
    done
  done <<<"$entries"

  PERIOD_CACHE[$month]=$(
    for i in "${!dates[@]}"; do
      echo "${dates[i]} ${weekdays[i]} ${seconds[i]}"
    done
  )
}

is_business_day() {
  local date=$1 weekday=$2
  ((weekday <= 5)) && [[ -z ${HOLIDAYS[$date]:-} ]]
}

non_business_marker() {
  local date=$1 weekday=$2
  if [[ -n ${HOLIDAYS[$date]:-} ]]; then
    echo "(feriado: ${HOLIDAYS[$date]})"
  elif ((weekday == 6)); then
    echo "(sáb)"
  else
    echo "(dom)"
  fi
}

holidays_unavailable() {
  local month=$1 start end
  start=$(period_start "$month")
  end=$(period_end "$month")
  [[ ${HOLIDAY_YEARS[${start:0:4}]:-} == falhou || ${HOLIDAY_YEARS[${end:0:4}]:-} == falhou ]]
}

# ---------------------------------------------------------------------------
# Renderização
# ---------------------------------------------------------------------------

# Sobra de mais de 30 min além das horas completas ganha um "=" amarelo.
has_half_hour_mark() {
  (($1 % 60 > HALF_HOUR_MINUTES))
}

# Quantidade de "=": uma por hora completa, mais a marca de meia hora.
bar_length() {
  local minutes=$1 length=$(($1 / 60))
  if has_half_hour_mark "$minutes"; then
    length=$((length + 1))
  fi
  echo "$length"
}

render_bar() {
  local minutes=$1 hours_color=$2 width=$3 half_hour=''
  if has_half_hour_mark "$minutes"; then
    half_hour="$YELLOW=$RESET"
  fi
  printf '[%s%s%s%s%*s]' "$hours_color" "$(repeat_char '=' $((minutes / 60)))" "$RESET" \
    "$half_hour" $((width - $(bar_length "$minutes"))) ''
}

render_header() {
  local month=$1
  printf '%sUsuário:%s    %s\n' "$BOLD" "$RESET" "$USER_NAME"
  printf '%sWorkspace:%s  %s\n' "$BOLD" "$RESET" "$WORKSPACE_NAME"
  printf '%sMês:%s        %s (%s a %s)\n\n' "$BOLD" "$RESET" "$(period_label "$month")" \
    "$(date -d "$(period_start "$month")" +%d/%m/%Y)" "$(date -d "$(period_end "$month")" +%d/%m/%Y)"
}

render_day() {
  local date=$1 weekday=$2 minutes=$3 bar_width=$4 hours_color total_color marker=''
  if is_business_day "$date" "$weekday"; then
    if ((minutes >= DAILY_GOAL_MINUTES)); then
      hours_color=$GREEN total_color=$GREEN
    else
      hours_color=$RED total_color=$RED
    fi
  else
    hours_color=$GREEN total_color=$GRAY
    marker=" $(non_business_marker "$date" "$weekday")"
  fi

  printf '%s %s %s%s%s%s\n' "${date:8:2}/${date:5:2}/${date:2:2}" \
    "$(render_bar "$minutes" "$hours_color" "$bar_width")" \
    "$total_color" "$(format_hhmm "$minutes")" "$RESET" "$marker"
}

render_summary() {
  local goal_minutes=$1 worked_minutes=$2 worked_color=''
  if ((worked_minutes > MAX_MONTH_MINUTES)); then
    worked_color=$YELLOW
  fi
  printf '\n%sMáximo:%s     %s\n' "$BOLD" "$RESET" "$(format_hhmm "$MAX_MONTH_MINUTES" 3)"
  printf '%sMeta:%s       %s\n' "$BOLD" "$RESET" "$(format_hhmm "$goal_minutes" 3)"
  printf '%sRealizado:%s  %s%s%s\n' "$BOLD" "$RESET" "$worked_color" "$(format_hhmm "$worked_minutes" 3)" "$RESET"
}

render_footer() {
  local month=$1 current_month=$2 interactive=$3
  if holidays_unavailable "$month"; then
    printf '\n%saviso: feriados indisponíveis (BrasilAPI); só fins de semana foram considerados.%s\n' "$YELLOW" "$RESET"
  fi
  if [[ $interactive == true ]]; then
    printf '\n[A] mês anterior'
    if [[ $month < $current_month ]]; then
      printf '   [D] próximo mês'
    fi
    printf '   [Q] sair\n'
  fi
}

# Mostra o período inteiro: até hoje no período atual, até o fim nos passados.
render_period() {
  local month=$1 current_month=$2 interactive=$3 today
  today=$(date +%F)

  local -a rows=()
  local date weekday seconds minutes
  local business_days=0 worked_minutes=0 bar_width=$MIN_BAR_WIDTH length
  while read -r date weekday seconds; do
    if is_business_day "$date" "$weekday"; then
      business_days=$((business_days + 1))
    fi
    if [[ $date > $today ]]; then
      continue
    fi
    minutes=$((seconds / 60))
    worked_minutes=$((worked_minutes + minutes))
    length=$(bar_length "$minutes")
    bar_width=$((length > bar_width ? length : bar_width))
    rows+=("$date $weekday $minutes")
  done <<<"${PERIOD_CACHE[$month]}"

  render_header "$month"
  local row
  for row in "${rows[@]}"; do
    read -r date weekday minutes <<<"$row"
    render_day "$date" "$weekday" "$minutes" "$bar_width"
  done
  render_summary $((business_days * DAILY_GOAL_MINUTES)) "$worked_minutes"
  render_footer "$month" "$current_month" "$interactive"
}

show_period() {
  local month=$1 current_month=$2 interactive=$3
  if [[ -z ${PERIOD_CACHE[$month]+x} ]]; then
    if [[ $interactive == true ]]; then
      clear_screen
      echo "Carregando $(period_label "$month")…"
    fi
    build_period "$month"
  fi
  if [[ $interactive == true ]]; then
    clear_screen
  fi
  render_period "$month" "$current_month" "$interactive"
}

# ---------------------------------------------------------------------------
# Principal
# ---------------------------------------------------------------------------

main() {
  setup_colors
  require_commands curl jq awk date
  load_config
  load_user
  load_workspace_name

  local current_month month key interactive=false
  current_month=$(current_period_month)
  month=$current_month
  if [[ -t 0 && -t 1 ]]; then
    interactive=true
  fi

  if [[ $interactive == false ]]; then
    show_period "$month" "$current_month" false
    return
  fi

  while true; do
    show_period "$month" "$current_month" true
    read -rsn1 key
    # Setas enviam "ESC [ X"; descarta o resto para não virar A/D.
    if [[ $key == $'\e' ]]; then
      read -rsn2 -t 0.01 _ || true
      continue
    fi
    case $key in
      a | A) month=$(shift_month "$month" -1) ;;
      d | D)
        if [[ $month < $current_month ]]; then
          month=$(shift_month "$month" +1)
        fi
        ;;
      q | Q) break ;;
    esac
  done
}

main "$@"
