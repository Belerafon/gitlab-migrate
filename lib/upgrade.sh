# lib/upgrade.sh
# shellcheck shell=bash
declare -a UPGRADE_SERIES_ORDER=()
declare -A UPGRADE_SERIES_PATCH=()
declare -A UPGRADE_SERIES_REQUIREMENT=()
declare -A UPGRADE_SERIES_FLAGS=()
declare -A UPGRADE_SERIES_NOTES=()
declare -a UPGRADE_SKIPPED_OPTIONALS=()

register_upgrade_series() {
  local series="$1" patch="$2" requirement="$3" flags="$4" note="$5"
  UPGRADE_SERIES_ORDER+=("$series")
  UPGRADE_SERIES_PATCH["$series"]="$patch"
  UPGRADE_SERIES_REQUIREMENT["$series"]="${requirement:-required}"
  UPGRADE_SERIES_FLAGS["$series"]="$flags"
  UPGRADE_SERIES_NOTES["$series"]="$note"
}

while IFS='|' read -r series patch requirement flags note; do
  [[ -z "$series" ]] && continue
  [[ "$series" = \#* ]] && continue
  register_upgrade_series "$series" "$patch" "$requirement" "$flags" "$note"
done <<'EOF'
# series|patch|requirement|flags|note
13.0|13.0.14-ce.0|required||Финальный патч ветки 13.0 перед переходом на 13.1
13.1|13.1.11-ce.0|required||Обязательная остановка GitLab 13 перед 13.8
13.8|13.8.8-ce.0|required||Обязательная остановка GitLab 13 перед 13.12
13.12|13.12.15-ce.0|required||Последний релиз 13.x перед переходом на 14.x
14.0|14.0.12-ce.0|required||Старт ветки 14.x с исправлениями миграций
14.3|14.3.6-ce.0|required||Рекомендуемая остановка 14.3 для безопасных миграций БД
14.9|14.9.5-ce.0|required||Обязательный стоп 14.9 перед финальным 14.10
14.10|14.10.5-ce.0|required||Финальный релиз 14.x перед 15.x
15.0|15.0.5-ce.0|required||Первый релиз 15.x с исправлениями миграций
15.1|15.1.6-ce.0|conditional|multi-web|Нужен для инстансов с несколькими web-нодами
15.4|15.4.6-ce.0|required||Обязательный стоп 15.4 перед 15.11
15.11|15.11.13-ce.0|required||Последний релиз 15.x перед 16.x
16.0|16.0.10-ce.0|conditional|large-users,large-pipeline-history|Рекомендуется для крупных инстансов и больших историй переменных пайплайнов
16.1|16.1.8-ce.0|conditional|npm-packages|Рекомендуется при использовании npm в registry
16.2|16.2.11-ce.0|conditional|pipeline-variables|Нужен для инстансов с большой историей переменных пайплайна
16.3|16.3.9-ce.0|required||Обязательный стоп 16.3
16.7|16.7.10-ce.0|required||Обязательный стоп 16.7
16.11|16.11.10-ce.0|required||Последний релиз 16.x перед 17.x и переходом на PostgreSQL 14
17.0|17.0.7-ce.0|required||Начальный релиз ветки 17.x с исправлениями миграций
17.1|17.1.8-ce.0|conditional|large-ci-pipeline-messages|Нужен для инстансов с крупной таблицей ci_pipeline_messages
17.3|17.3.7-ce.0|required||Обязательный стоп 17.3
17.5|17.5.5-ce.0|required||Обязательный стоп 17.5
17.8|17.8.7-ce.0|required||Обязательный стоп 17.8
17.11|17.11.7-ce.0|required||Финальный релиз 17.x на момент подготовки
EOF

# Function to get the latest patch version for a given series
latest_patch_tag() {
  local series patch
  series="$1"
  patch="${UPGRADE_SERIES_PATCH[$series]:-}"
  if [ -n "$patch" ]; then
    echo "$patch"
  else
    echo "$series"
  fi
}

# Убирает суффиксы вроде «-ce.0» и переводит версию в компактный вид.
normalize_version_string() {
  local version="$1"
  version="${version%%-*}"
  version="${version//$'\r'/}"
  version="${version//$'\n'/}"
  version="${version//[$' \t']/}"
  printf '%s' "$version"
}

# Проверяет, что первая версия не меньше второй (сравнение major.minor.patch).
version_ge() {
  local left right highest

  left="$(normalize_version_string "$1")"
  right="$(normalize_version_string "$2")"

  if [ -z "$left" ]; then
    return 1
  fi
  if [ -z "$right" ]; then
    return 0
  fi

  if [ "$left" = "$right" ]; then
    return 0
  fi

  highest=$(printf '%s\n%s\n' "$left" "$right" | LC_ALL=C sort -V | tail -n1)
  [[ "$highest" = "$left" ]]
}

upgrade_stop_requirement() {
  local series="$1"
  printf '%s' "${UPGRADE_SERIES_REQUIREMENT[$series]:-required}"
}

upgrade_stop_flags() {
  local series="$1"
  printf '%s' "${UPGRADE_SERIES_FLAGS[$series]:-}"
}

upgrade_stop_note() {
  local series="$1"
  printf '%s' "${UPGRADE_SERIES_NOTES[$series]:-}"
}

describe_upgrade_stop() {
  local series="$1" patch requirement flags note status extras_join=""
  local -a extras=()
  patch="$(latest_patch_tag "$series")"
  requirement="$(upgrade_stop_requirement "$series")"
  flags="$(upgrade_stop_flags "$series")"
  note="$(upgrade_stop_note "$series")"

  case "$requirement" in
    required) status="обязательная" ;;
    conditional) status="условная" ;;
    *) status="$requirement" ;;
  esac

  if [ -n "$flags" ]; then
    extras+=("условия: $flags")
  fi
  if [ -n "$note" ]; then
    extras+=("$note")
  fi

  if [ "${#extras[@]}" -gt 0 ]; then
    extras_join=$(printf '%s; ' "${extras[@]}")
    extras_join="${extras_join%; }"
    printf '%s -> %s (%s; %s)' "$series" "$patch" "$status" "$extras_join"
  else
    printf '%s -> %s (%s)' "$series" "$patch" "$status"
  fi
}

