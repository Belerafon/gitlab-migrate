# lib/docker.sh
# shellcheck shell=bash
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || { err "Запусти как root"; exit 1; }; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || { err "Нужна команда '$1'"; exit 1; }; }
docker_ok() {
  local t=${DOCKER_INFO_TIMEOUT:-10}
  if command -v timeout >/dev/null 2>&1; then
    timeout "$t" docker info >/dev/null 2>&1
  else
    docker info >/dev/null 2>&1
  fi
}

# Use non-login shell to avoid TTY errors
dexec() {
  local cmd="$1" out rc
  # Выполняем команду и сохраняем stdout/stderr вместе с кодом возврата
  out=$(docker exec -i "$CONTAINER_NAME" bash -c "$cmd" 2>&1)
  rc=$?
  # Фильтруем надоедливое предупреждение mesg
  out=$(printf "%s" "$out" | grep -v "mesg: ttyname failed")
  printf "%s" "$out"

  # Если docker exec провалился, покажем диагностическую информацию
  if [ $rc -ne 0 ] && { [[ "$out" == *"OCI runtime exec failed"* ]] || ! container_running; }; then
    warn "[dexec] docker exec завершился с кодом $rc"
    log "------ Статус контейнера ------"
    docker ps -a --filter "name=$CONTAINER_NAME" 2>&1 || true
    log "------ Подсказка по логам ------"
    log "docker logs --tail 20 $CONTAINER_NAME"
  fi

  return $rc
}

container_running() {
  docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qi true
}

container_restart_count() {
  # Suppress TTY allocation errors
  docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null | grep -v "mesg: ttyname failed" || echo 0
}

# Останавливает и удаляет контейнер, если он существует
stop_container() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    log "[>] Останавливаю и удаляю контейнер ${CONTAINER_NAME}…"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || \
      warn "Не удалось удалить контейнер $CONTAINER_NAME"
    sleep 5
  fi
}

resolve_and_pull_base_image() {
  local base_ver="$1" cand ok_tag=""
  for cand in "${base_ver}-ce.0" "${base_ver}"; do
    log "[>] Pulling image gitlab/gitlab-ce:${cand} …"
    if docker pull "gitlab/gitlab-ce:${cand}" >/dev/null 2>&1; then
      ok "[base] найден тег: gitlab/gitlab-ce:${cand}"
      ok_tag="$cand"; break
    else
      warn "тег ${cand} недоступен, пробую следующий…"
    fi
  done
  [ -n "$ok_tag" ] || { err "Не удалось загрузить образ для базовой версии $base_ver"; exit 1; }
  printf "%s" "$ok_tag"
}

latest_patch_tag() {
  local series="$1" tag=""
  case "$series" in
    13.12) tag="13.12.15-ce.0" ;;
    14.0)  tag="14.0.12-ce.0"  ;;
    14.10) tag="14.10.5-ce.0"  ;;
    15.11) tag="15.11.13-ce.0" ;;
    16.11) tag="16.11.8-ce.0"  ;;
    17)    tag="17.5.2-ce.0"   ;;
    *)     tag="${series}.0-ce.0" ;;
  esac
  printf "%s" "$tag"
}

run_container() {
  local image="$1"
  log "[>] Запуск контейнера ${CONTAINER_NAME} c образом ${image}"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  log "[>] Предварительное выравнивание прав (update-permissions)…"
  # Скрипт update-permissions входит в образ GitLab и использует его встроенные утилиты
  # (например, для вычисления UID/GID и исправления множества путей). Запускать его
  # напрямую с хоста сложно: придётся тащить весь необходимый стек. Поэтому мы
  # запускаем короткоживущий контейнер, который выполняет update-permissions в
  # «родной» среде перед стартом основного инстанса.
  docker run --rm \
    -v "$DATA_ROOT/config:/etc/gitlab" \
    -v "$DATA_ROOT/data:/var/opt/gitlab" \
    -v "$DATA_ROOT/logs:/var/log/gitlab" \
    gitlab/gitlab-ce:"$image" update-permissions >/dev/null 2>&1 \
    || warn "update-permissions завершился с ошибкой"
  # Отключаем авто-миграции до восстановления
  touch "$DATA_ROOT/data/skip-auto-migrations" 2>/dev/null || true
  docker run -d --name "$CONTAINER_NAME" --restart=always \
    -e GITLAB_SKIP_DATABASE_MIGRATION=1 \
    -p "$HOST_IP:$PORT_SSH:22" -p "$HOST_IP:$PORT_HTTPS:443" -p "$HOST_IP:$PORT_HTTP:80" \
    -v "$DATA_ROOT/config:/etc/gitlab" \
    -v "$DATA_ROOT/data:/var/opt/gitlab" \
    -v "$DATA_ROOT/logs:/var/log/gitlab" \
    gitlab/gitlab-ce:"$image" >/dev/null
  sleep "$WAIT_AFTER_START"
  show_versions
}

