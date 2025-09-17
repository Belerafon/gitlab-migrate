# lib/stats.sh
# shellcheck shell=bash

# Run a query against gitlabhq_production and return the first non-empty row.
# If the query fails or returns nothing, fallback value is returned instead.
gitlab_psql_query() {
  local query="$1" fallback="${2:-unknown}" raw trimmed escaped_query

  escaped_query=$(printf '%q' "$query")
  raw=$({ dexec "gitlab-psql -d gitlabhq_production -t -c $escaped_query" 2>/dev/null || true; })

  trimmed=$(printf '%s\n' "$raw" \
    | awk 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' 2>/dev/null || true)

  if [ -z "${trimmed//[[:space:]]/}" ]; then
    printf '%s' "$fallback"
  else
    printf '%s' "$trimmed"
  fi
}

# Determine if a raw statistic value (prior to formatting) contains data.
stats_value_available() {
  local value="$1"
  [[ -n "${value//[[:space:]]/}" && "$value" != "unknown" ]]
}

# Format statistic for display (convert empty/unknown to н/д).
stats_format_value() {
  local value="$1"
  if stats_value_available "$value"; then
    printf '%s' "$value"
  else
    printf '%s' "н/д"
  fi
}

# Helper to check if a statistic is a non-negative integer.
stats_value_is_number() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]]
}

# Collect GitLab statistics into the provided associative array reference.
# shellcheck disable=SC2154
collect_gitlab_stats() {
  local -n _dest=$1
  _dest=()

  _dest[projects_total]=$(gitlab_psql_query "SELECT COUNT(*) FROM projects;" "unknown")
  _dest[repositories_with_data]=$(gitlab_psql_query "SELECT COUNT(*) FROM project_statistics WHERE COALESCE(repository_size,0) > 0;" "unknown")
  _dest[groups_total]=$(gitlab_psql_query "SELECT COUNT(*) FROM namespaces WHERE type = 'Group';" "unknown")
  _dest[users_total]=$(gitlab_psql_query "SELECT COUNT(*) FROM users;" "unknown")
  _dest[users_active]=$(gitlab_psql_query "SELECT COUNT(*) FROM users WHERE state = 'active';" "unknown")
  _dest[issues_total]=$(gitlab_psql_query "SELECT COUNT(*) FROM issues;" "unknown")
  _dest[merge_requests_total]=$(gitlab_psql_query "SELECT COUNT(*) FROM merge_requests;" "unknown")
  _dest[db_size]=$(gitlab_psql_query "SELECT pg_size_pretty(pg_database_size('gitlabhq_production'));" "unknown")
  _dest[storage_total]=$(gitlab_psql_query "SELECT pg_size_pretty(COALESCE(SUM(storage_size),0)) FROM project_statistics;" "unknown")
  _dest[repos_size]=$(gitlab_psql_query "SELECT pg_size_pretty(COALESCE(SUM(repository_size),0)) FROM project_statistics;" "unknown")
  _dest[wiki_size]=$(gitlab_psql_query "SELECT pg_size_pretty(COALESCE(SUM(wiki_size),0)) FROM project_statistics;" "unknown")
  _dest[lfs_size]=$(gitlab_psql_query "SELECT pg_size_pretty(COALESCE(SUM(lfs_objects_size),0)) FROM project_statistics;" "unknown")
  _dest[artifacts_size]=$(gitlab_psql_query "SELECT pg_size_pretty(COALESCE(SUM(build_artifacts_size),0)) FROM project_statistics;" "unknown")
  _dest[packages_size]=$(gitlab_psql_query "SELECT pg_size_pretty(COALESCE(SUM(packages_size),0)) FROM project_statistics;" "unknown")
  _dest[uploads_size]=$(gitlab_psql_query "SELECT pg_size_pretty(COALESCE(SUM(uploads_size),0)) FROM project_statistics;" "unknown")
  _dest[snippets_size]=$(gitlab_psql_query "SELECT pg_size_pretty(COALESCE(SUM(snippets_size),0)) FROM project_statistics;" "unknown")
}

# Pretty-print the collected statistics using the provided associative array.
print_gitlab_stats() {
  local -n _stats=$1
  local indent="${2:-  }"
  local subindent="${indent}  "

  local projects_line users_line issues_value mr_value
  local repos_data_raw="${_stats[repositories_with_data]-}"

  projects_line="$(stats_format_value "${_stats[projects_total]-}")"
  if stats_value_available "$repos_data_raw"; then
    projects_line+=" (репозиториев с данными: $(stats_format_value "$repos_data_raw"))"
  fi
  log "${indent}- Проекты: ${projects_line}"

  users_line="$(stats_format_value "${_stats[users_total]-}")"
  if stats_value_available "${_stats[users_active]-}"; then
    users_line+=" (активные: $(stats_format_value "${_stats[users_active]-}"))"
  fi
  log "${indent}- Пользователи: ${users_line}"

  if stats_value_available "${_stats[groups_total]-}"; then
    log "${indent}- Группы: $(stats_format_value "${_stats[groups_total]-}")"
  fi

  issues_value=$(stats_format_value "${_stats[issues_total]-}")
  mr_value=$(stats_format_value "${_stats[merge_requests_total]-}")
  log "${indent}- Ишью: ${issues_value}"
  log "${indent}- Merge Requests: ${mr_value}"

  log "${indent}- Размер базы данных: $(stats_format_value "${_stats[db_size]-}")"

  if stats_value_available "${_stats[storage_total]-}"; then
    log "${indent}- Суммарный размер хранилищ проектов: $(stats_format_value "${_stats[storage_total]-}")"
  fi

  if stats_value_available "${_stats[repos_size]-}"; then
    log "${subindent}· Репозитории: $(stats_format_value "${_stats[repos_size]-}")"
  fi
  if stats_value_available "${_stats[wiki_size]-}"; then
    log "${subindent}· Вики: $(stats_format_value "${_stats[wiki_size]-}")"
  fi
  if stats_value_available "${_stats[lfs_size]-}"; then
    log "${subindent}· LFS: $(stats_format_value "${_stats[lfs_size]-}")"
  fi
  if stats_value_available "${_stats[artifacts_size]-}"; then
    log "${subindent}· Артефакты: $(stats_format_value "${_stats[artifacts_size]-}")"
  fi
  if stats_value_available "${_stats[packages_size]-}"; then
    log "${subindent}· Пакеты: $(stats_format_value "${_stats[packages_size]-}")"
  fi
  if stats_value_available "${_stats[uploads_size]-}"; then
    log "${subindent}· Загрузки: $(stats_format_value "${_stats[uploads_size]-}")"
  fi
  if stats_value_available "${_stats[snippets_size]-}"; then
    log "${subindent}· Сниппеты: $(stats_format_value "${_stats[snippets_size]-}")"
  fi
}
