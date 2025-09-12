# lib/upgrade.sh
# shellcheck shell=bash
# Function to get the latest patch version for a given series
latest_patch_tag() {
  local series="$1"
  # Hardcoded mapping for known series to their latest patch versions
  case "$series" in
    "13.12") echo "13.12.15-ce.0" ;;
    "14.0")  echo "14.0.12-ce.0" ;;
    "14.10") echo "14.10.5-ce.0" ;;
    "15.11") echo "15.11.13-ce.0" ;;
    "16.11") echo "16.11.3-ce.0" ;;
    "17")    echo "17.0.0-ce.0" ;;
    *)       echo "$series" ;; # fallback to input if not found
  esac
}

compute_stops() {
  echo "13.12"
  echo "14.0"
  echo "14.10"
  echo "15.11"
  echo "16.11"
  [ "$DO_TARGET_17" = "yes" ] && echo "17"
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
    local new_pg_ver new_pg_major new_bin_dir
    new_pg_ver=$(dexec 'gitlab-psql --version' 2>/dev/null | awk '{print $3}')
    new_pg_major="${new_pg_ver%%.*}"
    new_bin_dir="/opt/gitlab/embedded/postgresql/${new_pg_major}/bin"
    log "  версия после reconfigure: ${new_pg_ver:-unknown}"
    log "  старый путь бинарников: ${old_bin_dir}"
    log "  новый путь бинарников: ${new_bin_dir}"
    dexec "[ -d '${old_bin_dir}' ]" || { err "Не найден каталог старых бинарников: ${old_bin_dir}"; exit 1; }
    dexec "[ -d '${new_bin_dir}' ]" || { err "Не найден каталог новых бинарников: ${new_bin_dir}"; exit 1; }
    log "  выполняю gitlab-ctl pg-upgrade"
    local pg_log_container="/var/log/gitlab/pg-upgrade.log"
    local pg_log_host="${DATA_ROOT}/logs/pg-upgrade.log"
    rm -f "$pg_log_host" 2>/dev/null || true
    if dexec "gitlab-ctl pg-upgrade --old-bindir='${old_bin_dir}' --new-bindir='${new_bin_dir}' 2>&1 | tee '${pg_log_container}'"; then
      dexec "tail -n 20 '${pg_log_container}'" 2>/dev/null | sed -e 's/^/    /' || warn "лог pg-upgrade (в контейнере) не найден"
      wait_postgres_ready
      pg_ver=$(dexec 'gitlab-psql --version' 2>/dev/null | awk '{print $3}')
      log "  версия после pg-upgrade: ${pg_ver:-unknown}"
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
  local series="$1" target required_pg=""
  case "$series" in
    "14.0") required_pg=12 ;;
    "15.11") required_pg=13 ;;
    "16.11") required_pg=14 ;;
    "17") required_pg=15 ;;
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
  
    log "[>] Проверка миграций схемы:"
    local ms_output up_count down_count
    ms_output=$(dexec 'gitlab-rake db:migrate:status' 2>/dev/null || true)
    up_count=$(printf '%s\n' "$ms_output" | grep -cE '^\s*up' || true)
    down_count=$(printf '%s\n' "$ms_output" | grep -cE '^\s*down' || true)

    if [ "$down_count" -gt 0 ]; then
      log "  есть неприменённые миграции"
    else
      log "  все миграции применены"
    fi
    log "  итого: up=$up_count, down=$down_count"
  
    log "[>] Статус фоновых миграций (если задача есть):"
    if dexec 'gitlab-rake -T 2>/dev/null | grep -q gitlab:background_migrations:status'; then
      dexec 'gitlab-rake gitlab:background_migrations:status' || warn "Задача gitlab:background_migrations:status завершилась с ошибкой"
    else
      echo "(task not available)" >&2
    fi
  
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
  
    log "[>] Пауза ${WAIT_BETWEEN_STEPS}s"; sleep "$WAIT_BETWEEN_STEPS"
    set_state LAST_UPGRADED_TO "$target"
}
