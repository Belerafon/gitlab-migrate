# lib/background.sh
# shellcheck shell=bash

BACKGROUND_RAKE_TASKS_CACHE=""
BACKGROUND_RAKE_TASKS_RC=0
BACKGROUND_RAKE_TASKS_ERROR=""
BACKGROUND_RAKE_TASKS_LOADED=0
BACKGROUND_LAST_PSQL_OUTPUT=""
BACKGROUND_LAST_PSQL_RC=0

indent_with_prefix() {
  local prefix="${1:-      }"
  sed "s/^/${prefix}/"
}

background_load_rake_tasks() {
  if [ "${BACKGROUND_RAKE_TASKS_LOADED:-0}" -eq 1 ]; then
    return
  fi

  local output rc
  if output=$(dexec 'gitlab-rake -T 2>/dev/null' 2>&1); then
    BACKGROUND_RAKE_TASKS_CACHE="$output"
    BACKGROUND_RAKE_TASKS_ERROR=""
    BACKGROUND_RAKE_TASKS_RC=0
  else
    rc=$?
    BACKGROUND_RAKE_TASKS_CACHE=""
    BACKGROUND_RAKE_TASKS_ERROR="$output"
    BACKGROUND_RAKE_TASKS_RC=$rc
  fi
  BACKGROUND_RAKE_TASKS_LOADED=1
}

background_rake_task_exists() {
  local task="$1"
  background_load_rake_tasks

  if [ "${BACKGROUND_RAKE_TASKS_RC:-0}" -ne 0 ]; then
    return 1
  fi

  if [ -z "${BACKGROUND_RAKE_TASKS_CACHE//[[:space:]]/}" ]; then
    return 1
  fi

  if printf '%s\n' "${BACKGROUND_RAKE_TASKS_CACHE}" | awk '{print $1}' | grep -Fxq "$task"; then
    return 0
  fi

  return 1
}

background_psql() {
  local sql="$1" opts="${2-}" cmd output rc

  if [ -n "$opts" ]; then
    cmd="gitlab-psql -d gitlabhq_production -At ${opts} -c \"${sql}\""
  else
    cmd="gitlab-psql -d gitlabhq_production -At -c \"${sql}\""
  fi

  if output=$(dexec "$cmd" 2>&1); then
    BACKGROUND_LAST_PSQL_OUTPUT="$output"
    BACKGROUND_LAST_PSQL_RC=0
  else
    rc=$?
    BACKGROUND_LAST_PSQL_OUTPUT="$output"
    BACKGROUND_LAST_PSQL_RC=$rc
  fi

  return $BACKGROUND_LAST_PSQL_RC
}

background_psql_table_exists() {
  local regclass="$1" query value trimmed rc
  query="SELECT to_regclass('${regclass}')::text"

  if background_psql "$query"; then
    value="${BACKGROUND_LAST_PSQL_OUTPUT:-}"
    trimmed="$(printf '%s' "$value" | tr -d '[:space:]')"
    if [ -n "$trimmed" ]; then
      return 0
    fi
    return 1
  fi

  rc=$?
  return 2
}

background_print_pending_task() {
  local indent="$1" pending_output pending_rc

  if background_rake_task_exists "gitlab:background_migrations:pending"; then
    if pending_output=$(dexec 'gitlab-rake gitlab:background_migrations:pending' 2>&1); then
      pending_rc=0
    else
      pending_rc=$?
    fi
    log "${indent}- gitlab:background_migrations:pending (rc=${pending_rc}):"
    if [[ -n "${pending_output//[[:space:]]/}" ]]; then
      printf '%s\n' "$pending_output" | indent_with_prefix "${indent}  "
    else
      log "${indent}  (команда не вернула вывода)"
    fi
  else
    if [ "${BACKGROUND_RAKE_TASKS_RC:-0}" -ne 0 ] && [ -n "${BACKGROUND_RAKE_TASKS_ERROR:-}" ]; then
      log "${indent}- Не удалось получить список задач rake (gitlab-rake -T):"
      printf '%s\n' "${BACKGROUND_RAKE_TASKS_ERROR}" | indent_with_prefix "${indent}  "
    else
      log "${indent}- Задача gitlab:background_migrations:pending недоступна в этой версии GitLab"
    fi
  fi
}

background_print_sidekiq_status() {
  local indent="$1" output rc

  if output=$(dexec 'gitlab-ctl status sidekiq' 2>&1); then
    rc=0
  else
    rc=$?
  fi

  if [ -n "$output" ]; then
    log "${indent}- gitlab-ctl status sidekiq (rc=${rc}):"
    printf '%s\n' "$output" | indent_with_prefix "${indent}  "
  else
    log "${indent}- gitlab-ctl status sidekiq не вернул вывода (rc=${rc})"
  fi
}

