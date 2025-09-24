# lib/background.sh
# shellcheck shell=bash

BACKGROUND_RAKE_TASKS_CACHE=""
BACKGROUND_RAKE_TASKS_RC=0
BACKGROUND_RAKE_TASKS_ERROR=""
BACKGROUND_RAKE_TASKS_LOADED=0
BACKGROUND_LAST_PSQL_OUTPUT=""
BACKGROUND_LAST_PSQL_RC=0
BACKGROUND_PENDING_TOTAL=0
BACKGROUND_PENDING_DETAILS=""
BACKGROUND_PENDING_ERROR_MSG=""
BACKGROUND_PENDING_BLOCKED=0
BACKGROUND_PENDING_BLOCKER_MSG=""
BACKGROUND_PENDING_BATCHED=0
BACKGROUND_PENDING_BATCHED_JOBS_TOTAL=0
BACKGROUND_PENDING_LEGACY=0

indent_with_prefix() {
  local prefix="${1:-      }"
  sed "s/^/${prefix}/"
}
 
background_normalize_lines() {
  local data="$1"
  printf '%s' "$data" | tr -d '\\r' | sed '/^[[:space:]]*$/d'
}
 
background_sum_counts() {
  local data
  data="$(background_normalize_lines "$1")"
  if [ -z "$data" ]; then
    printf '0'
    return 0
  fi
  printf '%s\n' "$data" | awk -F= 'BEGIN{sum=0} {if($2 ~ /^[0-9]+$/) {sum+=$2}} END{print sum}'
}

background_format_status_bullet_lines() {
  local data indent bullet line result=""

  data="$(background_normalize_lines "$1")"
  indent="${2:-    }"
  bullet="${3:-- }"

  if [ -z "$data" ]; then
    return 1
  fi

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    result+="${indent}${bullet}${line}"$'\n'
  done <<< "$data"

  printf '%s' "${result%$'\n'}"
  return 0
}
 
background_append_error_msg() {
  local message="$1"
  if [ -z "$message" ]; then
    return
  fi
  if [ -z "$BACKGROUND_PENDING_ERROR_MSG" ]; then
    BACKGROUND_PENDING_ERROR_MSG="$message"
  else
    BACKGROUND_PENDING_ERROR_MSG+=$'\n'"$message"
  fi
}
background_append_blocker() {
  local message="$1"
  [ -z "$message" ] && return
  BACKGROUND_PENDING_BLOCKED=1
  if [ -z "$BACKGROUND_PENDING_BLOCKER_MSG" ]; then
    BACKGROUND_PENDING_BLOCKER_MSG="$message"
  else
    BACKGROUND_PENDING_BLOCKER_MSG+=$'\n'"$message"
  fi
}
 
background_append_psql_error() {
  local context="$1" query="$2" rc output message
  rc="${BACKGROUND_LAST_PSQL_RC:-unknown}"
  output="$(background_normalize_lines "${BACKGROUND_LAST_PSQL_OUTPUT:-}")"
  message="${context}: запрос ${query} завершился с кодом ${rc}"
  if [ -n "$output" ]; then
    message="${message}"$'\n'"${output}"
  fi
  background_append_error_msg "$message"
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

background_table_base_name() {
  local regclass="$1"
  regclass="${regclass//\"/}"
  case "$regclass" in
    *.*)
      printf '%s' "${regclass##*.}"
      ;;
    *)
      printf '%s' "$regclass"
      ;;
  esac
}

background_psql_column_type() {
  local regclass="$1" column="$2" query type_raw type_trimmed

  query="SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = '${regclass}'::regclass AND attname = '${column}'"

  if background_psql "$query"; then
    type_raw="${BACKGROUND_LAST_PSQL_OUTPUT:-}"
    type_trimmed="$(printf '%s' "$type_raw" | tr -d '[:space:]')"
    printf '%s' "$type_trimmed"
    return 0
  fi

  return 1
}

background_status_type_is_numeric() {
  local type="$1"

  case "$type" in
    smallint|integer|bigint)
      return 0
      ;;
  esac

  return 1
}