should_include_stop() {
  local series="$1" requirement="$2"
  local include_optional major list

  major="${series%%.*}"
  if [[ "$series" == "$major" ]]; then
    major="$series"
  fi

  if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 17 ] && [ "${DO_TARGET_17:-no}" != "yes" ]; then
    return 1
  fi

  if [ "$requirement" != "conditional" ]; then
    return 0
  fi

  include_optional="${INCLUDE_OPTIONAL_STOPS:-yes}"
  case "$include_optional" in
    yes|true|1|auto|'') return 0 ;;
    no|false|0) return 1 ;;
    list)
      list=",${OPTIONAL_STOP_LIST:-},"
      if [[ "$list" == *",${series},"* ]]; then
        return 0
      fi
      return 1
      ;;
    *)
      warn "Неизвестное значение INCLUDE_OPTIONAL_STOPS='${include_optional}' — использую включение условных остановок"
      return 0
      ;;
  esac
}

compute_stops() {
  local series requirement
  UPGRADE_SKIPPED_OPTIONALS=()

  for series in "${UPGRADE_SERIES_ORDER[@]}"; do
    requirement="$(upgrade_stop_requirement "$series")"

    if should_include_stop "$series" "$requirement"; then
      echo "$series"
    else
      if [ "$requirement" = "conditional" ]; then
        UPGRADE_SKIPPED_OPTIONALS+=("$series")
      fi
    fi
  done
}

get_skipped_optional_stops() {
  local series

  for series in "${UPGRADE_SKIPPED_OPTIONALS[@]}"; do
    [ -n "$series" ] || continue
    printf '%s\n' "$series"
  done
}

format_bytes_human() {
  local bytes="$1" human=""
  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    if command -v numfmt >/dev/null 2>&1; then
      human=$(numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || true)
    fi
    if [ -n "$human" ]; then
      printf "%s (%s B)" "$human" "$bytes"
      return
    fi
    printf "%s B" "$bytes"
  else
    printf "%s" "$bytes"
  fi
}

