#!/usr/bin/env bash
set -Eeuo pipefail

# Determine base directory (../ from bin)
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source config
# shellcheck disable=SC1091
. "$BASEDIR/conf/settings.env"

# Source libs
. "$BASEDIR/lib/log.sh"
. "$BASEDIR/lib/state.sh"
. "$BASEDIR/lib/docker.sh"
. "$BASEDIR/lib/dirs.sh"
. "$BASEDIR/lib/backup.sh"
. "$BASEDIR/lib/upgrade.sh"

reset_migration() {
  log "[!] Сброс миграции: удаление контейнеров, данных и состояния"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [ -d "$DATA_ROOT" ]; then
    log "[>] Очистка директории данных: $DATA_ROOT"
    rm -rf "$DATA_ROOT"/*
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
  repo_size=$(dexec 'du -sh /var/opt/gitlab/git-data/repositories | cut -f1' 2>/dev/null || echo "unknown"')
  db_size=$(dexec 'du -sh /var/opt/gitlab/postgresql/data | cut -f1' 2>/dev/null || echo "unknown"')
  
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

error_trap() {
  warn "Ошибка на шаге. См. статус служб ниже:"
  (dexec "gitlab-ctl status" || true) 2>&1 | sed -e "s/^/[status] /" >&2
  log "[status] ------ Последние строки docker logs ------"
  docker logs --tail 20 "$CONTAINER_NAME" 2>&1 | sed -e "s/^/[status] /" >&2 || true
  log "[status] ------ Последние строки chef-client.log ------"
  docker exec -i "$CONTAINER_NAME" tail -n 20 /var/log/gitlab/chef-client.log 2>&1 | sed -e "s/^/[status] /" >&2 || true
  log "[status] ------ Последние строки reconfigure.log ------"
  docker exec -i "$CONTAINER_NAME" tail -n 20 /var/log/gitlab/reconfigure.log 2>&1 | sed -e "s/^/[status] /" >&2 || true
}

main() {
  for arg in "$@"; do
    case $arg in
      --reset|-r) reset_migration ;;
      --help|-h)
        echo "Использование: $0 [--reset|-r] [--help|-h]"
        echo "  --reset, -r  Сбросить миграцию и начать заново"
        echo "  --help,  -h  Показать эту справку"
        exit 0 ;;
    esac
  done

  need_root; need_cmd docker; docker_ok || { err "Docker daemon недоступен"; exit 1; }
  state_init

  ensure_dirs
  import_backup_and_config

  local base_ver base_tag
  base_ver="$(get_state BASE_VER)"
  base_tag="$(get_state BASE_IMAGE_TAG || true)"

  if [ -z "${base_tag// }" ]; then
    base_tag="$(resolve_and_pull_base_image "$base_ver")"
    base_tag="$(printf "%s" "$base_tag" | tr -d '\n')"; set_state BASE_IMAGE_TAG "$base_tag"
  else
    ok "Использую образ (из state): gitlab/gitlab-ce:${base_tag}"
    if ! docker image inspect "gitlab/gitlab-ce:${base_tag}" >/dev/null 2>&1; then
      warn "BASE_IMAGE_TAG='${base_tag}' не найден локально/битый — переопределяю"
      base_tag="$(resolve_and_pull_base_image "$base_ver")"
      base_tag="$(printf "%s" "$base_tag" | tr -d '\n')"; set_state BASE_IMAGE_TAG "$base_tag"
    fi
  fi

  if [ "$(get_state BASE_STARTED || true)" != "1" ]; then
    run_container "$base_tag"
    set_state BASE_STARTED 1
  else
    ok "Базовый контейнер уже стартовал — пропускаю запуск"; show_versions
  fi

  wait_gitlab_ready
  wait_postgres_ready

  restore_backup_if_needed

  if [ "$(get_state RESTORE_DONE || true)" != "1" ]; then
    verify_restore_success
  else
    ok "Проверка восстановления уже выполнена — пропускаю"
  fi

  log "[>] Формирую «лестницу» апгрейдов…"
  mapfile -t stops < <(compute_stops)
  echo "  → ${stops[*]} (будут разрешены до latest patch)" >&2

  local cur_ver s sM sm cM cm
  for s in "${stops[@]}"; do
    cur_ver="$(dexec 'cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo 0.0.0')"
    if [[ "$s" =~ ^[0-9]+\.[0-9]+$ ]]; then
      sM="${s%%.*}"; sm="${s##*.}"
      cM="${cur_ver%%.*}"; cm="$(echo "$cur_ver" | cut -d. -f2)"
      if { [ "$cM" -gt "$sM" ] || { [ "$cM" -eq "$sM" ] && [ "$cm" -gt "$sm" ]; }; }; then
        ok "Текущая $cur_ver >= ${s}.x — пропускаю"; continue
      fi
    elif [ "$s" = "17" ]; then
      cM="${cur_ver%%.*}"; [ "$cM" -ge 17 ] && { ok "Текущая $cur_ver >= 17.x — пропускаю"; continue; }
    fi
    upgrade_to_series "$s"
  done

  log "[>] Финальная проверка после всех апгрейдов…"
  wait_gitlab_ready
  wait_postgres_ready

  log "[>] Итоговая информация:"
  log "  - Текущая версия GitLab: $(dexec 'cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo unknown')"
  log "  - Количество проектов: $(dexec 'gitlab-psql -d gitlabhq_production -t -c \"SELECT COUNT(*) FROM projects;\" 2>/dev/null | tr -d \"[:space:]\" || echo unknown')"
  log "  - Количество пользователей: $(dexec 'gitlab-psql -d gitlabhq_production -t -c \"SELECT COUNT(*) FROM users;\" 2>/dev/null | tr -d \"[:space:]\" || echo unknown')"

  log "[>] Проверка состояния служб:"
  dexec 'gitlab-ctl status' || true

  ok "ГОТОВО. Состояние: $STATE_FILE"
  log "Открой: https://<твой-домен>:${PORT_HTTPS}  (или http :${PORT_HTTP})"

  generate_migration_report
}

trap error_trap ERR

main "$@"