show_versions() {
  echo -n "[i] Image: " >&2
  docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" >&2 || true
  echo -n "[i] GitLab VERSION: " >&2
  dexec 'cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo "unknown"' >&2 || true
}

ensure_permissions() {
  if container_running; then
    log "[>] Выравниваю права (update-permissions)…"
    dexec 'update-permissions >/dev/null 2>&1' || warn "update-permissions завершился с ошибкой"
  fi
}

wait_gitlab_ready() {
  local timeout=${READY_TIMEOUT:-900}
  local progress=${READY_STATUS_INTERVAL:-30}
  log "[>] Ожидаю готовность gitlab-ctl status (таймаут ${timeout}s)…"
  local waited=0
  local last_report=0
  local fmt_total="∞"
  if [ "$timeout" -gt 0 ]; then
    fmt_total=$(printf "%02d:%02d" $((timeout / 60)) $((timeout % 60)))
  fi
  until dexec 'gitlab-ctl status >/dev/null 2>&1'; do
    sleep 3; waited=$((waited+3))
    if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
      warn "gitlab-ctl status не ответил за ${timeout}s — продолжу"
      return 0
    fi
    if [ "$progress" -gt 0 ] && [ $((waited - last_report)) -ge "$progress" ]; then
      local fmt_waited
      fmt_waited=$(printf "%02d:%02d" $((waited / 60)) $((waited % 60)))
      if [ "$timeout" -gt 0 ]; then
        log "    …жду уже ${fmt_waited} из ${fmt_total}"
      else
        log "    …жду уже ${fmt_waited}"
      fi
      last_report=$waited
    fi
  done
  ok "gitlab-ctl status OK"
}

wait_postgres_ready() {
  log "[>] Ожидаю PostgreSQL (unix socket и статус)…"
  local waited=0 timeout=${POSTGRES_READY_TIMEOUT:-$READY_TIMEOUT}
  until dexec 'test -S /var/opt/gitlab/postgresql/.s.PGSQL.5432 && gitlab-ctl status postgresql >/dev/null 2>&1'; do
    sleep 3; waited=$((waited+3))
    if [ "$waited" -ge "$timeout" ]; then
      warn "PostgreSQL не поднялся за ${timeout}s — запускаю reconfigure и продолжаю ждать"
      dexec 'gitlab-ctl reconfigure >/dev/null 2>&1 || true'
      waited=0
    fi
  done
  # Доппроверка коннекта
  log "[>] Проверяю подключение к PostgreSQL…"
  waited=0
  until dexec 'gitlab-psql -c "SELECT 1;" >/dev/null 2>&1'; do
    sleep 5; waited=$((waited+5))
    if [ "$waited" -ge "$timeout" ]; then
      err "PostgreSQL не принимает подключения за ${timeout}s"
      log "[status] Последние строки /var/log/gitlab/postgresql/current:"
      dexec 'tail -n 20 /var/log/gitlab/postgresql/current' 2>&1 \
        | sed -e "s/^/[status] /" >&2 || true
      return 1
    fi
  done
  ok "PostgreSQL готов"
}

wait_container_health() {
  log "[>] Проверяю healthcheck контейнера…"
  local waited=0 status
  while container_running; do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    if [ "$status" = "healthy" ] || [ "$status" = "none" ]; then
      ok "Контейнер в состоянии $status"
      return 0
    fi
    sleep 3; waited=$((waited+3))
    if [ "$waited" -ge "$READY_TIMEOUT" ]; then
      warn "Контейнер не перешёл в состояние healthy за ${READY_TIMEOUT}s (статус: $status)"
      return 0
    fi
  done
  warn "Контейнер не запущен"
}

# New function to wait for upgrade completion with timeout
wait_upgrade_completion() {
  local timeout=$((60 * 30)) # 30 minutes timeout
  local start_time=$(date +%s)
  local current_time
  local elapsed=0
  local last_log_size=0
  local log_file="/var/log/gitlab/reconfigure.log"

  log "[>] Ожидаю завершение апгрейда (таймаут 30 минут)..."

  while [ $elapsed -lt $timeout ]; do
    # Check if reconfigure log exists and is growing
    if dexec "[ -f '$log_file' ]" >/dev/null 2>&1; then
      local current_log_size=$(dexec "stat -c%s '$log_file'" 2>/dev/null || echo 0)
      if [ "$current_log_size" -gt "$last_log_size" ]; then
        last_log_size="$current_log_size"
        # Log is still growing - upgrade in progress
      else
        # Log hasn't grown in 5 minutes - assume upgrade completed
        ok "Апгрейд завершён (лог не растёт)"
        return
      fi
    fi

    # Check if all services are running
    if dexec "gitlab-ctl status" >/dev/null 2>&1; then
      ok "Апгрейд завершён (все службы работают)"
      return
    fi

    sleep 30
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
  done

  warn "Апгрейд не завершился за 30 минут. Пытаюсь перезапустить..."
  dexec 'gitlab-ctl restart >/dev/null 2>&1' || true
  sleep 60
}
