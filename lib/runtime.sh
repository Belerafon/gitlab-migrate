# lib/runtime.sh
# shellcheck shell=bash

cleanup_previous_run() {
  if [ -f "$LOCK_FILE" ]; then
    local old_pid
    old_pid="$(cat "$LOCK_FILE")"
    if [ -n "$old_pid" ]; then
      if ps -p "$old_pid" -o cmd= 2>/dev/null | grep -q 'gitlab-migrate.sh'; then
        log "[!] Обнаружен запущенный экземпляр (PID $old_pid) — останавливаю"
        kill "$old_pid" 2>/dev/null || true
        sleep 1
        kill -9 "$old_pid" 2>/dev/null || true
      fi
    fi
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"; log "Лог файл: $LOG_FILE"' EXIT
}

prompt_initial_action() {
  local snapshot_dir="$BASE_SNAPSHOT_DIR"
  local snapshot_state="$BASE_SNAPSHOT_DIR/state.env"
  local has_snapshot=0 choice=""

  if [ -d "$snapshot_dir/config" ] && [ -d "$snapshot_dir/data" ]; then
    has_snapshot=1
    log "[>] Найден локальный бэкап ${snapshot_dir}"
    show_snapshot_overview "$snapshot_dir" "$snapshot_state"
    SNAPSHOT_INFO_ALREADY_SHOWN=1
  else
    log "[i] Локальный бэкап ${snapshot_dir} не найден или неполон"
  fi

  log ""
  log "Выберите дальнейшее действие:"
  if [ "$has_snapshot" -eq 1 ]; then
    log "  1) Продолжить миграцию (использовать найденный снапшот при необходимости)"
    log "  2) Создать/обновить локальный снапшот и завершить работу"
    log "  3) Ничего не делать и выйти"
  else
    log "  1) Продолжить миграцию (будут использованы архивы из $BACKUPS_SRC)"
    log "  2) Попробовать создать первичный локальный снапшот и завершить работу"
    log "  3) Выйти"
  fi

  while true; do
    read -r -p "Выбор [1-3]: " choice || choice=""
    choice="${choice:-1}"
    case "$choice" in
      1) INITIAL_ACTION="continue"; return 0 ;;
      2) INITIAL_ACTION="snapshot";  return 0 ;;
      3) INITIAL_ACTION="exit";      return 0 ;;
      *) log "Введите 1, 2 или 3." ;;
    esac
  done
}

snapshot_only_mode() {
  local missing=()
  for d in config data logs; do
    if [ ! -d "$DATA_ROOT/$d" ]; then
      missing+=("$DATA_ROOT/$d")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    err "Нельзя создать снапшот — отсутствуют каталоги: ${missing[*]}"
    warn "Убедитесь, что GitLab уже развернут и каталоги данных доступны по пути $DATA_ROOT"
    return 1
  fi

  log "[>] Создаю локальный снапшот и завершаю работу по запросу пользователя"
  create_snapshot
  ok "Снимок данных обновлён. Скрипт завершает работу"
  return 0
}

reset_migration() {
  log "[!] Сброс миграции: удаление контейнеров, данных и состояния"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [ -d "$DATA_ROOT" ]; then
    log "[>] Очистка директории данных: $DATA_ROOT"
    rm -rf "$DATA_ROOT" 2>/dev/null || true
    mkdir -p "$DATA_ROOT"/{config,data,logs}
  fi
  state_clear
  ok "Миграция сброшена. Можно запускать заново."
  exit 0
}

