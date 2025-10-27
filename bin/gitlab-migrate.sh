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
. "$BASEDIR/lib/background.sh"
. "$BASEDIR/lib/chef.sh"
. "$BASEDIR/lib/dirs.sh"
. "$BASEDIR/lib/backup.sh"
. "$BASEDIR/lib/upgrade.sh"

LOG_DIR="$BASEDIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/gitlab-migrate-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

LOCK_FILE="$BASEDIR/gitlab-migrate.pid"
FORCE_CLEAN=0
CLEANUP_LADDER=0

. "$BASEDIR/lib/runtime.sh"

cleanup_previous_run


trim_spaces() {
  local value="$1"
  local trimmed="$value"

  trimmed="${trimmed#${trimmed%%[![:space:]]*}}"
  trimmed="${trimmed%${trimmed##*[![:space:]]}}"

  printf '%s' "$trimmed"
}

print_active_container_summary() {
  local info id status running health image command ports fmt=""

  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$CONTAINER_NAME"; then
    warn "Контейнер ${CONTAINER_NAME} не найден на хосте"
    return 1
  fi

  printf -v fmt '{{.Id}}\t{{.State.Status}}\t{{if .State.Running}}1{{else}}0{{end}}\t{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}\t{{.Config.Image}}\t{{.Path}}{{range .Args}} {{.}}{{end}}'
  info=$(docker inspect -f "$fmt" "$CONTAINER_NAME" 2>/dev/null || true)
  if [ -z "$info" ]; then
    warn "Не удалось получить сведения о контейнере ${CONTAINER_NAME}"
    return 1
  fi

  IFS=$'\t' read -r id status running health image command <<< "$info"
  command="$(trim_spaces "$command")"
  local running_label="нет"
  [ "$running" = "1" ] && running_label="да"

  log "[>] Текущий контейнер: ${CONTAINER_NAME} (${id:0:12})"
  log "    Статус: ${status} (running=${running_label}); health: ${health}"
  log "    Образ: ${image}"
  if [ -n "$command" ]; then
    log "    Команда: ${command}"
  fi

  ports="$(docker_container_port_bindings "$CONTAINER_NAME" | sed '/^$/d')"
  if [ -n "$ports" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      log "    Порт: ${line}"
    done <<< "$ports"
  else
    log "    Порты: пробросы не обнаружены или контейнер остановлен"
  fi
}

cleanup_ladder_containers() {
  local -a raw_containers=() stale_containers=()
  local -a keep_image_refs=() keep_image_ids=() keep_image_notes=()
  local entry id raw_name name image status running health command created id_short
  local skip_image_cleanup=0

  local current_image current_image_id last_upgraded_tag keep_note

  current_image="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  current_image_id="$(docker inspect -f '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  last_upgraded_tag="$(get_state LAST_UPGRADED_TO || true)"

  if [ -n "$current_image" ]; then
    keep_image_refs+=("$current_image")
    keep_note="контейнер ${CONTAINER_NAME}: ${current_image}"
    keep_image_notes+=("$keep_note")
  fi

  if [ -n "$current_image_id" ]; then
    keep_image_ids+=("$current_image_id")
    if [ -z "$current_image" ]; then
      keep_note="контейнер ${CONTAINER_NAME}: ${current_image_id}"
      keep_image_notes+=("$keep_note")
    fi
  fi

  if [ -n "$last_upgraded_tag" ]; then
    local last_ref="gitlab/gitlab-ce:${last_upgraded_tag}"
    if [[ "$last_upgraded_tag" == */* ]]; then
      last_ref="$last_upgraded_tag"
    fi
    keep_image_refs+=("$last_ref")
    keep_image_notes+=("state LAST_UPGRADED_TO: ${last_ref}")
  fi

  mapfile -t raw_containers < <(docker_containers_using_data_root 2>/dev/null || true)

  for entry in "${raw_containers[@]}"; do
    IFS=$'\t' read -r id raw_name image status running health command created <<< "$entry"
    name="${raw_name#/}"
    command="$(trim_spaces "$command")"

    if [ "$name" = "$CONTAINER_NAME" ]; then
      continue
    fi

    printf -v entry '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$id" "$name" "$image" "$status" "$running" "$health" "$command" "$created"
    stale_containers+=("$entry")
  done

  if [ "${#stale_containers[@]}" -eq 0 ]; then
    ok "Старые контейнеры GitLab, связанные с ${DATA_ROOT}, не найдены"
  else
    log "[>] Найдены контейнеры GitLab, использующие ${DATA_ROOT} (возможно из лестницы апгрейдов): ${#stale_containers[@]} шт."
    for entry in "${stale_containers[@]}"; do
      IFS=$'\t' read -r id name image status running health command created <<< "$entry"
      id_short="${id:0:12}"
      local running_label="нет"
      [ "$running" = "1" ] && running_label="да"
      log "  - ${name} (${id_short}) — образ ${image}, статус ${status} (running=${running_label}), health=${health}"
      if [ -n "$command" ]; then
        log "    Команда: ${command}"
      fi
      log "    Создан: ${created}"
    done

    if ask_yes_no "Удалить перечисленные контейнеры?" "n"; then
      for entry in "${stale_containers[@]}"; do
        IFS=$'\t' read -r id name image status running health command created <<< "$entry"
        if docker rm -f "$name" >/dev/null 2>&1; then
          ok "Удалён контейнер ${name} (${id:0:12})"
        else
          warn "Не удалось удалить контейнер ${name}"
        fi
      done
      ok "Очистка контейнеров завершена"
    else
      warn "Удаление контейнеров отменено пользователем"
      skip_image_cleanup=1
    fi
  fi

  if [ "$skip_image_cleanup" -eq 1 ]; then
    print_active_container_summary || true
    return 0
  fi

  if [ "${#keep_image_refs[@]}" -eq 0 ] && [ "${#keep_image_ids[@]}" -eq 0 ]; then
    warn "Не удалось определить актуальный образ GitLab — очистка образов пропущена"
    print_active_container_summary || true
    return 0
  fi

  if [ "${#keep_image_notes[@]}" -gt 0 ]; then
    log "[>] Образы, которые будут сохранены:"
    for keep_note in "${keep_image_notes[@]}"; do
      log "    - ${keep_note}"
    done
  fi

  local -a raw_images=() stale_images=()
  local -A seen_image_ids=()
  mapfile -t raw_images < <(docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' 'gitlab/gitlab-ce' 2>/dev/null || true)

  if [ "${#raw_images[@]}" -eq 0 ]; then
    ok "Локальные образы gitlab/gitlab-ce отсутствуют"
    print_active_container_summary || true
    return 0
  fi

  for entry in "${raw_images[@]}"; do
    [ -n "$entry" ] || continue
    local repo_tag image_id size keep_flag=0
    IFS=$'\t' read -r repo_tag image_id size <<< "$entry"
    [ -n "$image_id" ] || continue
    if [ -n "${seen_image_ids[$image_id]:-}" ]; then
      continue
    fi
    seen_image_ids[$image_id]=1

    for keep_note in "${keep_image_refs[@]}"; do
      if [ -n "$keep_note" ] && [ "$repo_tag" = "$keep_note" ]; then
        keep_flag=1
        break
      fi
    done

    if [ "$keep_flag" -eq 0 ]; then
      for keep_note in "${keep_image_ids[@]}"; do
        if [ -n "$keep_note" ] && [ "$image_id" = "$keep_note" ]; then
          keep_flag=1
          break
        fi
      done
    fi

    if [ "$keep_flag" -eq 1 ]; then
      continue
    fi

    printf -v entry '%s\t%s\t%s' "$repo_tag" "$image_id" "$size"
    stale_images+=("$entry")
  done

  if [ "${#stale_images[@]}" -eq 0 ]; then
    ok "Все локальные образы gitlab/gitlab-ce соответствуют актуальным версиям — удаление не требуется"
    print_active_container_summary || true
    return 0
  fi

  log "[>] Найдены неиспользуемые образы gitlab/gitlab-ce: ${#stale_images[@]} шт."
  for entry in "${stale_images[@]}"; do
    local repo_tag image_id size short_id
    IFS=$'\t' read -r repo_tag image_id size <<< "$entry"
    short_id="${image_id#sha256:}"
    short_id="${short_id:0:12}"
    log "  - ${repo_tag} (${short_id}) — размер ${size}"
  done

  if ! ask_yes_no "Удалить перечисленные образы GitLab?" "n"; then
    warn "Удаление образов отменено пользователем"
    print_active_container_summary || true
    return 0
  fi

  for entry in "${stale_images[@]}"; do
    local repo_tag image_id size short_id
    IFS=$'\t' read -r repo_tag image_id size <<< "$entry"
    short_id="${image_id#sha256:}"
    short_id="${short_id:0:12}"
    if docker image rm "$image_id" >/dev/null 2>&1; then
      ok "Удалён образ ${repo_tag} (${short_id})"
    else
      warn "Не удалось удалить образ ${repo_tag} (${short_id})"
    fi
  done

  ok "Очистка образов завершена"
  print_active_container_summary || true
}


main() {
  for arg in "$@"; do
    case $arg in
      --reset|-r) reset_migration ;;
      --clean|-c) FORCE_CLEAN=1 ;;
      --cleanup-ladder) CLEANUP_LADDER=1 ;;
      --help|-h)
        echo "Использование: $0 [--reset|-r] [--clean|-c] [--cleanup-ladder] [--help|-h]"
        echo "  --reset, -r         Сбросить миграцию и начать заново"
        echo "  --clean, -c         Очистить каталоги /srv/gitlab без вопросов"
        echo "  --cleanup-ladder    Удалить старые контейнеры и образы GitLab, оставшиеся после лестницы"
        echo "  --help,  -h         Показать эту справку"
        exit 0 ;;
    esac
  done

  need_root; need_cmd docker; docker_ok || { err "Docker daemon недоступен"; exit 1; }

  if [ "$CLEANUP_LADDER" -eq 1 ]; then
    cleanup_ladder_containers
    return
  fi

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

  if ! wait_gitlab_ready; then
    err "GitLab не стал доступен после запуска базового контейнера"
    exit 1
  fi
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

  if ! background_wait_for_completion "перед построением лестницы апгрейдов"; then
    err "Фоновые миграции не завершены — прерываю выполнение"
    exit 1
  fi

  log "[>] Формирую «лестницу» апгрейдов…"
  log "  Целевая версия (максимум): $(target_version_cutoff)"
  mapfile -t stops < <(compute_stops)
  log "  Запланированные остановки (серия → патч):"
  local stop_metadata
  for s in "${stops[@]}"; do
    stop_metadata="$(describe_upgrade_stop "$s")"
    log "    - ${stop_metadata}"
  done

  local -a skipped_optionals=()
  mapfile -t skipped_optionals < <(get_skipped_optional_stops)
  if [ "${#skipped_optionals[@]}" -gt 0 ]; then
    warn "Условные остановки, пропущенные согласно INCLUDE_OPTIONAL_STOPS='${INCLUDE_OPTIONAL_STOPS:-yes}':"
    for s in "${skipped_optionals[@]}"; do
      stop_metadata="$(describe_upgrade_stop "$s")"
      log "      * ${stop_metadata}"
    done
  fi

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
  if ! wait_gitlab_ready; then
    err "GitLab не стал доступен после всех апгрейдов"
    exit 1
  fi
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
  log "[hint] Для удаления временных контейнеров и образов лестницы выполни: $0 --cleanup-ladder"
}

trap error_trap ERR

main "$@"
