# lib/backup.sh
# shellcheck shell=bash
# Source docker lib for container_running function
. "$BASEDIR/lib/docker.sh"
# Chef helpers for сжатого вывода reconfigure
. "$BASEDIR/lib/chef.sh"

summarize_reconfigure_log() {
  local log_file="$1" outcome="${2:-успех}" max_changed_preview=8 max_stage_lines=10

  if [ ! -f "$log_file" ]; then
    warn "[chef] Лог reconfigure не найден: ${log_file}"
    return
  fi

  log "[chef] Сводка gitlab-ctl reconfigure (${outcome}):"

  local chef_summary
  chef_summary=$(awk '/Chef Infra Client (finished|failed)/ {line=$0} END {if (length(line)) print line}' "$log_file" 2>/dev/null || true)
  if [ -n "$chef_summary" ]; then
    log "    - ${chef_summary}"
  else
    log "    - Итоговая строка Chef не найдена (см. лог)"
  fi

  local chef_updated chef_total
  chef_updated=$(awk 'match($0, /Chef Infra Client finished, ([0-9]+)\/([0-9]+) resources updated/, m) {updated=m[1]; total=m[2]} END {if (updated == "") updated="unknown"; print updated}' "$log_file" 2>/dev/null || true)
  chef_total=$(awk 'match($0, /Chef Infra Client finished, ([0-9]+)\/([0-9]+) resources updated/, m) {updated=m[1]; total=m[2]} END {if (total == "") total="unknown"; print total}' "$log_file" 2>/dev/null || true)
  if [ "$chef_updated" != "unknown" ] && [ "$chef_total" != "unknown" ]; then
    log "    - Обновлено ресурсов (по Chef): ${chef_updated}/${chef_total}"
  fi

  local changed_lines changed_count
  mapfile -t changed_lines < <(awk '
    function flush_current() {
      if (length(current_line) == 0) {
        return
      }
      if (state == "changed") {
        line=current_line
        sub(/^[[:space:]]+/, "", line)
        if (!seen[line]++) {
          list[count++] = line
        }
      }
      current_line=""
      state="unknown"
    }

    /^[[:space:]]*\*/ && / action / {
      flush_current()
      if ($0 ~ /\(up to date\)/) next
      if ($0 ~ /\(skipped/)) next
      current_line=$0
      state="unknown"
      next
    }

    {
      if (length(current_line) == 0) {
        next
      }
      if ($0 ~ /\(up to date\)/ || $0 ~ /\(skipped/)) {
        if (state != "changed") {
          state="noop"
        }
      }
      if ($0 ~ /^[[:space:]]*-/) {
        state="changed"
      }
    }

    END {
      flush_current()
      for (i = 0; i < count; i++) print list[i]
    }
  ' "$log_file" 2>/dev/null)
  changed_count=${#changed_lines[@]}
  if [ "$changed_count" -gt 0 ]; then
    log "    - Ресурсы с изменениями (по анализу лога): ${changed_count}"
    local limit=$max_changed_preview
    if [ "$changed_count" -lt "$limit" ]; then
      limit=$changed_count
    fi
    local i
    for ((i = 0; i < limit; i++)); do
      log "        • ${changed_lines[$i]}"
    done
    if [ "$changed_count" -gt "$limit" ]; then
      log "        … и ещё $((changed_count - limit)) ресурсов (см. полный лог)"
    fi
  else
    log "    - Ресурсы с изменениями не обнаружены (по анализу лога)"
  fi

  local skipped_count up_to_date_count
  skipped_count=$(awk 'BEGIN {c=0} /\(skipped due to/ {c++} END {print c}' "$log_file" 2>/dev/null || true)
  up_to_date_count=$(awk 'BEGIN {c=0} /\(up to date\)/ {c++} END {print c}' "$log_file" 2>/dev/null || true)
  log "    - Пропущено ресурсов (skip): ${skipped_count}"
  log "    - Уже в актуальном состоянии (up to date): ${up_to_date_count}"

  local stage_lines=()
  mapfile -t stage_lines < <(awk '
    /^[[:space:]]*(Running reconfigure|Waiting for Database|Database upgrade is complete|Toggling deploy page|Toggling services|==== Upgrade has completed ====|Please verify everything is working)/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      print line
    }
  ' "$log_file" 2>/dev/null)
  if [ ${#stage_lines[@]} -gt 0 ]; then
    log "    - Ключевые статусы:" 
    local start=0 total=${#stage_lines[@]}
    if [ "$total" -gt "$max_stage_lines" ]; then
      start=$((total - max_stage_lines))
    fi
    local i
    for ((i = start; i < total; i++)); do
      log "        ${stage_lines[$i]}"
    done
  fi

  local warnings=()
  mapfile -t warnings < <(awk 'BEGIN {IGNORECASE=1} /warn|error|fatal|critical/ {print}' "$log_file" 2>/dev/null | tail -n5)
  if [ ${#warnings[@]} -gt 0 ]; then
    log "    - Последние предупреждения/ошибки:"
    local w
    for w in "${warnings[@]}"; do
      log "        ${w}"
    done
  fi

  log "    - Полный лог: ${log_file}"
}

print_reconfigure_failure_excerpt() {
  local log_file="$1" lines="${2:-60}"

  [ -f "$log_file" ] || return

  log "[chef] Последние ключевые события (по фильтру Chef):"

  local excerpt_rc filter_rc
  set +e
  chef_filter_log_file "$log_file" 2>/dev/null | tail -n "$lines" | sed 's/^/        /'
  excerpt_rc=$?
  filter_rc=${PIPESTATUS[0]:-0}
  set -e

  if [ "${filter_rc:-0}" -ne 0 ] || [ "${excerpt_rc:-0}" -ne 0 ]; then
    log "        (не удалось применить фильтр — показываю необработанные строки)"
    tail -n "$lines" "$log_file" | sed 's/^/        /'
  fi
}

should_ignore_reconfigure_failure() {
  local log_file="$1" reason_var="$2"

  [ -f "$log_file" ] || return 1

  local version="" optional_reason="" other_service="" rc=0

  version="$(gitlab_detect_version_for_health_checks)"
  if ! gitlab_service_optional "grafana" "$version" optional_reason; then
    return 1
  fi

  if [ -z "$optional_reason" ]; then
    return 1
  fi

  if ! grep -q "runit_service\\[grafana\\]" "$log_file" 2>/dev/null; then
    return 1
  fi

  if ! grep -q "Error executing action \`restart\` on resource 'runit_service\\[grafana\\]'" "$log_file" 2>/dev/null; then
    return 1
  fi

  other_service=$(awk '
    match($0, /runit_service\[([A-Za-z0-9_-]+)\]/, m) {
      if (m[1] != "grafana") {
        print m[1]
        exit
      }
    }
  ' "$log_file" 2>/dev/null || true)
  if [ -n "$other_service" ]; then
    return 1
  fi

  set +e
  chef_filter_log_file "$log_file" 2>/dev/null \
    | grep -F '[chef][ERR]' \
    | grep -Fv 'runit_service[grafana]' \
    >/dev/null
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    return 1
  fi

  if [ -n "$reason_var" ]; then
    printf -v "$reason_var" '%s' "$optional_reason"
  fi

  return 0
}

run_reconfigure() {
  local cmd="${1:-gitlab-ctl reconfigure}"
  local rlog_container="/var/log/gitlab/reconfigure.log"
  local rlog_host="${DATA_ROOT}/logs/reconfigure.log"
  rm -f "$rlog_host" 2>/dev/null || true
  log "[>] Выполняю ${cmd} (подробный лог: ${rlog_host})"
  log "[chef] Вывожу ключевые события Chef в реальном времени (подробности см. в логе)"

  local start_ts
  start_ts=$(date +%s)

  local dexec_rc filter_rc
  dexec_rc=0
  filter_rc=0

  set +e
  dexec "set -o pipefail; $cmd |& tee '$rlog_container'" \
    | chef_filter_stream
  dexec_rc=${PIPESTATUS[0]:-0}
  filter_rc=${PIPESTATUS[1]:-0}
  set -e

  local end_ts duration
  end_ts=$(date +%s)
  duration=$((end_ts - start_ts))

  if [ "${filter_rc:-0}" -ne 0 ]; then
    warn "[chef] Фильтр вывода Chef завершился с кодом ${filter_rc} — смотри полный лог: ${rlog_host}"
  fi

  log "[chef] Продолжительность gitlab-ctl reconfigure: $(format_duration "${duration}")"

  if [ "${dexec_rc:-0}" -eq 0 ]; then
    summarize_reconfigure_log "$rlog_host" "успех"
    report_basic_health "после gitlab-ctl reconfigure" "skip-db"
    return 0
  fi

  summarize_reconfigure_log "$rlog_host" "ошибка"
  print_reconfigure_failure_excerpt "$rlog_host"
  report_basic_health "после ошибки gitlab-ctl reconfigure" "skip-db"

  local ignore_reason=""
  if should_ignore_reconfigure_failure "$rlog_host" ignore_reason; then
    warn "[chef] Обнаружена сбойная перезагрузка опционального сервиса: ${ignore_reason}. Продолжаю несмотря на код возврата"
    return 0
  fi

  err "gitlab-ctl reconfigure завершился с ошибкой. Лог: $rlog_host"
  return 1
}

find_latest_backup_in_src() {
  local backup_files=()
  for pattern in "*_gitlab_backup.tar" "*_gitlab_backup.tar.gz"; do
    while IFS= read -r -d '' file; do
      backup_files+=("$file")
    done < <(find "$BACKUPS_SRC" -name "$pattern" -type f -print0 2>/dev/null | sort -z -r)
  done
  if [ ${#backup_files[@]} -gt 0 ]; then
    printf "%s" "${backup_files[0]}"
  else
    return 1
  fi
}

import_backup_and_config() {
  [ "$(get_state IMPORT_DONE || true)" = "1" ] && { ok "IMPORT_DONE уже выполнен — пропускаю импорт"; return; }
  [ -d "$BACKUPS_SRC" ] || { err "Не найден каталог $BACKUPS_SRC"; exit 1; }
  local cfg="$BACKUPS_SRC/gitlab_config.tar"
  [ -f "$cfg" ] || { err "Не найден $cfg"; exit 1; }
  local bk; bk="$(find_latest_backup_in_src)"; [ -n "$bk" ] || { err "В $BACKUPS_SRC нет *_gitlab_backup.tar*"; exit 1; }

  # Парсим TIMESTAMP и BASE_VER
  local fname ts y m d base rest
  fname="${bk##*/}"
  IFS=_ read -r ts y m d base rest <<< "$fname"
  [ -n "$ts" ] && [ -n "$base" ] || { err "Не удалось распарсить TIMESTAMP/BASE_VER из $fname"; exit 1; }

  set_state BACKUP_FILE "$bk"
  set_state BACKUP_TS   "$ts"
  set_state BASE_VER    "$base"

  mkdir -p "$DATA_ROOT/data/backups"
  cp -a "$bk" "$DATA_ROOT/data/backups/"
  log "[>] Распаковываю gitlab_config.tar → $DATA_ROOT"
  tar -C "$DATA_ROOT" -xf "$cfg"
  # Поддержка архивов без вложенной папки config
  if [ -f "$DATA_ROOT/gitlab.rb" ] || [ -f "$DATA_ROOT/gitlab-secrets.json" ]; then
    mkdir -p "$DATA_ROOT/config"
    [ -f "$DATA_ROOT/gitlab.rb" ] && mv -f "$DATA_ROOT/gitlab.rb" "$DATA_ROOT/config/"
    [ -f "$DATA_ROOT/gitlab-secrets.json" ] && mv -f "$DATA_ROOT/gitlab-secrets.json" "$DATA_ROOT/config/"
  fi
  if [ ! -f "$DATA_ROOT/config/gitlab.rb" ] || [ ! -f "$DATA_ROOT/config/gitlab-secrets.json" ]; then
    err "В gitlab_config.tar нет gitlab.rb или gitlab-secrets.json"
    exit 1
  fi
  permissions_mark_pending
  ok "Импортированы backup и конфиг"
  set_state IMPORT_DONE 1
}

ensure_backup_present() {
  local ts="$(get_state BACKUP_TS || true)" bk_srv
  bk_srv=$(ls -1 "$DATA_ROOT/data/backups/${ts}_"*_gitlab_backup.tar* 2>/dev/null | head -n1 || true)
  if [ -z "$bk_srv" ]; then
    warn "В /srv нет файла бэкапа TS=${ts}. Пробую скопировать из $BACKUPS_SRC…"
    local bk_src
    bk_src="$(find_latest_backup_in_src)"
    [ -n "$bk_src" ] || { err "В $BACKUPS_SRC нет *_gitlab_backup.tar*"; exit 1; }

    if [ -z "$ts" ]; then
      local fname2 ts2 y m d base
      fname2="${bk_src##*/}"
      IFS=_ read -r ts2 y m d base _ <<< "$fname2"
      set_state BACKUP_TS "$ts2"
      [ -z "$(get_state BASE_VER || true)" ] && set_state BASE_VER "$base"
      ts="$ts2"
    fi

    mkdir -p "$DATA_ROOT/data/backups"
    cp -a "$bk_src" "$DATA_ROOT/data/backups/"
    ok "Скопировал $(basename "$bk_src") в $DATA_ROOT/data/backups/"
  fi
}

# Создаём ТОЛЬКО корректное «каноническое» имя под реальное расширение
normalize_backup_name() {
  local ts dir_host real ext
  ts="$(get_state BACKUP_TS)"; dir_host="$DATA_ROOT/data/backups"
  real=$(ls -1 "$dir_host/${ts}_"*_gitlab_backup.tar* 2>/dev/null | head -n1 || true)
  [ -z "$real" ] && { err "Не найден файл $dir_host/${ts}_*_gitlab_backup.tar*"; exit 1; }
  if [[ "$real" == *.tar.gz ]]; then ext=".tar.gz"; else ext=".tar"; fi
  local canon="$dir_host/${ts}_gitlab_backup${ext}"
  if [ "$real" != "$canon" ]; then
    ln -f "$real" "$canon" 2>/dev/null || cp -a "$real" "$canon"
  fi
  set_state BACKUP_CANON "$canon"
  ok "Нормализовано имя бэкапа: $(basename "$canon")"
}

fix_owners() {
  local UIDG_GIT U_GIT G_GIT UIDG_PSQL U_PSQL G_PSQL

  UIDG_GIT=$(dexec 'printf "%s:%s" "$(id -u git)" "$(id -g git)"' 2>/dev/null || echo "998:998")
  UIDG_GIT=$(printf "%s" "$UIDG_GIT" | tr -d '\n')
  U_GIT=${UIDG_GIT%%:*}
  G_GIT=${UIDG_GIT##*:}

  UIDG_PSQL=$(dexec 'printf "%s:%s" "$(id -u gitlab-psql)" "$(id -g gitlab-psql)"' 2>/dev/null || echo "996:996")
  UIDG_PSQL=$(printf "%s" "$UIDG_PSQL" | tr -d '\n')
  U_PSQL=${UIDG_PSQL%%:*}
  G_PSQL=${UIDG_PSQL##*:}

  chown -R root:root "$DATA_ROOT/config"
  chown -R "$U_GIT:$G_GIT" "$DATA_ROOT/data" "$DATA_ROOT/logs"
  chown -R "$U_PSQL:$G_PSQL" "$DATA_ROOT/data/postgresql" 2>/dev/null || true
  chmod 700 "$DATA_ROOT/data/backups" 2>/dev/null || true
  chmod 600 "$DATA_ROOT/data/backups"/*gitlab_backup.tar* 2>/dev/null || true
  ok "Права на каталоги выровнены (git uid:gid = $U_GIT:$G_GIT, gitlab-psql uid:gid = $U_PSQL:$G_PSQL)"
}

check_backup_versions() {
  local canon bk_ver bk_db cur_ver cur_db tmp container_backup
  canon="$(get_state BACKUP_CANON || true)"
  [ -f "$canon" ] || { warn "Не найден backup файл для проверки версий"; return; }
  container_backup="/var/opt/gitlab/backups/$(basename "$canon")"

  log "[>] Проверка метаданных бэкапа…"
  tmp="$(mktemp)"
  if tar -xf "$canon" backup_information.yml -O >"$tmp" 2>/dev/null; then
    bk_ver=$(grep '^:gitlab_version:' "$tmp" | awk '{print $2}' | tr -d "'\"[:space:]" || true)
    bk_db=$(grep '^:db_version:' "$tmp" | awk '{print $2}' | tr -d "'\"[:space:]" || true)
    log "  - GitLab в бэкапе: ${bk_ver:-unknown}"
    log "  - Версия схемы БД в бэкапе: ${bk_db:-unknown}"
    if [ -z "$bk_ver" ] || [ -z "$bk_db" ]; then
      warn "Отсутствуют метаданные в backup_information.yml"
      log "  - Путь к архиву (host): $canon"
      log "  - Путь к архиву (container): $container_backup"
      log "  - Содержимое backup_information.yml (host):"
      sed 's/^/    | /' "$tmp" || true
      log "  - Содержимое backup_information.yml (container):"
      dexec "tar -xf '$container_backup' backup_information.yml -O" 2>/dev/null | sed 's/^/    | /' || warn "Не удалось извлечь backup_information.yml из контейнера"
    fi
  else
    warn "Не удалось извлечь backup_information.yml из $(basename "$canon")"
    log "  - Путь к архиву (host): $canon"
    log "  - Содержимое архива (первые 50 строк):"
    tar -tvf "$canon" 2>&1 | head -n50 | sed 's/^/    | /'
  fi
  rm -f "$tmp" 2>/dev/null || true

  cur_ver=$(dexec 'cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo unknown')
  cur_db=$(dexec "gitlab-psql -d gitlabhq_production -t -c 'SELECT MAX(version) FROM schema_migrations;' 2>/dev/null" | tr -d '[:space:]')
  log "  - GitLab в контейнере: ${cur_ver:-unknown}"
  log "  - Версия схемы БД в контейнере: ${cur_db:-unknown}"

  if [ -n "$bk_ver" ] && [ "$bk_ver" != "$cur_ver" ]; then
    warn "Версия GitLab бэкапа (${bk_ver}) отличается от версии контейнера (${cur_ver})"
  fi
  if [ -n "$bk_db" ] && [ "$bk_db" != "$cur_db" ]; then
    warn "Версия схемы БД бэкапа (${bk_db}) отличается от версии контейнера (${cur_db})"
  fi

  log "[>] Статус служб в контейнере:"
  dexec 'gitlab-ctl status' || true
}

restore_backup_if_needed() {
  local done ts canon ext container_backup_file
  ts="$(get_state BACKUP_TS)"
  done="$(get_state RESTORED_TS || true)"
  [ "$done" = "$ts" ] && { ok "Бэкап уже восстановлен (TS=$done) — пропускаю"; return; }

  ensure_backup_present
  normalize_backup_name
  canon="$(get_state BACKUP_CANON)"
  [[ "$canon" == *.tar.gz ]] && ext=".tar.gz" || ext=".tar"
  container_backup_file="/var/opt/gitlab/backups/${ts}_gitlab_backup${ext}"

  log "[>] Проверка валидности backup файла…"
  log "[>] Путь к backup файлу (host): ${canon}"
  log "[>] Путь к backup файлу (container): ${container_backup_file}"
  log "[>] Размер backup файла: $(stat -c%s "${canon}" 2>/dev/null || echo "n/a")"
  log "[>] Права на backup файл: $(stat -c%A "${canon}" 2>/dev/null || echo "n/a")"
  log "[>] Владелец файла: $(stat -c%U "${canon}" 2>/dev/null || echo "n/a")"
  log "[>] Группа файла: $(stat -c%G "${canon}" 2>/dev/null || echo "n/a")"

  log "[>] Проверка доступности backup файла в контейнере…"
  dexec "ls -la '${container_backup_file}'" >/dev/null || { err "Backup файл недоступен в контейнере: ${container_backup_file}"; exit 1; }

  log "[>] Проверка свободного места в контейнере…"
  dexec "df -h /var/opt/gitlab" || true

  if [[ "${container_backup_file}" == *.tar.gz ]]; then
    log "[>] Проверка gzip архива…"
    dexec "gunzip -t '${container_backup_file}'" || { err "Backup файл повреждён (gzip test failed)"; exit 1; }
    log "[>] Проверка tar архива…"
    dexec "tar -ztvf '${container_backup_file}' >/dev/null" || { err "Backup файл повреждён (tar zt failed)"; exit 1; }
  else
    log "[>] Проверка tar архива…"
    dexec "tar -tvf '${container_backup_file}'  >/dev/null" || { err "Backup файл повреждён (tar t failed)"; exit 1; }
  fi

  log "[>] Проверка готовности всех служб перед восстановлением…"
  if ! wait_gitlab_ready; then
    err "GitLab не готов к восстановлению из бэкапа"
    exit 1
  fi
  wait_postgres_ready
  wait_container_health
  check_backup_versions

  fix_owners
  dexec 'touch /var/opt/gitlab/skip-auto-migrations' >/dev/null 2>&1 || true
  dexec 'update-permissions' >/dev/null 2>&1 || warn "update-permissions после fix_owners завершился с ошибкой"
  log "[>] Применение новых прав (gitlab-ctl reconfigure)…"
  run_reconfigure || exit 1
  if ! wait_gitlab_ready; then
    err "GitLab не поднялся после reconfigure перед восстановлением"
    exit 1
  fi
  wait_postgres_ready

  log "[>] Проверка свободного места перед восстановлением…"
  dexec "df -h /var/opt/gitlab" || true
  local available_space
  available_space=$(dexec "df -BG --output=avail /var/opt/gitlab | tail -1 | tr -dc '0-9'" || echo "0")
  if [ "${available_space:-0}" -lt 5 ]; then
    err "Недостаточно свободного места: ${available_space}G доступно, требуется минимум 5G"; exit 1
  fi

  local rlog="/var/log/gitlab/restore_${ts}.log"
  local restore_attempt=1 max_attempts=3

  set_state RESTORE_CONFIRMED 0

  while [ $restore_attempt -le $max_attempts ]; do
    log "[>] Восстановление BACKUP=$ts (подробный лог: ${rlog})…"
    log "[>] Попытка восстановления $restore_attempt/$max_attempts…"
    log "[i] Для мониторинга прогресса в реальном времени: tail -f ${rlog}"

    local rc_before rc_after cmd_rc
    rc_before=$(container_restart_count)

    # Выполняем восстановление и сохраняем код возврата
    trap - ERR
    set +e
    dexec "set -o pipefail; umask 077; ( time gitlab-backup restore BACKUP=$ts force=yes ) 2>&1 | tee '${rlog}' | grep -E '(Warning:|ERROR|FATAL|Starting Chef Client|Recipe:|Running handlers|Chef Client finished|gitlab Reconfigured|Restore task is done|real|user|sys)' | grep -vE 'ERROR: +(relation|sequence|table|index) .* does not exist|ERROR: +must be owner of extension' || true; exit \\${PIPESTATUS[0]}"
    cmd_rc=$?
    set -e
    trap error_trap ERR
    if [ $cmd_rc -eq 0 ]; then
      ok "Восстановление успешно завершено на попытке $restore_attempt"
      log "[i] Код возврата gitlab-backup restore: $cmd_rc"
      break
    else
      warn "Попытка $restore_attempt/$max_attempts завершилась ошибкой (код ${cmd_rc})"
      rc_after=$(container_restart_count)
      log "Подробности см. в ${rlog} и через docker logs --tail 200 $CONTAINER_NAME"

      if [ "$cmd_rc" -eq 137 ]; then
        warn "Команда gitlab-backup restore была прервана (код 137) — проверяю память"
        log "------ Свободная память хоста ------"
        free -h 2>&1 | sed -e 's/^/[host] /' >&2 || true
        if container_running; then
          log "------ Свободная память контейнера ------"
          dexec 'free -h' 2>&1 | sed -e 's/^/[ctr] /' >&2 || true
        fi
        log "------ dmesg (последние строки) ------"
        local last_dmesg
        last_dmesg=$(dmesg | tail -n 20)
        printf '%s\n' "$last_dmesg" | sed -e 's/^/[dmesg] /' >&2 || true
        if printf '%s' "$last_dmesg" | grep -qi 'Killed process'; then
          err "Обнаружены признаки OOM: процесс был убит ядром. Увеличьте доступную RAM/Swap и запустите заново"
          exit 1
        fi
      fi

      if ! container_running || [ "${rc_after:-0}" -gt "${rc_before:-0}" ]; then
        warn "Обнаружен возможный рестарт/ступор контейнера (RestartCount ${rc_before}→${rc_after}). Запускаю update-permissions и перезапуск…"
        docker exec -i "$CONTAINER_NAME" update-permissions >/dev/null 2>&1 || true
        docker restart "$CONTAINER_NAME" >/dev/null || true
        sleep "$WAIT_AFTER_START"
        run_reconfigure || true
        sleep "$WAIT_AFTER_START"
      fi

      if ! wait_gitlab_ready; then
        err "GitLab не восстановился после неудачной попытки восстановления"
        exit 1
      fi
      wait_postgres_ready

      if [ $restore_attempt -eq $max_attempts ]; then
        err "Восстановление завершилось с ошибкой после $max_attempts попыток. Проверьте лог: ${rlog}"
        exit 1
      else
        warn "Повторю попытку через 30 секунд…"; sleep 30
        restore_attempt=$((restore_attempt+1))
      fi
    fi
  done

  dexec 'rm -f /var/opt/gitlab/skip-auto-migrations' >/dev/null 2>&1 || true
  run_reconfigure 'env -u GITLAB_SKIP_DATABASE_MIGRATION gitlab-ctl reconfigure' || true
  dexec 'env -u GITLAB_SKIP_DATABASE_MIGRATION gitlab-ctl restart >/dev/null 2>&1'     || true

  set_state RESTORED_TS "$ts"
  ok "Восстановление завершено"
}

verify_restore_success() {
  log "[>] Запускаю все службы после восстановления…"
  
  # Ensure container is running
  if ! container_running; then
    log "[>] Контейнер не запущен — запускаю…"
    docker start "$CONTAINER_NAME" >/dev/null || true
    sleep 30
  fi
  
  # Start services inside container
  dexec 'gitlab-ctl start >/dev/null 2>&1' || true
  sleep 30

  # Wait for GitLab and PostgreSQL to be ready
  if ! wait_gitlab_ready; then
    err "GitLab не поднялся после запуска служб"
    exit 1
  fi
  wait_postgres_ready

  # Explicitly check critical services
  local services=("gitaly" "postgresql" "redis" "sshd")
  local service_ok=1
  for service in "${services[@]}"; do
    if dexec "gitlab-ctl status ${service} | grep -q 'run:'"; then
      ok "Служба $service запущена"
    else
      warn "Служба $service не запущена"
      service_ok=0
    fi
  done

  # Если критические службы не запущены, пытаемся автоматический recovery
  if [ $service_ok -eq 0 ]; then
    warn "Критические службы не запустились — выполняю reconfigure и restart"
    run_reconfigure 'env -u GITLAB_SKIP_DATABASE_MIGRATION gitlab-ctl reconfigure' || true
    dexec 'gitlab-ctl restart >/dev/null 2>&1'     || true
    sleep 30

    service_ok=1
    for service in "${services[@]}"; do
      if dexec "gitlab-ctl status ${service} | grep -q 'run:'"; then
        ok "Служба $service запущена"
      else
        warn "Служба $service не запустилась после reconfigure"
        service_ok=0
      fi
    done

    if [ $service_ok -eq 0 ]; then
      err "Критические службы не запустились даже после reconfigure"
      exit 1
    fi
  fi

  log "[>] Проверка миграций после восстановления…"
  local rake_available=0 need_status_check=1 pending_warned=0
  local abort_output="" abort_rc=0 status_output="" status_rc=0 pending_count=0 preview_count=0

  if gitlab_rake_available; then
    rake_available=1
  else
    need_status_check=0
    warn "Не удалось проверить миграции: ${GITLAB_RAKE_ERROR:-Команда gitlab-rake недоступна}"
  fi

  if [ "$rake_available" -eq 1 ]; then
    if background_rake_task_exists 'gitlab:db:abort_if_pending_migrations'; then
      if abort_output=$(gitlab_rake gitlab:db:abort_if_pending_migrations 2>&1); then
        ok "Все миграции применены"
        need_status_check=0
      else
        abort_rc=$?
        pending_warned=1
        warn "Найдены незавершённые миграции (gitlab:db:abort_if_pending_migrations завершился с кодом ${abort_rc})"
        if [ -n "${abort_output//[[:space:]]/}" ]; then
          log "    - Вывод gitlab:db:abort_if_pending_migrations:"
          printf '%s\n' "$abort_output" | indent_with_prefix "        "
        fi
      fi
    else
      if [ "${BACKGROUND_RAKE_TASKS_RC:-0}" -ne 0 ] && [ -n "${BACKGROUND_RAKE_TASKS_ERROR:-}" ]; then
        warn "Не удалось получить список rake-задач (gitlab-rake -AT/-T завершился с кодом ${BACKGROUND_RAKE_TASKS_RC})"
        printf '%s\n' "${BACKGROUND_RAKE_TASKS_ERROR}" | indent_with_prefix "    "
      else
        log "    - Задача gitlab:db:abort_if_pending_migrations недоступна в этой версии GitLab"
      fi
    fi
  fi

  if [ "$need_status_check" -eq 1 ] && [ "$rake_available" -eq 1 ]; then
    if status_output=$(gitlab_rake db:migrate:status 2>&1); then
      status_rc=0
    else
      status_rc=$?
    fi

    if [ "$status_rc" -eq 0 ]; then
      pending_count=$(printf '%s\n' "$status_output" | awk '/^[[:space:]]*down/ {count++} END {print count+0}')
      if [ "$pending_count" -gt 0 ]; then
        if [ "$pending_warned" -eq 0 ]; then
          warn "Найдены незапущенные миграции: ${pending_count}"
          pending_warned=1
        else
          log "    - Незавершённых миграций: ${pending_count}"
        fi
        preview_count=$pending_count
        if [ "$preview_count" -gt 10 ]; then
          preview_count=10
        fi
        if [ "$preview_count" -gt 0 ]; then
          log "    - Незавершённые миграции (первые ${preview_count}):"
          printf '%s\n' "$status_output" |
            awk '
              BEGIN { db="" }
              /^database:/ {
                db=$0
                sub(/^[[:space:]]+/, "", db)
                next
              }
              /^[[:space:]]*down/ {
                line=$0
                sub(/^[[:space:]]+/, "", line)
                if (db != "") {
                  printf "%s -> %s\n", db, line
                } else {
                  printf "%s\n", line
                }
              }
            ' |
            head -n "$preview_count" |
            indent_with_prefix "        "
          if [ "$pending_count" -gt "$preview_count" ]; then
            log "        … и ещё $((pending_count - preview_count)) миграций (см. полный вывод db:migrate:status)"
          fi
        fi
      else
        if [ "$pending_warned" -eq 1 ]; then
          log "    - db:migrate:status не показал миграций со статусом down"
        else
          ok "Все миграции применены"
        fi
      fi
    else
      warn "Не удалось получить статус миграций (db:migrate:status завершился с кодом ${status_rc})"
      if [ -n "${status_output//[[:space:]]/}" ]; then
        log "    - Вывод db:migrate:status:"
        printf '%s\n' "$status_output" | indent_with_prefix "        "
      fi
    fi
  fi

  log "[>] Проверка состояния базы данных…"
  local project_count user_count issue_count
  project_count=$(dexec 'gitlab-psql -d gitlabhq_production -t -c "SELECT COUNT(*) FROM projects;" 2>/dev/null | tr -d "[:space:]" || echo "0"')
  user_count=$(dexec 'gitlab-psql -d gitlabhq_production -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d "[:space:]" || echo "0"')
  issue_count=$(dexec 'gitlab-psql -d gitlabhq_production -t -c "SELECT COUNT(*) FROM issues;" 2>/dev/null | tr -d "[:space:]" || echo "0"')
  
  if [ "${project_count:-0}" -gt 0 ]; then
    ok "База данных содержит ${project_count} проектов"
  else
    warn "База данных пуста или недоступна"
  fi

  log "  - Пользователи: $user_count"
  log "  - Ишью: $issue_count"

  log "[>] Проверка фоновых миграций…"
  background_migrations_status_report "  " || true

  log "[>] Размер восстановленных данных:"
  dexec 'du -sh /var/opt/gitlab/git-data/repositories | awk '\''{print "  - Репозитории: "$1}'\'' || true'
  dexec 'du -sh /var/opt/gitlab/postgresql/data | awk '\''{print "  - База данных: "$1}'\'' || true'

  log "[>] Контрольная проверка GitLab после восстановления"
  if ensure_gitlab_health "после восстановления"; then
    ok "Автоматическая проверка после восстановления пройдена"
  else
    warn "Автоматическая проверка после восстановления обнаружила проблемы: ${LAST_HEALTH_ISSUES:-unknown}"
    print_host_log_hint
  fi

  set_state RESTORE_DONE 1
  if [ "${LAST_HEALTH_OK:-0}" = "1" ]; then
    ok "Восстановление проверено"
  else
    warn "Восстановление завершено, но требуется ручная проверка"
  fi
}

BASE_SNAPSHOT_DIR="${DATA_ROOT}-snapshot"

current_gitlab_version() {
  dexec 'cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo "unknown"' 2>/dev/null
}

current_image_tag() {
  docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true
}

create_snapshot() {
  local current_version="${1-}" image_tag snapshot_ts
  current_version="${current_version:-$(current_gitlab_version)}"
  current_version="${current_version:-unknown}"
  image_tag="$(current_image_tag)"; image_tag="${image_tag:-unknown}"
  snapshot_ts="$(date +%Y%m%d-%H%M%S)"

  log "[>] Останавливаю контейнер перед созданием локального бэкапа…"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  sleep 5

  log "[>] Копирую каталоги ${DATA_ROOT} → ${BASE_SNAPSHOT_DIR}"
  rm -rf "$BASE_SNAPSHOT_DIR" 2>/dev/null || true
  mkdir -p "$BASE_SNAPSHOT_DIR"
  cp -a "$DATA_ROOT"/{config,data,logs} "$BASE_SNAPSHOT_DIR/"

  set_state SNAPSHOT_DONE 1
  set_state SNAPSHOT_VERSION "$current_version"
  set_state SNAPSHOT_IMAGE "$image_tag"
  set_state SNAPSHOT_TS "$snapshot_ts"
  cp -a "$STATE_FILE" "$BASE_SNAPSHOT_DIR/state.env" 2>/dev/null || true

  log "  - Метка снапшота: ${snapshot_ts}"
  log "  - Версия GitLab: ${current_version}"
  log "  - Образ контейнера: ${image_tag}"
  log "  - Размер репозиториев: $(du -sh "$BASE_SNAPSHOT_DIR/data/git-data/repositories" 2>/dev/null | cut -f1)"
  log "  - Размер базы данных: $(du -sh "$BASE_SNAPSHOT_DIR/data/postgresql/data" 2>/dev/null | cut -f1)"
  ok "Локальный бэкап обновлён (GitLab ${current_version})"

  log "[>] Запускаю контейнер после создания бэкапа…"
  docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
  sleep "$WAIT_AFTER_START"
  ensure_permissions
}

ensure_initial_snapshot() {
  if [ "$(get_state SNAPSHOT_DONE || true)" = "1" ]; then
    ok "Локальный бэкап уже создан и актуален — пропускаю"
    return 1
  fi

  create_snapshot
  ok "Снимок данных создан. Запустите скрипт снова для продолжения миграции"
  return 0
}

restore_from_local_snapshot() {
  local snap="$BASE_SNAPSHOT_DIR" snap_state="$BASE_SNAPSHOT_DIR/state.env" snap_ver
  snap_ver="$(get_state_from_file "$snap_state" SNAPSHOT_VERSION || true)"
  if [ -d "$snap/config" ] && [ -d "$snap/data" ]; then
    if [ "$(get_state SNAPSHOT_DONE || true)" = "1" ]; then
      ok "Локальный бэкап уже создан и актуален — пропускаю восстановление"
      return
    fi
    local prompt="Найден локальный бэкап ${snap}"
    if [ -n "$snap_ver" ]; then
      prompt+=" (версия GitLab ${snap_ver})"
    fi
    prompt+=". Восстановить его?"
    if ask_yes_no "$prompt" "y"; then
      stop_container
      log "[>] Восстанавливаю каталоги из ${snap}"
      rm -rf "$DATA_ROOT"/config "$DATA_ROOT"/data "$DATA_ROOT"/logs
      mkdir -p "$DATA_ROOT"
      cp -a "$snap"/{config,data,logs} "$DATA_ROOT/"
      cp -a "$snap/state.env" "$STATE_FILE" 2>/dev/null || true
      set_state BASE_STARTED 0
      permissions_mark_pending
      set_state RESTORE_DONE 0
      set_state RESTORE_CONFIRMED 0

      local snap_ts snap_image prev_base_ver prev_base_tag new_base_tag
      snap_ts="$(get_state_from_file "$snap_state" SNAPSHOT_TS || true)"
      snap_image="$(get_state_from_file "$snap_state" SNAPSHOT_IMAGE || true)"

      local snap_ver_clean snap_image_clean snap_ts_clean
      snap_ver_clean="${snap_ver//$'\r'/}"; snap_ver_clean="${snap_ver_clean//$'\n'/}"
      snap_image_clean="${snap_image//$'\r'/}"; snap_image_clean="${snap_image_clean//$'\n'/}"
      snap_ts_clean="${snap_ts//$'\r'/}"; snap_ts_clean="${snap_ts_clean//$'\n'/}"

      if [ -n "$snap_ver_clean" ] && [ "$snap_ver_clean" != "unknown" ]; then
        prev_base_ver="$(get_state BASE_VER || true)"
        if [ "$snap_ver_clean" != "${prev_base_ver:-}" ]; then
          if [ -n "${prev_base_ver:-}" ]; then
            log "[i] Обновляю BASE_VER из снапшота: ${prev_base_ver} → ${snap_ver_clean}"
          else
            log "[i] Сохраняю BASE_VER из снапшота: ${snap_ver_clean}"
          fi
        fi
        set_state BASE_VER "$snap_ver_clean"
      fi

      if [ -n "$snap_image_clean" ] && [ "$snap_image_clean" != "unknown" ]; then
        new_base_tag=""
        if [[ "$snap_image_clean" == *@* ]]; then
          warn "SNAPSHOT_IMAGE='${snap_image_clean}' содержит digest — оставляю BASE_IMAGE_TAG без изменений"
        elif [[ "$snap_image_clean" == *":"* ]]; then
          new_base_tag="${snap_image_clean##*:}"
        else
          warn "Не удалось извлечь тег из SNAPSHOT_IMAGE='${snap_image_clean}' — оставляю BASE_IMAGE_TAG без изменений"
        fi
        new_base_tag="${new_base_tag//[[:space:]]/}"
        if [ -n "$new_base_tag" ]; then
          prev_base_tag="$(get_state BASE_IMAGE_TAG || true)"
          if [ "$new_base_tag" != "${prev_base_tag:-}" ]; then
            if [ -n "${prev_base_tag:-}" ]; then
              log "[i] Обновляю BASE_IMAGE_TAG из снапшота: ${prev_base_tag} → ${new_base_tag}"
            else
              log "[i] Сохраняю BASE_IMAGE_TAG из снапшота: ${new_base_tag}"
            fi
          fi
          set_state BASE_IMAGE_TAG "$new_base_tag"
        fi
      fi

      if [ -n "$snap_ts_clean" ]; then
        log "  - Метка снапшота: ${snap_ts_clean}"
      fi
      if [ -n "$snap_ver_clean" ]; then
        log "  - Версия GitLab: ${snap_ver_clean}"
      fi
      if [ -n "$snap_image_clean" ]; then
        log "  - Образ контейнера: ${snap_image_clean}"
      fi
      log "  - Размер репозиториев: $(du -sh "$DATA_ROOT/data/git-data/repositories" 2>/dev/null | cut -f1)"
      log "  - Размер базы данных: $(du -sh "$DATA_ROOT/data/postgresql/data" 2>/dev/null | cut -f1)"
      ok "Каталоги восстановлены из локального бэкапа"
    fi
  fi
}