generate_migration_report() {
  log "\n=== ОТЧЕТ О МИГРАЦИИ ==="
  log "Время завершения: $(date)"
  log "Файл состояния: $STATE_FILE"

  log "\nКонфигурация:"
  log "  - Порт HTTPS: $PORT_HTTPS"
  log "  - Порт HTTP:  $PORT_HTTP"
  log "  - Порт SSH:   $PORT_SSH"

  log "\nИстория апгрейдов:"
  local last_upgraded
  last_upgraded=$(get_state LAST_UPGRADED_TO || true)
  if [ -n "$last_upgraded" ]; then
    log "  - Последняя версия: $last_upgraded"
  fi

  log "\nСтатистика восстановления:"
  # shellcheck disable=SC2034 # используется через nameref в collect_gitlab_stats
  declare -A report_stats=()
  collect_gitlab_stats report_stats
  print_gitlab_stats report_stats "  "

  local repo_size_disk db_size_disk
  repo_size_disk=$(dexec 'du -sh /var/opt/gitlab/git-data/repositories | cut -f1' 2>/dev/null || echo "unknown")
  db_size_disk=$(dexec 'du -sh /var/opt/gitlab/postgresql/data | cut -f1' 2>/dev/null || echo "unknown")

  log "\nРазмер данных на диске:"
  log "  - Git репозитории: $repo_size_disk"
  log "  - PostgreSQL: $db_size_disk"

  log "\nСостояние служб:"
  dexec 'gitlab-ctl status' 2>/dev/null | sed 's/^/  - /' || log "  - Службы недоступны"

  log "\nДоступ к GitLab:"
  log "  - Веб-интерфейс: https://localhost:$PORT_HTTPS"
  log "  - HTTP (если нужен): http://localhost:$PORT_HTTP"
  log "  - SSH: git@localhost:$PORT_SSH"

  log "\n=== КОНЕЦ ОТЧЕТА ==="
}

error_trap() {
  trap - ERR
  set +e
  warn "Ошибка на шаге. См. статус служб ниже:"
  if container_running; then
    (dexec "gitlab-ctl status" || true) 2>&1 | sed -e "s/^/[status] /" >&2
  else
    log "[status] gitlab-ctl status недоступен: контейнер ${CONTAINER_NAME} не запущен"
  fi

  log "[status] ------ Статус контейнера ------"
  docker ps -a --filter "name=$CONTAINER_NAME" 2>&1 | sed -e "s/^/[status] /" >&2 || true
  log "[status] ------ Docker inspect (state) ------"
  docker inspect -f 'State: {{.State.Status}}, Exit: {{.State.ExitCode}}, OOMKilled: {{.State.OOMKilled}}, Restarts: {{.RestartCount}}' "$CONTAINER_NAME" 2>&1 \
    | sed -e "s/^/[status] /" >&2 || true

  log "[status] ------ Подсказки по логам ------"
  log "[status] docker logs --tail 200 $CONTAINER_NAME"
  log "[status] docker exec -it $CONTAINER_NAME tail -n 20 /var/log/gitlab/chef-client.log"
  log "[status] docker exec -it $CONTAINER_NAME tail -n 20 /var/log/gitlab/reconfigure.log"
  local ts
  ts=$(get_state BACKUP_TS || true)
  if [ -n "$ts" ]; then
    log "[status] docker exec -it $CONTAINER_NAME tail -n 20 /var/log/gitlab/restore_${ts}.log"
  fi

  log "[status] ------ Свободная память хоста ------"
  free -h 2>&1 | sed -e "s/^/[status] /" >&2 || true
  if container_running; then
    log "[status] ------ Свободная память контейнера ------"
    dexec 'free -h' 2>&1 | sed -e "s/^/[status] /" >&2 || true
  fi

  log "[status] ------ Свободное место на диске ------"
  df -h 2>&1 | sed -e "s/^/[status] /" >&2 || true
  if container_running; then
    log "[status] ------ Свободное место на диске (контейнер) ------"
    dexec 'df -h' 2>&1 | sed -e "s/^/[status] /" >&2 || true
  fi

  log "[status] ------ dmesg (последние строки) ------"
  dmesg | tail -n 20 | sed -e "s/^/[status] /" >&2 || true
  exit 1
}