background_print_sidekiq_logs() {
  local indent="$1" output rc

  if output=$(dexec 'tail -n 50 /var/log/gitlab/sidekiq/current' 2>&1); then
    rc=0
  else
    rc=$?
  fi

  if [[ -n "${output//[[:space:]]/}" ]]; then
    log "${indent}- tail -n 50 /var/log/gitlab/sidekiq/current (rc=${rc}):"
    printf '%s\n' "$output" | indent_with_prefix "${indent}  "
  else
    log "${indent}- tail -n 50 /var/log/gitlab/sidekiq/current вывода не дало (rc=${rc})"
  fi
}

background_print_batched_migrations() {
  local indent="$1" table_rc query output

  if background_psql_table_exists 'public.batched_background_migrations'; then
    query="SELECT id || ' | ' || job_class_name || ' | ' || table_name || ' | status=' || status || ' | processed=' || COALESCE(processed_tuple_count::text,'?') || '/' || COALESCE(total_tuple_count::text,'?') || ' | updated=' || COALESCE(updated_at::text,'-') FROM batched_background_migrations WHERE status NOT IN ('finished','finalizing') ORDER BY created_at LIMIT 10"
    if background_psql "$query"; then
      output="${BACKGROUND_LAST_PSQL_OUTPUT:-}"
      if [[ -n "${output//[[:space:]]/}" ]]; then
        log "${indent}- Незавершённые batched фоновые миграции (id | класс | таблица | статус | processed | total | updated):"
        printf '%s\n' "$output" | indent_with_prefix "${indent}  "
      else
        log "${indent}- batched_background_migrations: незавершённых записей нет"
      fi
    else
      log "${indent}- Не удалось получить данные batched_background_migrations (rc=${BACKGROUND_LAST_PSQL_RC:-unknown})"
      if [ -n "${BACKGROUND_LAST_PSQL_OUTPUT:-}" ]; then
        printf '%s\n' "${BACKGROUND_LAST_PSQL_OUTPUT}" | indent_with_prefix "${indent}  "
      fi
    fi

    if background_psql_table_exists 'public.batched_background_migration_jobs'; then
      query="SELECT status || ': ' || COUNT(*) FROM batched_background_migration_jobs GROUP BY status ORDER BY status"
      if background_psql "$query"; then
        output="${BACKGROUND_LAST_PSQL_OUTPUT:-}"
        if [[ -n "${output//[[:space:]]/}" ]]; then
          log "${indent}- batched_background_migration_jobs по статусам:"
          printf '%s\n' "$output" | indent_with_prefix "${indent}  "
        else
          log "${indent}- batched_background_migration_jobs: записей нет"
        fi
      else
        log "${indent}- Не удалось получить batched_background_migration_jobs (rc=${BACKGROUND_LAST_PSQL_RC:-unknown})"
        if [ -n "${BACKGROUND_LAST_PSQL_OUTPUT:-}" ]; then
          printf '%s\n' "${BACKGROUND_LAST_PSQL_OUTPUT}" | indent_with_prefix "${indent}  "
        fi
      fi
    else
      table_rc=$?
      if [ "$table_rc" -eq 2 ]; then
        log "${indent}- Ошибка при проверке batched_background_migration_jobs (rc=${BACKGROUND_LAST_PSQL_RC:-unknown})"
        if [ -n "${BACKGROUND_LAST_PSQL_OUTPUT:-}" ]; then
          printf '%s\n' "${BACKGROUND_LAST_PSQL_OUTPUT}" | indent_with_prefix "${indent}  "
        fi
      else
        log "${indent}- Таблица batched_background_migration_jobs отсутствует"
      fi
    fi
  else
    table_rc=$?
    if [ "$table_rc" -eq 2 ]; then
      log "${indent}- Ошибка при проверке batched_background_migrations (rc=${BACKGROUND_LAST_PSQL_RC:-unknown})"
      if [ -n "${BACKGROUND_LAST_PSQL_OUTPUT:-}" ]; then
        printf '%s\n' "${BACKGROUND_LAST_PSQL_OUTPUT}" | indent_with_prefix "${indent}  "
      fi
    else
      log "${indent}- Таблица batched_background_migrations отсутствует"
    fi
  fi
}

