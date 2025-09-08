# lib/docker.sh
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || { err "Запусти как root"; exit 1; }; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || { err "Нужна команда '$1'"; exit 1; }; }
docker_ok() { docker info >/dev/null 2>&1; }

# Use non-login shell to avoid TTY errors
dexec() {
  # Suppress TTY allocation errors
  docker exec -i "$CONTAINER_NAME" bash -c "$1" 2>/dev/null | grep -v "mesg: ttyname failed" || true
}

container_running() {
  docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qi true
}

container_restart_count() {
  # Suppress TTY allocation errors
  docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null | grep -v "mesg: ttyname failed" || echo 0
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
  docker run -d --name "$CONTAINER_NAME" --restart=always \
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

wait_gitlab_ready() {
  log "[>] Ожидаю готовность gitlab-ctl status…"
  local waited=0
  until dexec 'gitlab-ctl status >/dev/null 2>&1'; do
    sleep 3; waited=$((waited+3))
    [ "$waited" -ge "$READY_TIMEOUT" ] && { warn "gitlab-ctl status не ответил за ${READY_TIMEOUT}s — продолжу"; return 0; }
  done
  ok "gitlab-ctl status OK"
}

wait_postgres_ready() {
  log "[>] Ожидаю PostgreSQL (unix socket и статус)…"
  local waited=0
  until dexec 'test -S /var/opt/gitlab/postgresql/.s.PGSQL.5432 && gitlab-ctl status postgresql >/dev/null 2>&1'; do
    sleep 3; waited=$((waited+3))
    if [ "$waited" -ge "$READY_TIMEOUT" ]; then
      warn "PostgreSQL не поднялся за ${READY_TIMEOUT}s — запускаю reconfigure и продолжаю ждать"
      dexec 'gitlab-ctl reconfigure || true'
      waited=0
    fi
  done
  # Доппроверка коннекта
  log "[>] Проверяю подключение к PostgreSQL…"
  waited=0
  until dexec 'gitlab-psql -c "SELECT 1;" >/dev/null 2>&1'; do
    sleep 5; waited=$((waited+5))
    if [ "$waited" -ge "$READY_TIMEOUT" ]; then
      warn "PostgreSQL не принимает подключения за ${READY_TIMEOUT}s — продолжаю с риском"
      break
    fi
  done
  ok "PostgreSQL готов"
}