background_status_numeric_value() {
  local table_base="$1" status_name="$2"

  case "${table_base}:${status_name}" in
    batched_background_migrations:paused)
      printf '0'
      ;;
    batched_background_migrations:active)
      printf '1'
      ;;
    batched_background_migrations:finished)
      printf '3'
      ;;
    batched_background_migrations:failed)
      printf '4'
      ;;
    batched_background_migrations:finalizing)
      printf '5'
      ;;
    batched_background_migrations:finalized)
      printf '6'
      ;;
    batched_background_migration_jobs:pending)
      printf '0'
      ;;
    batched_background_migration_jobs:running)
      printf '1'
      ;;
    batched_background_migration_jobs:failed)
      printf '2'
      ;;
    batched_background_migration_jobs:finished|batched_background_migration_jobs:succeeded)
      printf '3'
      ;;
    background_migration_jobs:pending)
      printf '0'
      ;;
    background_migration_jobs:running)
      printf '1'
      ;;
    background_migration_jobs:failed|background_migration_jobs:errored)
      printf '2'
      ;;
    background_migration_jobs:finished|background_migration_jobs:succeeded)
      printf '3'
      ;;
    *)
      return 1
      ;;
  esac

  return 0
}

background_quote_list() {
  local items=("$@") item result=""

  for item in "${items[@]}"; do
    [ -z "$item" ] && continue
    item="${item//\'/''}"
    result+="'${item}',"
  done

  result="${result%,}"
  printf '%s' "$result"
}

background_status_case_expression() {
  local regclass="$1" column="${2:-status}" type base expr=""

  if ! type="$(background_psql_column_type "$regclass" "$column")"; then
    printf '%s' "$column"
    return 0
  fi

  if ! background_status_type_is_numeric "$type"; then
    printf '%s' "$column"
    return 0
  fi

  base="$(background_table_base_name "$regclass")"

  case "$base" in
    batched_background_migrations)
      expr="CASE ${column}"
      expr+=" WHEN 0 THEN 'paused'"
      expr+=" WHEN 1 THEN 'active'"
      expr+=" WHEN 3 THEN 'finished'"
      expr+=" WHEN 4 THEN 'failed'"
      expr+=" WHEN 5 THEN 'finalizing'"
      expr+=" WHEN 6 THEN 'finalized'"
      expr+=" ELSE ${column}::text END"
      ;;
    batched_background_migration_jobs)
      expr="CASE ${column}"
      expr+=" WHEN 0 THEN 'pending'"
      expr+=" WHEN 1 THEN 'running'"
      expr+=" WHEN 2 THEN 'failed'"
      expr+=" WHEN 3 THEN 'succeeded'"
      expr+=" ELSE ${column}::text END"
      ;;
    background_migration_jobs)
      expr="CASE ${column}"
      expr+=" WHEN 0 THEN 'pending'"
      expr+=" WHEN 1 THEN 'running'"
      expr+=" WHEN 2 THEN 'failed'"
      expr+=" WHEN 3 THEN 'succeeded'"
      expr+=" ELSE ${column}::text END"
      ;;
    *)
      expr="${column}::text"
      ;;
  esac

  printf '%s' "$expr"
}