log_gitlab_instance_stats() {
  if ! container_running; then
    warn "Контейнер ${CONTAINER_NAME} не запущен — пропускаю сбор статистики"
    return
  fi

  local projects_raw users_raw repo_size_raw projects users repo_size display

  projects="unknown"
  if projects_raw=$(dexec 'gitlab-psql -d gitlabhq_production -t -c "SELECT COUNT(*) FROM projects;"' 2>/dev/null); then
    projects=$(printf "%s" "$projects_raw" | tr -d '[:space:]')
    [ -n "$projects" ] || projects="0"
  else
    warn "Не удалось получить количество репозиториев"
  fi

  users="unknown"
  if users_raw=$(dexec 'gitlab-psql -d gitlabhq_production -t -c "SELECT COUNT(*) FROM users;"' 2>/dev/null); then
    users=$(printf "%s" "$users_raw" | tr -d '[:space:]')
    [ -n "$users" ] || users="0"
  else
    warn "Не удалось получить количество пользователей"
  fi

  repo_size="unknown"
  if repo_size_raw=$(dexec 'gitlab-psql -d gitlabhq_production -t -c "SELECT COALESCE(SUM(repository_size),0) FROM project_statistics;"' 2>/dev/null); then
    repo_size=$(printf "%s" "$repo_size_raw" | tr -d '[:space:]')
    [ -n "$repo_size" ] || repo_size="0"
  else
    warn "Не удалось получить суммарный размер репозиториев"
  fi

  display=$(format_bytes_human "$repo_size")

  log "  статистика GitLab:"
  log "    - Количество репозиториев (projects): ${projects}"
  log "    - Количество пользователей: ${users}"
  log "    - Объём данных репозиториев: ${display}"
}

prompt_snapshot_after_upgrade() {
  local current_version="$1" target_tag="$2"
  local snapshot_version snapshot_display prompt snapshot_ts snapshot_image

  current_version="${current_version:-$(current_gitlab_version)}"
  snapshot_version="$(get_state SNAPSHOT_VERSION || true)"
  snapshot_ts="$(get_state SNAPSHOT_TS || true)"
  snapshot_image="$(get_state SNAPSHOT_IMAGE || true)"

  if [ -z "$snapshot_version" ]; then
    snapshot_display="нет"
  else
    snapshot_display="$snapshot_version"
  fi

  log "[>] Состояние перед созданием снапшота:"
  log "    - Текущая версия GitLab: ${current_version}"
  log "    - Версия в локальном снимке: ${snapshot_display}"
  if [ -n "$snapshot_ts" ]; then
    log "    - Метка последнего снапшота: ${snapshot_ts}"
  fi
  if [ -n "$snapshot_image" ]; then
    log "    - Образ в последнем снапшоте: ${snapshot_image}"
  fi

  prompt="Создать локальный снапшот? (текущая: ${current_version}; в снимке: ${snapshot_display})"
  if ask_yes_no "$prompt" "y"; then
    log "[>] Создаю локальный снапшот после апгрейда до ${target_tag}"
    create_snapshot "$current_version"
    wait_gitlab_ready
    wait_postgres_ready
    ok "Снимок после обновления сохранён"
  else
    log "[>] Пользователь пропустил создание снапшота; в наличии версия ${snapshot_display}"
  fi
}