background_print_legacy_jobs() {
  local indent="$1" table_rc query output

  if background_psql_table_exists 'public.background_migration_jobs'; then
    query="SELECT id || ' | ' || class_name || ' | status=' || status || ' | attempts=' || COALESCE(attempts::text,'0') || ' | updated=' || COALESCE(updated_at::text,'-') FROM background_migration_jobs WHERE status <> 'succeeded' ORDER BY updated_at DESC LIMIT 10"
    if background_psql "$query"; then
      output="${BACKGROUND_LAST_PSQL_OUTPUT:-}"
  if [[ -n "${output//[[:space:]]/}" ]]; then
        log "${indent}- Записи background_migration_jobs со статусом <> succeeded:"
        printf '%s\n' "$output" | indent_with_prefix "${indent}  "
      else
        log "${indent}- background_migration_jobs: незавершённых записей нет"
      fi
    else
      log "${indent}- Не удалось получить background_migration_jobs (rc=${BACKGROUND_LAST_PSQL_RC:-unknown})"
      if [ -n "${BACKGROUND_LAST_PSQL_OUTPUT:-}" ]; then
        printf '%s\n' "${BACKGROUND_LAST_PSQL_OUTPUT}" | indent_with_prefix "${indent}  "
      fi
    fi
  else
    table_rc=$?
    if [ "$table_rc" -eq 2 ]; then
      log "${indent}- Ошибка при проверке background_migration_jobs (rc=${BACKGROUND_LAST_PSQL_RC:-unknown})"
      if [ -n "${BACKGROUND_LAST_PSQL_OUTPUT:-}" ]; then
        printf '%s\n' "${BACKGROUND_LAST_PSQL_OUTPUT}" | indent_with_prefix "${indent}  "
      fi
    else
      log "${indent}- Таблица background_migration_jobs отсутствует"
    fi
  fi
}

background_print_manual_hints() {
  local indent="$1"
  log "${indent}- Подсказки по ручной диагностике:"
  log "${indent}  * Проверить sidekiq: docker exec -it ${CONTAINER_NAME} gitlab-ctl tail sidekiq"
  log "${indent}  * Проверить фоновые миграции: docker exec -it ${CONTAINER_NAME} gitlab-psql -d gitlabhq_production -c \"SELECT * FROM batched_background_migrations WHERE status <> 'finished';\""
}

background_migrations_extra_diagnostics() {
  local indent="$1" inner
  inner="${indent}  "
  log "${indent}- Дополнительная диагностика фоновых миграций:"
  background_print_sidekiq_status "$inner"
  background_print_sidekiq_logs "$inner"
  background_print_pending_task "$inner"
  background_print_batched_migrations "$inner"
  background_print_legacy_jobs "$inner"
  background_print_manual_hints "$inner"
}

background_migrations_status_report() {
  local indent="${1:-}"
  local sub="${indent}  "
  local status_output status_rc

  background_load_rake_tasks

  if [ "${BACKGROUND_RAKE_TASKS_RC:-0}" -ne 0 ]; then
    warn "Не удалось получить список rake-задач (gitlab-rake -T завершился с кодом ${BACKGROUND_RAKE_TASKS_RC})"
    if [ -n "${BACKGROUND_RAKE_TASKS_ERROR:-}" ]; then
      log "${indent}- Вывод gitlab-rake -T:"
      printf '%s\n' "${BACKGROUND_RAKE_TASKS_ERROR}" | indent_with_prefix "$sub"
    fi
    return 1
  fi

  if ! background_rake_task_exists "gitlab:background_migrations:status"; then
    log "${indent}- Задача gitlab:background_migrations:status недоступна в этой версии GitLab"
    return 0
  fi

  if status_output=$(dexec 'gitlab-rake gitlab:background_migrations:status' 2>&1); then
    status_rc=0
  else
    status_rc=$?
  fi

  if [ $status_rc -eq 0 ]; then
    log "${indent}- gitlab:background_migrations:status:";
    if [[ -n "${status_output//[[:space:]]/}" ]]; then
      printf '%s\n' "$status_output" | indent_with_prefix "$sub"
    else
      log "${sub}(команда не вернула вывода)"
    fi
    return 0
  fi

  warn "Задача gitlab:background_migrations:status завершилась с ошибкой (код ${status_rc})"
  if [ -n "$status_output" ]; then
    log "${indent}- Вывод gitlab:background_migrations:status (rc=${status_rc}):"
    printf '%s\n' "$status_output" | indent_with_prefix "$sub"
  else
    log "${indent}- gitlab:background_migrations:status не вернула вывода (rc=${status_rc})"
  fi

  background_migrations_extra_diagnostics "$indent"
  return $status_rc
}
