# lib/backup.sh
# shellcheck shell=bash
# Source docker lib for container_running function
. "$BASEDIR/lib/docker.sh"

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
  tar -C "$DATA_ROOT" -xf "$cfg"   # создаст $DATA_ROOT/config
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
    bk_ver=$(grep '^:gitlab_version:' "$tmp" | awk '{print $2}' || true)
    bk_db=$(grep '^:db_version:' "$tmp" | awk '{print $2}' || true)
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

  log "[>] Сводка окружения контейнера:"
  dexec 'gitlab-rake gitlab:env:info' || true
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
  wait_gitlab_ready
  wait_postgres_ready
  wait_container_health
  check_backup_versions

  fix_owners
  dexec 'touch /var/opt/gitlab/skip-auto-migrations' >/dev/null 2>&1 || true
  dexec 'update-permissions' >/dev/null 2>&1 || warn "update-permissions после fix_owners завершился с ошибкой"
  log "[>] Применение новых прав (gitlab-ctl reconfigure)…"
  dexec 'gitlab-ctl reconfigure >/dev/null 2>&1' || true
  wait_gitlab_ready
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

  while [ $restore_attempt -le $max_attempts ]; do
    log "[>] Восстановление BACKUP=$ts (подробный лог: ${rlog})…"
    log "[>] Попытка восстановления $restore_attempt/$max_attempts…"
    log "[i] Для мониторинга прогресса в реальном времени: tail -f ${rlog}"

    local rc_before rc_after cmd_rc
    rc_before=$(container_restart_count)

    # Выполняем восстановление и сохраняем код возврата
    trap - ERR
    set +e
    dexec "set -o pipefail; umask 077; ( time gitlab-backup restore BACKUP=$ts force=yes ) 2>&1 | tee '${rlog}' | grep -E '^( \*[^ ]|Warning:|ERROR|FATAL|Starting Chef Client|Recipe:|Running handlers|Chef Client finished|gitlab Reconfigured|Restore task is done|real|user|sys)' || true; exit \${PIPESTATUS[0]}"
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

      # Enhanced error diagnostics
      log "------ Ошибки из ${rlog} (полный контекст) ------"
      if ! dexec "grep -nE 'ERROR|FATAL|rake aborted|tar:|Permission denied|No space left|No such file|Database.*version|PG::|invalid' '${rlog}' -B 5 -A 5 | tail -n 100"; then
        log "(подходящих строк не найдено)"
      fi

      # Show critical last 50 lines regardless of error patterns
      log "------ Последние 50 строк лога ------"
      dexec "tail -n 50 '${rlog}'" || true
      log "------ Полный лог ${rlog} ------"
      dexec "cat '${rlog}'" || true
      log "------ Проверка прав Postgres ------"
      dexec "ls -ld /var/opt/gitlab/postgresql /var/opt/gitlab/postgresql/data /var/opt/gitlab/postgresql/data/global" 2>&1 || true
      if dexec "test -e /var/opt/gitlab/postgresql/data/global/pg_filenode.map" >/dev/null 2>&1; then
        dexec "ls -l /var/opt/gitlab/postgresql/data/global/pg_filenode.map" || true
      fi


      # Дополнительные данные о состоянии контейнера
      log "------ Статус контейнера ------"
      docker ps -a --filter "name=$CONTAINER_NAME" || true
      log "------ Ошибки из docker logs ------"
      local dlog
      dlog=$(docker logs --tail 200 "$CONTAINER_NAME" 2>&1 || true)
      if printf '%s\n' "$dlog" | grep -iE 'ERROR|FATAL|rake aborted|database version is too old|Chef Client failed' >/dev/null; then
        printf '%s\n' "$dlog" | grep -iE 'ERROR|FATAL|rake aborted|database version is too old|Chef Client failed' || true
      else
        printf '%s\n' "$dlog"
      fi

      log "------ Последние строки chef-client.log ------"
      if docker exec -i "$CONTAINER_NAME" test -f /var/log/gitlab/chef-client.log >/dev/null 2>&1; then
        docker exec -i "$CONTAINER_NAME" tail -n 20 /var/log/gitlab/chef-client.log 2>&1 || true
      else
        log "файл /var/log/gitlab/chef-client.log отсутствует"
      fi
      log "------ Последние строки reconfigure.log ------"
      if docker exec -i "$CONTAINER_NAME" test -f /var/log/gitlab/reconfigure.log >/dev/null 2>&1; then
        docker exec -i "$CONTAINER_NAME" tail -n 20 /var/log/gitlab/reconfigure.log 2>&1 || true
      else
        log "файл /var/log/gitlab/reconfigure.log отсутствует"
      fi

      if [ "$cmd_rc" -eq 137 ]; then
        warn "Команда gitlab-backup restore была прервана (код 137) — процесс был убит"
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
        else
          warn "Признаков нехватки памяти не найдено — проверьте логи выше и состояние контейнера"
        fi
      fi

      if ! container_running || [ "${rc_after:-0}" -gt "${rc_before:-0}" ]; then
        warn "Обнаружен возможный рестарт/ступор контейнера (RestartCount ${rc_before}→${rc_after}). Запускаю update-permissions и перезапуск…"
        docker exec -i "$CONTAINER_NAME" update-permissions >/dev/null 2>&1 || true
        docker restart "$CONTAINER_NAME" >/dev/null || true
        sleep "$WAIT_AFTER_START"
        docker exec -i "$CONTAINER_NAME" gitlab-ctl reconfigure >/dev/null 2>&1 || true
        sleep "$WAIT_AFTER_START"
      fi

      wait_gitlab_ready
      wait_postgres_ready

      if [ $restore_attempt -eq $max_attempts ]; then
        # More detailed final error message
        err "Восстановление завершилось с ошибкой после $max_attempts попыток. Проверьте полный лог: ${rlog}";
        exit 1
      else
        warn "Повторю попытку через 30 секунд…"; sleep 30
        restore_attempt=$((restore_attempt+1))
      fi
    fi
  done

  dexec 'rm -f /var/opt/gitlab/skip-auto-migrations' >/dev/null 2>&1 || true
  dexec 'env -u GITLAB_SKIP_DATABASE_MIGRATION gitlab-ctl reconfigure' || true
  dexec 'env -u GITLAB_SKIP_DATABASE_MIGRATION gitlab-ctl restart'     || true

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
  dexec 'gitlab-ctl start' || true
  sleep 30

  # Wait for GitLab and PostgreSQL to be ready
  wait_gitlab_ready
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
    dexec 'env -u GITLAB_SKIP_DATABASE_MIGRATION gitlab-ctl reconfigure' || true
    dexec 'gitlab-ctl restart'     || true
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
  local pending_migrations
  pending_migrations=$(dexec 'gitlab-rake db:migrate:status' 2>/dev/null | grep -E '^\s*down' || true)
  if [ -n "$pending_migrations" ]; then
    warn "Найдены незапущенные миграции:"
    printf '%s\n' "$pending_migrations"
  else
    ok "Все миграции применены"
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

  log "[>] Проверка веб‑интерфейса…"
  local http_status
  http_status=$(dexec 'curl -s -o /dev/null -w "%{http_code}" http://localhost/-/health 2>/dev/null || echo "000"')
  if [ "$http_status" = "200" ]; then
    ok "Веб‑интерфейс доступен (HTTP 200)"
  else
    warn "Веб‑интерфейс недоступен или возвращает код $http_status"
  fi

  log "[>] Проверка фоновых миграций…"
  dexec 'gitlab-rake gitlab:background_migrations:status' || true

  log "[>] Размер восстановленных данных:"
  dexec 'du -sh /var/opt/gitlab/git-data/repositories | awk '\''{print "  - Репозитории: "$1}'\'' || true'
  dexec 'du -sh /var/opt/gitlab/postgresql/data | awk '\''{print "  - База данных: "$1}'\'' || true'

  ok "Восстановление проверено"
  set_state RESTORE_DONE 1
}