# Проверяет версию PostgreSQL и при необходимости выполняет pg-upgrade
ensure_postgres_at_least() {
  local required="$1" series="$2"
  log "[>] Проверка версии PostgreSQL перед переходом на ${series}"
  local pg_ver pg_major data_pg_ver data_pg_major old_bin_dir
  pg_ver=$(dexec 'gitlab-psql --version' 2>/dev/null | awk '{print $3}')
  pg_major="${pg_ver%%.*}"
  old_bin_dir="/opt/gitlab/embedded/postgresql/${pg_major}/bin"
  data_pg_ver=$(dexec 'cat /var/opt/gitlab/postgresql/data/PG_VERSION 2>/dev/null || echo unknown')
  data_pg_major="${data_pg_ver%%.*}"
  log "  текущая версия бинарников: ${pg_ver:-unknown}"
  log "  версия данных в каталоге: ${data_pg_ver:-unknown}"
  log "  содержимое /var/opt/gitlab/postgresql:"
  dexec 'ls -al /var/opt/gitlab/postgresql' 2>/dev/null || true
  log "  содержимое /var/opt/gitlab/postgresql/data:"
  dexec 'ls -al /var/opt/gitlab/postgresql/data' 2>/dev/null || true
  log "  доступные каталоги бинарников:"
  dexec 'ls -1 /opt/gitlab/embedded/postgresql' 2>/dev/null || true
  if dexec 'command -v pg_controldata >/dev/null 2>&1'; then
    log "  pg_controldata (первые строки):"
    dexec 'pg_controldata /var/opt/gitlab/postgresql/data 2>/dev/null | head -n 20' || true
  fi

  if [[ -n "$pg_major" ]] && [[ -n "$data_pg_major" ]] && [[ "$data_pg_major" != "$pg_major" ]]; then
    err "Каталог данных /var/opt/gitlab/postgresql/data создан версией ${data_pg_ver}, а текущие бинарники ${pg_ver}. Восстанови корректный бэкап или очисти каталог перед повтором."
    exit 1
  fi

  if [[ -n "$pg_major" ]] && [[ "$pg_major" -lt "$required" ]]; then
    log "  выполняю gitlab-ctl reconfigure (подготовка к pg-upgrade)"
    run_reconfigure || exit 1
    local new_pg_ver available_bins new_pg_major="" new_bin_dir pg_upgrade_help supports_bindir=0 upgrade_command data_pg_ver
    new_pg_ver=$(dexec 'gitlab-psql --version' 2>/dev/null | awk '{print $3}')
    log "  версия после reconfigure: ${new_pg_ver:-unknown}"

    available_bins=$(dexec "ls -1 /opt/gitlab/embedded/postgresql 2>/dev/null | sort -n" 2>/dev/null || true)
    local formatted_bins
    formatted_bins="${available_bins//$'\n'/, }"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^[0-9]+$ ]] || continue
      if [ "$line" -gt "$pg_major" ]; then
        new_pg_major="$line"
        break
      fi
    done <<< "$available_bins"

    if [ -z "$new_pg_major" ]; then
      err "После reconfigure не найдена новая версия PostgreSQL (ожидалась >= ${required}). Каталоги: ${formatted_bins}"
      exit 1
    fi

    if [ "$new_pg_major" -lt "$required" ]; then
      err "Доступная версия PostgreSQL ${new_pg_major} меньше требуемой ${required}."
      exit 1
    fi

    new_bin_dir="/opt/gitlab/embedded/postgresql/${new_pg_major}/bin"
    log "  старый путь бинарников: ${old_bin_dir}"
    log "  новый путь бинарников: ${new_bin_dir}"

    dexec "[ -d '${old_bin_dir}' ]" || { err "Не найден каталог старых бинарников: ${old_bin_dir}"; exit 1; }
    dexec "[ -d '${new_bin_dir}' ]" || { err "Не найден каталог новых бинарников: ${new_bin_dir}"; exit 1; }

    pg_upgrade_help="$(dexec 'gitlab-ctl pg-upgrade --help' 2>/dev/null || true)"
    if printf '%s' "$pg_upgrade_help" | grep -q -- '--old-bindir'; then
      supports_bindir=1
    fi

    if [ "$supports_bindir" -eq 1 ]; then
      upgrade_command="gitlab-ctl pg-upgrade --old-bindir='${old_bin_dir}' --new-bindir='${new_bin_dir}'"
    else
      upgrade_command="gitlab-ctl pg-upgrade -V ${new_pg_major}"
    fi

    log "  выполняю ${upgrade_command}"
    local pg_log_container="/var/log/gitlab/pg-upgrade.log"
    local pg_log_host="${DATA_ROOT}/logs/pg-upgrade.log"
    rm -f "$pg_log_host" 2>/dev/null || true
    if dexec "set -o pipefail; ${upgrade_command} 2>&1 | tee '${pg_log_container}'"; then
      dexec "tail -n 20 '${pg_log_container}'" 2>/dev/null | sed -e 's/^/    /' || warn "лог pg-upgrade (в контейнере) не найден"
      wait_postgres_ready
      pg_ver=$(dexec 'gitlab-psql --version' 2>/dev/null | awk '{print $3}')
      data_pg_ver=$(dexec 'cat /var/opt/gitlab/postgresql/data/PG_VERSION 2>/dev/null || echo unknown')
      log "  версия после pg-upgrade: ${pg_ver:-unknown}"
      log "  версия данных после pg-upgrade: ${data_pg_ver:-unknown}"
      if [ "${pg_ver%%.*}" -lt "$required" ] || [ "${data_pg_ver%%.*}" -lt "$required" ]; then
        err "pg-upgrade завершился, но версия осталась ${pg_ver:-unknown} (данные ${data_pg_ver:-unknown})."
        exit 1
      fi
      ok "PostgreSQL обновлён"
    else
      dexec "tail -n 50 '${pg_log_container}'" 2>/dev/null | sed -e 's/^/    /' || warn "лог pg-upgrade (в контейнере) не найден"
      if dexec "grep -q 'Old cluster data and binary directories are from different major versions' '${pg_log_container}'" 2>/dev/null; then
        err "Обнаружено несоответствие major-версий PostgreSQL. Каталог данных создан другой версией. Проверь /var/opt/gitlab/postgresql и восстанови его из корректного бэкапа или очисти перед повтором."
      fi
      err "pg-upgrade завершился с ошибкой. Лог: $pg_log_host"
      exit 1
    fi
  fi
}

