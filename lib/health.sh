# lib/health.sh
# shellcheck shell=bash

# Проверяет, доступна ли указанная задача gitlab-rake в текущей версии GitLab.
gitlab_task_available() {
  local task="$1" tasks rc

  set +e
  tasks=$(dexec 'gitlab-rake -T 2>/dev/null' 2>/dev/null)
  rc=$?
  set -e

  if [ $rc -ne 0 ]; then
    if [ -n "$tasks" ]; then
      printf '%s\n' "$tasks" >&2
    fi
    return 2
  fi

  if printf '%s\n' "$tasks" | awk '{print $2}' | grep -Fxq "$task"; then
    return 0
  fi

  return 1
}

# Выполняет gitlab-rake gitlab:background_migrations:status и запускает
# дополнительные проверки при ошибке.
report_background_migrations_status() {
  log "[>] Статус фоновых миграций (если задача есть):"

  local task_status=0
  if gitlab_task_available 'gitlab:background_migrations:status'; then
    task_status=0
  else
    task_status=$?
  fi

  if [ $task_status -eq 2 ]; then
    warn "Не удалось получить список задач gitlab-rake -T"
    return 0
  fi

  if [ $task_status -ne 0 ]; then
    log "    (задача gitlab:background_migrations:status недоступна в этой версии)"
    return 0
  fi

  local output rc
  set +e
  output=$(dexec 'gitlab-rake gitlab:background_migrations:status' 2>&1)
  rc=$?
  set -e

  if [ -n "$output" ]; then
    printf '%s\n' "$output"
  fi

  if [ $rc -ne 0 ]; then
    warn "Задача gitlab:background_migrations:status завершилась с ошибкой (код $rc)"
    run_gitlab_health_checks "background_migrations"
  fi

  return 0
}

# Запускает базовый набор проверок состояния GitLab, чтобы диагностировать
# проблемы после неудачных операций.
run_gitlab_health_checks() {
  local reason="${1:-diagnostics}" http_status rc

  log "[>] Дополнительная проверка GitLab (повод: ${reason})"

  log "    • gitlab-ctl status"
  if ! dexec 'gitlab-ctl status'; then
    warn "gitlab-ctl status завершился с ошибкой"
  fi

  log "    • gitlab-rake gitlab:check SANITIZE=true"
  if ! dexec 'gitlab-rake gitlab:check SANITIZE=true'; then
    warn "gitlab-rake gitlab:check завершилась с ошибкой (см. вывод выше)"
  fi

  if dexec 'command -v curl >/dev/null 2>&1'; then
    log "    • HTTP проверка /users/sign_in"
    set +e
    http_status=$(dexec 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/users/sign_in' 2>/dev/null)
    rc=$?
    set -e
    if [ $rc -eq 0 ]; then
      log "      HTTP статус: ${http_status}"
      if [[ "$http_status" != "200" && "$http_status" != "302" ]]; then
        warn "HTTP проверка вернула неожиданный код ${http_status}"
      fi
    else
      warn "HTTP проверка /users/sign_in завершилась с ошибкой (код ${rc})"
    fi
  else
    warn "curl не найден в контейнере — пропускаю HTTP проверку"
  fi

  return 0
}
