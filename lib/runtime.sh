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
  local project_count user_count issue_count repo_size db_size
  project_count=$(dexec 'gitlab-psql -d gitlabhq_production -t -c "SELECT COUNT(*) FROM projects;" 2>/dev/null | tr -d "[:space:]" || echo "unknown"')
  user_count=$(dexec 'gitlab-psql -d gitlabhq_production -t -c "SELECT COUNT(*) FROM users WHERE state='\''active'\'';" 2>/dev/null | tr -d "[:space:]" || echo "unknown"')
  issue_count=$(dexec 'gitlab-psql -d gitlabhq_production -t -c "SELECT COUNT(*) FROM issues;" 2>/dev/null | tr -d "[:space:]" || echo "unknown"')
  repo_size=$(dexec 'du -sh /var/opt/gitlab/git-data/repositories | cut -f1' 2>/dev/null || echo "unknown")
  db_size=$(dexec 'du -sh /var/opt/gitlab/postgresql/data | cut -f1' 2>/dev/null || echo "unknown")

  log "  - Проекты: $project_count"
  log "  - Активные пользователи: $user_count"
  log "  - Задачи: $issue_count"
  log "  - Размер репозиториев: $repo_size"
  log "  - Размер базы данных: $db_size"

  log "\nСостояние служб:"
  dexec 'gitlab-ctl status' 2>/dev/null | sed 's/^/  - /' || log "  - Службы недоступны"

  log "\nДоступ к GitLab:"
  log "  - Веб-интерфейс: https://localhost:$PORT_HTTPS"
  log "  - HTTP (если нужен): http://localhost:$PORT_HTTP"
  log "  - SSH: git@localhost:$PORT_SSH"

  log "\n=== КОНЕЦ ОТЧЕТА ==="
}

print_host_log_hint() {
  log "    - Лог миграции (host): $LOG_FILE"
  log "    - Логи GitLab (host): $DATA_ROOT/logs"
  log "    - Последние события контейнера: docker logs --tail 200 $CONTAINER_NAME"
}

manual_checkpoint() {
  local context="$1" state_key="${2-}" mode="${3-}" loop_prompt

  if [ -n "$state_key" ] && [ "$(get_state "$state_key" || true)" = "1" ]; then
    ok "Контрольная точка (${context}) уже подтверждена — пропускаю"
    return 0
  fi

  log "[>] Контрольная точка: ${context}"

  while true; do
    if ensure_gitlab_health "$context" "$mode"; then
      ok "Автоматические проверки (${context}) пройдены"
    else
      warn "Автоматическая проверка (${context}) выявила проблемы: ${LAST_HEALTH_ISSUES:-unknown}"
      log "    - HTTP (контейнер): ${LAST_HEALTH_HTTP_INFO:-n/a}"
      log "    - HTTP (хост): ${LAST_HEALTH_HOST_HTTP_INFO:-n/a}"
      print_host_log_hint
    fi

    log "    - Проверь вручную веб-интерфейс: https://<твой-домен>:$PORT_HTTPS (или http://<домен>:$PORT_HTTP)"
    log "    - Убедись, что можно войти через SSH по порту $PORT_SSH (при необходимости)"

    if ask_yes_no "Подтверди, что GitLab работает корректно (${context}) и можно продолжать?" "n"; then
      if [ "${LAST_HEALTH_OK:-0}" != "1" ]; then
        warn "Продолжаем несмотря на обнаруженные автоматикой проблемы (${LAST_HEALTH_ISSUES:-unknown})"
      fi
      if [ -n "$state_key" ]; then
        set_state "$state_key" 1
      fi
      ok "Контрольная точка (${context}) подтверждена пользователем"
      break
    fi

    log "[>] Приостанавливаюсь. После устранения проблем нажми Enter для повторной проверки (Ctrl+C для выхода)"
    read -r -p "    Enter для повторной проверки или Ctrl+C для прерывания..." loop_prompt || true
  done
}

error_trap() {
  trap - ERR
  set +e
  warn "Ошибка на шаге. См. статус служб ниже:"
  (dexec "gitlab-ctl status" || true) 2>&1 | sed -e "s/^/[status] /" >&2

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