upgrade_to_series() {
  local series="$1" target required_pg="" major
  major="${series%%.*}"

  case "$major" in
    14)
      if [ "$series" = "14.0" ]; then
        required_pg=12
      fi
      ;;
    15)
      if [ "$series" = "15.11" ]; then
        required_pg=13
      fi
      ;;
    16)
      if [ "$series" = "16.11" ]; then
        required_pg=14
      fi
      ;;
    17)
      required_pg=15
      ;;
  esac
  if [[ -n "$required_pg" ]]; then
    ensure_postgres_at_least "$required_pg" "$series"
  fi
  if [[ "$series" =~ ^[0-9]+\.[0-9]+$ ]] || [[ "$series" =~ ^[0-9]+$ ]]; then
    target="$(latest_patch_tag "$series")"
    else
      target="$series"
    fi
    log "[==>] Апгрейд до gitlab/gitlab-ce:${target}"
    docker pull "gitlab/gitlab-ce:${target}" >/dev/null 2>&1 || warn "pull не обязателен, продолжу"
    run_container "$target"
    wait_gitlab_ready
    wait_postgres_ready
    wait_upgrade_completion
    report_basic_health "после апгрейда до ${target}"

    log "[>] Проверка миграций схемы:"
    local ms_output up_count down_count
    ms_output=$(gitlab_rake db:migrate:status 2>/dev/null || true)
    up_count=$(printf '%s\n' "$ms_output" | grep -cE '^\s*up' || true)
    down_count=$(printf '%s\n' "$ms_output" | grep -cE '^\s*down' || true)

    if [ "$down_count" -gt 0 ]; then
      log "  есть неприменённые миграции"
    else
      log "  все миграции применены"
    fi
    log "  итого: up=$up_count, down=$down_count"

    log_gitlab_instance_stats

    log "[>] Статус фоновых миграций (если задача есть):"
    background_migrations_status_report "  " || true
  
    # Additional check for successful upgrade
    local current_version current_base target_base
    current_version=$(dexec 'cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo unknown')
    target_base="${target%%-*}"
    current_base="${current_version%%-*}"
    if [[ "$current_base" != "$target_base" ]]; then
      warn "Версия после апгрейда не соответствует ожидаемой: $current_version != $target"
      log "[>] Попытка повторного запуска служб..."
      dexec 'gitlab-ctl restart >/dev/null 2>&1' || true
      sleep "$WAIT_AFTER_START"
      wait_gitlab_ready
      wait_postgres_ready
      current_version=$(dexec 'cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo unknown')
      current_base="${current_version%%-*}"
      if [[ "$current_base" != "$target_base" ]]; then
        err "Апгрейд до $target не удался. Текущая версия: $current_version"
        exit 1
      fi
    fi

    prompt_snapshot_after_upgrade "$current_version" "$target"

    log "[>] Пауза ${WAIT_BETWEEN_STEPS}s"; sleep "$WAIT_BETWEEN_STEPS"
    set_state LAST_UPGRADED_TO "$target"
}

pause_after_upgrade_step() {
  local target="$1" context

  if [ -z "$target" ]; then
    target="$(get_state LAST_UPGRADED_TO || true)"
  fi

  if [ -n "$target" ]; then
    context="после апгрейда до ${target}"
    log "[>] Шаг обновления до ${target} завершён — приостанавливаюсь"
  else
    context="после апгрейда"
    log "[>] Шаг обновления завершён — приостанавливаюсь"
  fi

  report_basic_health "перед остановкой ${context}"

  if [ -n "$target" ]; then
    ok "Шаг апгрейда до ${target} завершён. Запустите скрипт ещё раз для продолжения."
  else
    ok "Шаг апгрейда завершён. Запустите скрипт ещё раз для продолжения."
  fi

  exit 0
}
