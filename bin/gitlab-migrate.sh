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

LOG_DIR="$BASEDIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/gitlab-migrate-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

LOCK_FILE="$BASEDIR/gitlab-migrate.pid"
FORCE_CLEAN=0

. "$BASEDIR/lib/runtime.sh"

cleanup_previous_run


main() {
  for arg in "$@"; do
    case $arg in
      --reset|-r) reset_migration ;;
      --clean|-c) FORCE_CLEAN=1 ;;
      --help|-h)
        echo "Использование: $0 [--reset|-r] [--clean|-c] [--help|-h]"
        echo "  --reset, -r  Сбросить миграцию и начать заново"
        echo "  --clean, -c  Очистить каталоги /srv/gitlab без вопросов"
        echo "  --help,  -h  Показать эту справку"
        exit 0 ;;
    esac
  done

  need_root; need_cmd docker; docker_ok || { err "Docker daemon недоступен"; exit 1; }
  state_init

  log "[i] Лог выполнения (host): $LOG_FILE"
  log "[i] Логи GitLab на хосте: $DATA_ROOT/logs"

  ensure_dirs
  restore_from_local_snapshot
  import_backup_and_config

  local base_ver base_tag running_image running_tag
  base_ver="$(get_state BASE_VER)"
  base_tag="$(get_state BASE_IMAGE_TAG || true)"

  if container_running; then
    running_image="$(current_image_tag)"
    running_image="${running_image//$'\n'/}"; running_image="${running_image//$'\r'/}"
    if [ -n "$running_image" ]; then
      running_tag="${running_image#gitlab/gitlab-ce:}"
      [ -n "$running_tag" ] || running_tag="$running_image"
      if [ -z "$base_tag" ]; then
        base_tag="$running_tag"
        set_state BASE_IMAGE_TAG "$base_tag"
        log "[i] Сохраняю текущий образ контейнера в state: gitlab/gitlab-ce:${base_tag}"
      elif [ "$running_tag" != "$base_tag" ]; then
        log "[i] Контейнер уже запущен с образом gitlab/gitlab-ce:${running_tag}; обновляю BASE_IMAGE_TAG (было ${base_tag})"
        base_tag="$running_tag"
        set_state BASE_IMAGE_TAG "$base_tag"
      fi
    fi
  fi

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

  ensure_permissions

  wait_gitlab_ready
  wait_postgres_ready
  log "[>] Версия PostgreSQL в контейнере:"
  dexec 'gitlab-psql --version 2>/dev/null || psql --version' || true

  restore_backup_if_needed

  if [ "$(get_state RESTORE_DONE || true)" != "1" ]; then
    verify_restore_success
  else
    ok "Проверка восстановления уже выполнена — пропускаю"
  fi

  manual_checkpoint "после восстановления данных GitLab" "RESTORE_CONFIRMED"

  if ensure_initial_snapshot; then
    exit 0
  fi

  log "[>] Формирую «лестницу» апгрейдов…"
  mapfile -t stops < <(compute_stops)
  echo "  → ${stops[*]} (будут разрешены до latest patch)" >&2

  local cur_ver_raw cur_ver target_tag target_version s
  for s in "${stops[@]}"; do
    cur_ver_raw="$(dexec 'cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo 0.0.0')"
    cur_ver="$(normalize_version_string "$cur_ver_raw")"
    target_tag="$(latest_patch_tag "$s")"
    target_version="$(normalize_version_string "$target_tag")"

    if version_ge "$cur_ver" "$target_version"; then
      ok "Текущая ${cur_ver:-unknown} >= ${target_version} — пропускаю"; continue
    fi
    upgrade_to_series "$s"
    pause_after_upgrade_step "$(get_state LAST_UPGRADED_TO || true)"
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