background_status_filter_condition() {
  local regclass="$1" column="${2:-status}"
  shift 2
  local statuses=("$@") type base values=() value expr quoted joined

  if [ ${#statuses[@]} -eq 0 ]; then
    printf 'TRUE'
    return 0
  fi

  if ! type="$(background_psql_column_type "$regclass" "$column")"; then
    quoted="$(background_quote_list "${statuses[@]}")"
    printf '%s NOT IN (%s)' "$column" "$quoted"
    return 0
  fi

  if background_status_type_is_numeric "$type"; then
    base="$(background_table_base_name "$regclass")"
    for value in "${statuses[@]}"; do
      if value="$(background_status_numeric_value "$base" "$value")"; then
        values+=("$value")
      fi
    done
    if [ ${#values[@]} -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${values[*]}")
      printf '%s NOT IN (%s)' "$column" "$joined"
      return 0
    fi
    expr="$(background_status_case_expression "$regclass" "$column")"
    quoted="$(background_quote_list "${statuses[@]}")"
    if [ -n "$expr" ] && [ -n "$quoted" ]; then
      printf '%s NOT IN (%s)' "$expr" "$quoted"
      return 0
    fi
    quoted="$(background_quote_list "${statuses[@]}")"
    printf '%s::text NOT IN (%s)' "$column" "$quoted"
    return 0
  fi

  quoted="$(background_quote_list "${statuses[@]}")"
  printf '%s NOT IN (%s)' "$column" "$quoted"
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
  local indent="$1" table_rc query output status_expr status_condition job_status_expr

  if background_psql_table_exists 'public.batched_background_migrations'; then
    status_expr="$(background_status_case_expression 'public.batched_background_migrations' 'status')"
    [ -z "$status_expr" ] && status_expr='status'
    status_condition="$(background_status_filter_condition 'public.batched_background_migrations' 'status' 'finished' 'finalizing' 'finalized')"
    [ -z "$status_condition" ] && status_condition="status NOT IN ('finished','finalizing','finalized')"
    query="SELECT id || ' | ' || job_class_name || ' | ' || table_name || ' | status=' || ${status_expr} || ' | processed=' || COALESCE(processed_tuple_count::text,'?') || '/' || COALESCE(total_tuple_count::text,'?') || ' | updated=' || COALESCE(updated_at::text,'-') FROM batched_background_migrations WHERE ${status_condition} ORDER BY created_at LIMIT 10"
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
      job_status_expr="$(background_status_case_expression 'public.batched_background_migration_jobs' 'status')"
      [ -z "$job_status_expr" ] && job_status_expr='status'
      query="SELECT ${job_status_expr} || ': ' || COUNT(*) FROM batched_background_migration_jobs GROUP BY ${job_status_expr} ORDER BY ${job_status_expr}"
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
  local indent="$1" table_rc query output status_expr status_condition

  if background_psql_table_exists 'public.background_migration_jobs'; then
    status_expr="$(background_status_case_expression 'public.background_migration_jobs' 'status')"
    [ -z "$status_expr" ] && status_expr='status'
    status_condition="$(background_status_filter_condition 'public.background_migration_jobs' 'status' 'succeeded' 'finished')"
    [ -z "$status_condition" ] && status_condition="status NOT IN ('succeeded','finished')"
    query="SELECT id || ' | ' || class_name || ' | status=' || ${status_expr} || ' | attempts=' || COALESCE(attempts::text,'0') || ' | updated=' || COALESCE(updated_at::text,'-') FROM background_migration_jobs WHERE ${status_condition} ORDER BY updated_at DESC LIMIT 10"
    if background_psql "$query"; then
      output="${BACKGROUND_LAST_PSQL_OUTPUT:-}"
      if [[ -n "${output//[[:space:]]/}" ]]; then
        log "${indent}- Записи background_migration_jobs со статусами <> succeeded/finished:"
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
  local indent="$1" status_condition
  status_condition="$(background_status_filter_condition 'public.batched_background_migrations' 'status' 'finished' 'finalizing' 'finalized')"
  [ -z "$status_condition" ] && status_condition="status NOT IN ('finished','finalizing','finalized')"
  log "${indent}- Подсказки по ручной диагностике:"
  log "${indent}  * Проверить sidekiq: docker exec -it ${CONTAINER_NAME} gitlab-ctl tail sidekiq"
  log "${indent}  * Проверить фоновые миграции: docker exec -it ${CONTAINER_NAME} gitlab-psql -d gitlabhq_production -c \"SELECT * FROM batched_background_migrations WHERE ${status_condition};\""
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

background_collect_pending() {
  BACKGROUND_PENDING_TOTAL=0
  BACKGROUND_PENDING_DETAILS=""
  BACKGROUND_PENDING_ERROR_MSG=""
  BACKGROUND_PENDING_BLOCKED=0
  BACKGROUND_PENDING_BLOCKER_MSG=""
  BACKGROUND_PENDING_BATCHED=0
  BACKGROUND_PENDING_BATCHED_JOBS_TOTAL=0
  BACKGROUND_PENDING_LEGACY=0

  local total=0 table_rc=0 query="" count_raw="" trimmed="" status_raw="" job_raw="" job_total="" detail_line=""
  local batched_status_expr="" batched_condition="" batched_job_status_expr="" batched_job_condition=""
  local legacy_status_expr="" legacy_condition=""
  local batched_status_raw="" batched_jobs_status_raw="" legacy_status_raw=""
  local formatted=""
  local batched_table_check="SELECT to_regclass('public.batched_background_migrations')::text"
  local batched_jobs_table_check="SELECT to_regclass('public.batched_background_migration_jobs')::text"
  local legacy_table_check="SELECT to_regclass('public.background_migration_jobs')::text"
  local -a detail_lines=()

  if background_psql_table_exists 'public.batched_background_migrations'; then
    batched_status_expr="$(background_status_case_expression 'public.batched_background_migrations' 'status')"
    [ -z "$batched_status_expr" ] && batched_status_expr='status'
    batched_condition="$(background_status_filter_condition 'public.batched_background_migrations' 'status' 'finished' 'finalizing' 'finalized')"
    [ -z "$batched_condition" ] && batched_condition="status NOT IN ('finished','finalizing','finalized')"
    query="SELECT COUNT(*) FROM batched_background_migrations WHERE ${batched_condition}"
    if background_psql "$query"; then
      count_raw="${BACKGROUND_LAST_PSQL_OUTPUT:-}"
      trimmed="$(printf '%s' "$count_raw" | tr -d '[:space:]')"
      if [[ "$trimmed" =~ ^[0-9]+$ ]]; then
        BACKGROUND_PENDING_BATCHED="$trimmed"
        if [ "$trimmed" -gt 0 ]; then
          total=$((total + trimmed))
          query="SELECT ${batched_status_expr} || '=' || COUNT(*) FROM batched_background_migrations WHERE ${batched_condition} GROUP BY ${batched_status_expr} ORDER BY ${batched_status_expr}"
          if background_psql "$query"; then
            status_raw="$(background_normalize_lines "${BACKGROUND_LAST_PSQL_OUTPUT:-}")"
            batched_status_raw="$status_raw"
            if [ -n "$status_raw" ] && printf '%s\n' "$status_raw" | grep -q '^failed='; then
              background_append_blocker "batched_background_migrations: есть записи со статусом failed"
            fi
            if [ -n "$status_raw" ] && printf '%s\n' "$status_raw" | grep -q '^paused='; then
              background_append_blocker "batched_background_migrations: есть записи со статусом paused"
            fi
          else
            background_append_psql_error "batched_background_migrations" "$query"
          fi
          if background_psql_table_exists 'public.batched_background_migration_jobs'; then
            batched_job_status_expr="$(background_status_case_expression 'public.batched_background_migration_jobs' 'status')"
            [ -z "$batched_job_status_expr" ] && batched_job_status_expr='status'
            batched_job_condition="$(background_status_filter_condition 'public.batched_background_migration_jobs' 'status' 'finished' 'succeeded')"
            [ -z "$batched_job_condition" ] && batched_job_condition="status NOT IN ('finished','succeeded')"
            query="SELECT ${batched_job_status_expr} || '=' || COUNT(*) FROM batched_background_migration_jobs WHERE ${batched_job_condition} GROUP BY ${batched_job_status_expr} ORDER BY ${batched_job_status_expr}"
            if background_psql "$query"; then
              job_raw="$(background_normalize_lines "${BACKGROUND_LAST_PSQL_OUTPUT:-}")"
              batched_jobs_status_raw="$job_raw"
              job_total="$(background_sum_counts "$job_raw")"
              job_total="$(printf '%s' "$job_total" | tr -d '[:space:]')"
              if [[ "$job_total" =~ ^[0-9]+$ ]]; then
                BACKGROUND_PENDING_BATCHED_JOBS_TOTAL="$job_total"
              else
                BACKGROUND_PENDING_BATCHED_JOBS_TOTAL=0
              fi
              if [ -n "$job_raw" ] && printf '%s\n' "$job_raw" | grep -q '^failed='; then
                background_append_blocker "batched_background_migration_jobs: есть задачи со статусом failed"
              fi
            else
              background_append_psql_error "batched_background_migration_jobs" "$query"
            fi
          else
            table_rc=$?
            if [ "$table_rc" -eq 2 ]; then
              background_append_psql_error "batched_background_migration_jobs" "$batched_jobs_table_check"
            fi
          fi
        fi
      else
        background_append_error_msg "batched_background_migrations: неожиданный ответ COUNT(*) — ${count_raw}"
      fi
    else
      background_append_psql_error "batched_background_migrations" "$query"
    fi
  else
    table_rc=$?
    if [ "$table_rc" -eq 2 ]; then
      background_append_psql_error "batched_background_migrations" "$batched_table_check"
    fi
  fi


  if [ "$BACKGROUND_PENDING_BATCHED" -gt 0 ]; then
    detail_line="batched_background_migrations (batched фоновые миграции): ${BACKGROUND_PENDING_BATCHED}"
    formatted=""
    if formatted=$(background_format_status_bullet_lines "$batched_status_raw" '    ' '- '); then
      detail_line+=$'\n'"  Разбивка по статусам:"
      detail_line+=$'\n'"${formatted}"
    fi
    detail_lines+=("$detail_line")
  fi

  if [ "${BACKGROUND_PENDING_BATCHED_JOBS_TOTAL:-0}" -gt 0 ]; then
    detail_line="batched_background_migration_jobs (batched задачи): ${BACKGROUND_PENDING_BATCHED_JOBS_TOTAL}"
    formatted=""
    if formatted=$(background_format_status_bullet_lines "$batched_jobs_status_raw" '    ' '- '); then
      detail_line+=$'\n'"  Разбивка по статусам:"
      detail_line+=$'\n'"${formatted}"
    fi
    detail_lines+=("$detail_line")
  fi

  if background_psql_table_exists 'public.background_migration_jobs'; then
    legacy_status_expr="$(background_status_case_expression 'public.background_migration_jobs' 'status')"
    [ -z "$legacy_status_expr" ] && legacy_status_expr='status'
    legacy_condition="$(background_status_filter_condition 'public.background_migration_jobs' 'status' 'succeeded' 'finished')"
    [ -z "$legacy_condition" ] && legacy_condition="status NOT IN ('succeeded','finished')"
    query="SELECT COUNT(*) FROM background_migration_jobs WHERE ${legacy_condition}"
    if background_psql "$query"; then
      count_raw="${BACKGROUND_LAST_PSQL_OUTPUT:-}"
      trimmed="$(printf '%s' "$count_raw" | tr -d '[:space:]')"
      if [[ "$trimmed" =~ ^[0-9]+$ ]]; then
        BACKGROUND_PENDING_LEGACY="$trimmed"
        if [ "$trimmed" -gt 0 ]; then
          total=$((total + trimmed))
          query="SELECT ${legacy_status_expr} || '=' || COUNT(*) FROM background_migration_jobs WHERE ${legacy_condition} GROUP BY ${legacy_status_expr} ORDER BY ${legacy_status_expr}"
          if background_psql "$query"; then
            status_raw="$(background_normalize_lines "${BACKGROUND_LAST_PSQL_OUTPUT:-}")"
            legacy_status_raw="$status_raw"
            if [ -n "$status_raw" ] && printf '%s\n' "$status_raw" | grep -Eq '^(failed|errored)='; then
              background_append_blocker "background_migration_jobs: есть записи со статусами failed/errored"
            fi
          else
            background_append_psql_error "background_migration_jobs" "$query"
          fi
        fi
      else
        background_append_error_msg "background_migration_jobs: неожиданный ответ COUNT(*) — ${count_raw}"
      fi
    else
      background_append_psql_error "background_migration_jobs" "$query"
    fi
  else
    table_rc=$?
    if [ "$table_rc" -eq 2 ]; then
      background_append_psql_error "background_migration_jobs" "$legacy_table_check"
    fi
  fi


  if [ "$BACKGROUND_PENDING_LEGACY" -gt 0 ]; then
    detail_line="background_migration_jobs (legacy фоновые миграции): ${BACKGROUND_PENDING_LEGACY}"
    formatted=""
    if formatted=$(background_format_status_bullet_lines "$legacy_status_raw" '    ' '- '); then
      detail_line+=$'\n'"  Разбивка по статусам:"
      detail_line+=$'\n'"${formatted}"
    fi
    detail_lines+=("$detail_line")
  fi

  BACKGROUND_PENDING_TOTAL=$total
  if [ ${#detail_lines[@]} -gt 0 ]; then
    BACKGROUND_PENDING_DETAILS=$(printf '%s\n' "${detail_lines[@]}")
  else
    BACKGROUND_PENDING_DETAILS=""
  fi

  if [ -n "$BACKGROUND_PENDING_ERROR_MSG" ]; then
    return 2
  fi

  if [ "$total" -gt 0 ]; then
    return 1
  fi

  return 0
}

background_wait_for_completion() {
  local context="$1"
  local interval="${BACKGROUND_WAIT_INTERVAL:-60}"
  local report_every="${BACKGROUND_WAIT_REPORT_EVERY:-5}"
  local progress_interval="${BACKGROUND_WAIT_PROGRESS_INTERVAL:-300}"
  local start_ts now waited attempt=0 report_counter=0 last_signature="" last_log_ts=0 signature="" should_log=0 last_total=-1
  local message="" total="0" context_note=""

  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -le 0 ]; then
    interval=60
  fi
  if ! [[ "$report_every" =~ ^[0-9]+$ ]]; then
    report_every=5
  fi
  if ! [[ "$progress_interval" =~ ^[0-9]+$ ]] || [ "$progress_interval" -le 0 ]; then
    progress_interval=$((interval * 5))
  fi
  if [ "$progress_interval" -lt "$interval" ]; then
    progress_interval=$interval
  fi
  if [ -n "$context" ]; then
    context_note=" (контекст: ${context})"
  fi

  log "[>] Проверка фоновых миграций${context:+ (${context})}..."
  start_ts=$(date +%s)

  while true; do
    background_collect_pending
    case $? in
      0)
        if [ "$attempt" -gt 0 ]; then
          waited=$(( $(date +%s) - start_ts ))
          ok "Фоновые миграции завершены${context:+ (${context})} (ожидание $(format_duration "$waited"))"
        else
          ok "Фоновые миграции уже завершены${context:+ (${context})}"
        fi
        return 0
        ;;
      1)
        if [ "${BACKGROUND_PENDING_BLOCKED:-0}" -eq 1 ]; then
          err "Фоновые миграции заблокированы и требуют вмешательства${context_note}"
          if [ -n "$BACKGROUND_PENDING_BLOCKER_MSG" ]; then
            printf '%s\n' "$BACKGROUND_PENDING_BLOCKER_MSG" | indent_with_prefix "    "
          fi
          if [ -n "$BACKGROUND_PENDING_DETAILS" ]; then
            printf '%s\n' "$BACKGROUND_PENDING_DETAILS" | indent_with_prefix "    "
          fi
          background_migrations_status_report "    " || true
          return 1
        fi
        now=$(date +%s)
        waited=$((now - start_ts))
        total="${BACKGROUND_PENDING_TOTAL:-0}"
        signature="${total}|${BACKGROUND_PENDING_DETAILS}"
        should_log=0
        if [ "$last_signature" != "$signature" ] || [ "$last_log_ts" -eq 0 ]; then
          should_log=1
        elif [ $((now - last_log_ts)) -ge "$progress_interval" ]; then
          should_log=1
        fi
        if [ "$should_log" -eq 1 ]; then
          message="[wait] Фоновые миграции ещё выполняются — всего ${total}; ожидание $(format_duration "$waited")${context_note}"
          if [ "$last_total" -ge 0 ] && [ "$total" -lt "$last_total" ]; then
            message+=" (прогресс: ${last_total} → ${total})"
          elif [ "$last_total" -eq "$total" ] && [ "$total" -gt 0 ] && [ "$last_log_ts" -ne 0 ]; then
            message+=" (без изменений)"
          fi
          log "$message"
          if [ -n "$BACKGROUND_PENDING_DETAILS" ]; then
            printf '%s\n' "$BACKGROUND_PENDING_DETAILS" | indent_with_prefix "        "
          fi
          report_counter=$((report_counter + 1))
          if [ "$report_counter" -eq 1 ] || { [ "$report_every" -gt 0 ] && [ $((report_counter % report_every)) -eq 0 ]; }; then
            background_migrations_status_report "    " || true
          fi
          last_signature="$signature"
          last_log_ts=$now
          last_total=$total
        fi
        attempt=$((attempt + 1))
        sleep "$interval"
        ;;
      2)
        err "Не удалось получить статус фоновых миграций${context_note}"
        if [ -n "$BACKGROUND_PENDING_ERROR_MSG" ]; then
          log "  Подробности:"
          printf '%s\n' "$BACKGROUND_PENDING_ERROR_MSG" | indent_with_prefix "    "
        fi
        background_migrations_extra_diagnostics "    " || true
        return 1
        ;;
    esac
  done
}
