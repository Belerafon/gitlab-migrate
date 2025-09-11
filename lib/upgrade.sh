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
  local pg_ver pg_major
  pg_ver=$(dexec 'gitlab-psql --version' 2>/dev/null | awk '{print $3}')
  pg_major="${pg_ver%%.*}"
  log "  текущая версия: ${pg_ver:-unknown}"
  if [[ -n "$pg_major" ]] && [[ "$pg_major" -lt "$required" ]]; then
    log "  выполняю gitlab-ctl reconfigure (подготовка к pg-upgrade)"
    if dexec 'gitlab-ctl reconfigure'; then
      ok "reconfigure выполнен"
    else
      err "gitlab-ctl reconfigure завершился с ошибкой"
      exit 1
    fi
    log "  выполняю gitlab-ctl pg-upgrade"
    if dexec 'gitlab-ctl pg-upgrade'; then
      wait_postgres_ready
      ok "PostgreSQL обновлён"
    else
      err "pg-upgrade завершился с ошибкой. Лог: /var/log/gitlab/pg-upgrade-*.log (на хосте: ${DATA_ROOT}/logs/pg-upgrade-*.log)"
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
    dexec 'gitlab-rake gitlab:background_migrations:status' >/dev/null 2>&1 && \
    dexec 'gitlab-rake gitlab:background_migrations:status' || echo "(task not available)" >&2
  
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
