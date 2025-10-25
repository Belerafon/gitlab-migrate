# lib/docker.sh
# shellcheck shell=bash
LAST_HEALTH_OK=1
# shellcheck disable=SC2034 # используется в runtime.sh и backup.sh при формировании отчётов
LAST_HEALTH_ISSUES=""
# shellcheck disable=SC2034 # считывается из runtime.sh
LAST_HEALTH_HTTP_INFO=""
# shellcheck disable=SC2034 # считывается из runtime.sh
LAST_HEALTH_HOST_HTTP_INFO=""
HTTP_FAILURE_HINT_SHOWN=0
HTTP_DIAG_LAST_HASH=""
declare -Ag DEXEC_WAIT_LOG_TS=()

GITLAB_RAKE_RESOLVED=0
GITLAB_RAKE_MODE=""
GITLAB_RAKE_PATH=""
# shellcheck disable=SC2034
# используется в background.sh и backup.sh для сообщений об ошибках
GITLAB_RAKE_ERROR=""

GITLAB_RAILS_RESOLVED=0
GITLAB_RAILS_MODE=""
GITLAB_RAILS_PATH=""
# shellcheck disable=SC2034
# используется в background.sh для сообщений об ошибках
GITLAB_RAILS_ERROR=""

string_fingerprint() {
  local input="$1"
  local -a hash_cmd

  if command -v sha256sum >/dev/null 2>&1; then
    hash_cmd=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    hash_cmd=(shasum -a 256)
  elif command -v md5sum >/dev/null 2>&1; then
    hash_cmd=(md5sum)
  else
    hash_cmd=(cksum)
  fi

  printf '%s' "$input" | "${hash_cmd[@]}" | awk '{print $1}'
}

dexec_shorten_command() {
  local cmd="$1"
  cmd=${cmd//$'\n'/ }
  cmd=${cmd//$'\r'/ }
  cmd=${cmd//$'\t'/ }
  while [[ "$cmd" == *"  "* ]]; do
    cmd=${cmd//  / }
  done
  while [[ "$cmd" == ' '* ]]; do
    cmd=${cmd# }
  done
  while [[ "$cmd" == *' ' ]]; do
    cmd=${cmd% }
  done
  if [ ${#cmd} -gt 120 ]; then
    cmd="${cmd:0:117}..."
  fi
  printf "%s" "$cmd"
}

dexec_should_log_wait() {
  local message="$1" interval="${2:-30}" now last
  now=$(date +%s)
  last=${DEXEC_WAIT_LOG_TS["$message"]:-0}

  if [ "$interval" -le 0 ]; then
    DEXEC_WAIT_LOG_TS["$message"]=$now
    return 0
  fi

  if [ "$last" -eq 0 ] || [ $((now - last)) -ge "$interval" ]; then
    DEXEC_WAIT_LOG_TS["$message"]=$now
    return 0
  fi

  return 1
}
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
  local cmd="$1" out rc status should_retry=0 attempts=0 waited=0
  local max_attempts=${DEXEC_WAIT_RETRIES:-60}
  local sleep_between=${DEXEC_WAIT_INTERVAL:-3}
  local log_interval=${DEXEC_WAIT_LOG_INTERVAL:-30}
  local short_cmd="" last_short_cmd="" message

  while true; do
    out=$(docker exec -i "$CONTAINER_NAME" bash -c "$cmd" 2>&1)
    rc=$?
    out=$(printf "%s" "$out" | grep -v "mesg: ttyname failed")

    if [ "$rc" -eq 0 ]; then
      if [ "$attempts" -gt 0 ]; then
        log "[wait] Команда (${last_short_cmd:-bash -c}) выполнилась после ожидания $(format_duration "$waited") (повторов: ${attempts})"
      fi
      printf "%s" "$out"
      return 0
    fi

    status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    should_retry=0

    if [[ "$out" == *"is restarting"* ]] || [[ "$out" == *"No such container"* ]] || [[ "$out" == *"not running"* ]] || [[ "$out" == *"cannot exec in a stopped state"* ]]; then
      should_retry=1
    fi

    case "$status" in
      restarting|created|starting)
        should_retry=1
        ;;
    esac

    if [ "$should_retry" -eq 1 ] && [ "$attempts" -lt "$max_attempts" ]; then
      short_cmd=$(dexec_shorten_command "$cmd")
      message="Контейнер ${CONTAINER_NAME} в состоянии ${status} — ожидаю запуска (повтор: ${short_cmd:-bash -c})"
      if dexec_should_log_wait "$message" "$log_interval"; then
        log "[wait] ${message}"
      fi
      last_short_cmd="$short_cmd"
      sleep "$sleep_between"
      attempts=$((attempts + 1))
      waited=$((waited + sleep_between))
      continue
    fi

    if [ "$should_retry" -eq 1 ]; then
      warn "[dexec] Контейнер ${CONTAINER_NAME} не стал доступен за $(format_duration "$waited") (последний статус: ${status})"
    fi

    break
  done

  if [ -n "$out" ]; then
    printf "%s" "$out"
  fi

  if [ "$rc" -ne 0 ] && { [[ "$out" == *"OCI runtime exec failed"* ]] || ! container_running; }; then
    warn "[dexec] docker exec завершился с кодом $rc"
    log "------ Статус контейнера ------"
    docker ps -a --filter "name=$CONTAINER_NAME" 2>&1 || true
    log "------ Подсказка по логам ------"
    log "docker logs --tail 20 $CONTAINER_NAME"
  fi

  if [ "$attempts" -gt 0 ]; then
    log "[wait] Команда (${last_short_cmd:-bash -c}) не завершилась успешно после ожидания $(format_duration "$waited") (повторов: ${attempts})"
  fi

  return $rc
}

gitlab_rake_resolve() {
  if [ "${GITLAB_RAKE_RESOLVED:-0}" -eq 1 ] && [ "${GITLAB_RAKE_MODE:-missing}" != "missing" ]; then
    return 0
  fi

  GITLAB_RAKE_ERROR=""
  GITLAB_RAKE_MODE=""
  GITLAB_RAKE_PATH=""

  if dexec 'command -v gitlab-rake >/dev/null 2>&1'; then
    GITLAB_RAKE_MODE="direct"
    GITLAB_RAKE_PATH="gitlab-rake"
    GITLAB_RAKE_RESOLVED=1
    return 0
  fi

  if dexec '[ -x /opt/gitlab/bin/gitlab-rake ]'; then
    GITLAB_RAKE_MODE="direct"
    GITLAB_RAKE_PATH="/opt/gitlab/bin/gitlab-rake"
    GITLAB_RAKE_RESOLVED=1
    return 0
  fi

  if dexec '[ -x /opt/gitlab/embedded/bin/gitlab-rake ]'; then
    GITLAB_RAKE_MODE="direct"
    GITLAB_RAKE_PATH="/opt/gitlab/embedded/bin/gitlab-rake"
    GITLAB_RAKE_RESOLVED=1
    return 0
  fi

  if dexec '[ -d /opt/gitlab/embedded/service/gitlab-rails ] && [ -f /opt/gitlab/embedded/service/gitlab-rails/Rakefile ]'; then
    GITLAB_RAKE_MODE="bundle"
    GITLAB_RAKE_PATH="/opt/gitlab/embedded/service/gitlab-rails"
    GITLAB_RAKE_RESOLVED=1
    return 0
  fi

  GITLAB_RAKE_MODE="missing"
  GITLAB_RAKE_PATH=""
  # shellcheck disable=SC2034
  GITLAB_RAKE_ERROR="Команда gitlab-rake не найдена и не удалось определить bundle exec rake"
  GITLAB_RAKE_RESOLVED=0
  return 1
}

gitlab_rake_available() {
  gitlab_rake_resolve
}

gitlab_rake() {
  local args=() args_str="" quoted rake_cmd quoted_rake_cmd cmd cd_path

  if ! gitlab_rake_resolve; then
    return 127
  fi

  if [ "$#" -gt 0 ]; then
    args=("$@")
    for quoted in "${args[@]}"; do
      quoted=$(printf '%q' "$quoted")
      if [ -z "$args_str" ]; then
        args_str="$quoted"
      else
        args_str+=" $quoted"
      fi
    done
  fi

  if [ "${GITLAB_RAKE_MODE}" = "direct" ]; then
    if [ -n "$args_str" ]; then
      cmd="${GITLAB_RAKE_PATH} ${args_str}"
    else
      cmd="${GITLAB_RAKE_PATH}"
    fi
    dexec "$cmd"
    return $?
  fi

  # bundle mode fallback
  rake_cmd="bundle exec rake"
  if [ -n "$args_str" ]; then
    rake_cmd+=" ${args_str}"
  fi
  rake_cmd+=" RAILS_ENV=production"
  quoted_rake_cmd=$(printf '%q' "$rake_cmd")
  cd_path=$(printf '%q' "$GITLAB_RAKE_PATH")

  cmd="cd ${cd_path} && "
  cmd+="if command -v chpst >/dev/null 2>&1; then "
  cmd+="chpst -u git bash -lc ${quoted_rake_cmd}; "
  cmd+="elif command -v sudo >/dev/null 2>&1; then "
  cmd+="sudo -u git -H bash -lc ${quoted_rake_cmd}; "
  cmd+="else "
  cmd+="su -s /bin/bash git -c ${quoted_rake_cmd}; "
  cmd+="fi"

  dexec "$cmd"
}

gitlab_rails_resolve() {
  if [ "${GITLAB_RAILS_RESOLVED:-0}" -eq 1 ] && [ "${GITLAB_RAILS_MODE:-missing}" != "missing" ]; then
    return 0
  fi

  GITLAB_RAILS_ERROR=""
  GITLAB_RAILS_MODE=""
  GITLAB_RAILS_PATH=""

  if dexec 'command -v gitlab-rails >/dev/null 2>&1'; then
    GITLAB_RAILS_MODE="direct"
    GITLAB_RAILS_PATH="gitlab-rails"
    GITLAB_RAILS_RESOLVED=1
    return 0
  fi

  if dexec '[ -x /opt/gitlab/bin/gitlab-rails ]'; then
    GITLAB_RAILS_MODE="direct"
    GITLAB_RAILS_PATH="/opt/gitlab/bin/gitlab-rails"
    GITLAB_RAILS_RESOLVED=1
    return 0
  fi

  if dexec '[ -x /opt/gitlab/embedded/bin/gitlab-rails ]'; then
    GITLAB_RAILS_MODE="direct"
    GITLAB_RAILS_PATH="/opt/gitlab/embedded/bin/gitlab-rails"
    GITLAB_RAILS_RESOLVED=1
    return 0
  fi

  if dexec '[ -d /opt/gitlab/embedded/service/gitlab-rails ] && [ -f /opt/gitlab/embedded/service/gitlab-rails/bin/rails ]'; then
    GITLAB_RAILS_MODE="bundle"
    GITLAB_RAILS_PATH="/opt/gitlab/embedded/service/gitlab-rails"
    GITLAB_RAILS_RESOLVED=1
    return 0
  fi

  GITLAB_RAILS_MODE="missing"
  GITLAB_RAILS_PATH=""
  # shellcheck disable=SC2034
  GITLAB_RAILS_ERROR="Команда gitlab-rails недоступна и не удалось определить bundle exec rails"
  GITLAB_RAILS_RESOLVED=0
  return 1
}

gitlab_rails_available() {
  gitlab_rails_resolve
}

gitlab_rails_runner() {
  local code="$1" env="${2:-production}" escaped_code cmd cd_path

  if ! gitlab_rails_resolve; then
    return 127
  fi

  escaped_code=$(printf '%q' "$code")

  if [ "${GITLAB_RAILS_MODE}" = "direct" ]; then
    cmd="${GITLAB_RAILS_PATH} runner -e ${env} ${escaped_code}"
    dexec "$cmd"
    return $?
  fi

  cd_path=$(printf '%q' "$GITLAB_RAILS_PATH")
  cmd="cd ${cd_path} && RAILS_ENV=${env} bundle exec rails runner -e ${env} ${escaped_code}"
  dexec "$cmd"
}

container_running() {
  docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qi true
}

container_restart_count() {
  # Suppress TTY allocation errors
  docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null | grep -v "mesg: ttyname failed" || echo 0
}

container_status_summary() {
  local status health restarts
  status=$(docker inspect -f 'status={{.State.Status}}, pid={{.State.Pid}}' "$CONTAINER_NAME" 2>/dev/null || echo "status=unknown")
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
  restarts=$(container_restart_count)
  printf "%s; health=%s; restarts=%s" "$status" "$health" "$restarts"
}

permissions_mark_pending() {
  set_state PERMISSIONS_PENDING 1
}

permissions_clear_pending() {
  set_state PERMISSIONS_PENDING 0
}

permissions_is_pending() {
  [ "$(get_state PERMISSIONS_PENDING || true)" = "1" ]
}

run_update_permissions_image() {
  local image_ref="$1"
  if [ -z "$image_ref" ]; then
    warn "Не указан образ для update-permissions"
    return 1
  fi

  if [[ "$image_ref" != */* ]]; then
    image_ref="gitlab/gitlab-ce:${image_ref}"
  fi

  docker run --rm \
    -v "$DATA_ROOT/config:/etc/gitlab" \
    -v "$DATA_ROOT/data:/var/opt/gitlab" \
    -v "$DATA_ROOT/logs:/var/log/gitlab" \
    "$image_ref" update-permissions >/dev/null 2>&1
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
    16.0)  tag="16.0.10-ce.0"  ;;
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
  if run_update_permissions_image "$image"; then
    permissions_clear_pending
  else
    warn "update-permissions завершился с ошибкой"
    permissions_mark_pending
  fi
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

gitlab_detect_version_for_health_checks() {
  local version=""

  if declare -F current_gitlab_version >/dev/null 2>&1; then
    version="$(current_gitlab_version 2>/dev/null || true)"
  else
    version="$(dexec 'cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null' 2>/dev/null || true)"
  fi

  version="${version//$'\r'/}"
  version="${version//$'\n'/}"

  printf '%s' "$version"
}

gitlab_service_optional() {
  local service="$1" version="${2-}" reason_var="${3-}" reason=""

  if [ -z "$service" ]; then
    if [ -n "$reason_var" ]; then
      printf -v "$reason_var" '%s' ""
    fi
    return 1
  fi

  if [ -z "$version" ]; then
    version="$(gitlab_detect_version_for_health_checks)"
  fi

  version="${version%%-*}"
  version="${version%%+*}"
  version="$(printf '%s' "$version" | tr -d '[:space:]')"

  local major="" minor=""
  IFS=. read -r major minor _ <<< "$version"

  if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$minor" =~ ^[0-9]+$ ]]; then
    if [ -n "$reason_var" ]; then
      printf -v "$reason_var" '%s' ""
    fi
    return 1
  fi

  case "$service" in
    grafana)
      if [ "$major" -eq 13 ] && [ "$minor" -eq 1 ]; then
        reason="Grafana не входит в образ GitLab ${version}, сервис считается необязательным"
      fi
      ;;
  esac

  if [ -n "$reason_var" ]; then
    printf -v "$reason_var" '%s' "$reason"
  fi

  [ -n "$reason" ]
}

shorten_http_probe_label() {
  local label="$1"
  label="${label//, self-signed/}"
  printf '%s' "$label"
}

shorten_http_probe_detail() {
  local detail="$1" code="$2" normalized=""

  normalized="$(printf '%s' "${detail}" | tr '\r' ' ' | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //; s/ $//')"

  if [ -z "$normalized" ]; then
    printf '%s' "${code:-000}"
    return 0
  fi

  if [ "$code" = "000" ] && [[ "$normalized" == *" 000" ]]; then
    normalized="${normalized% 000}"
  fi

  if [ "$code" = "000" ] && [[ "$normalized" =~ curl:\ \(([0-9]+)\) ]]; then
    printf 'curl#%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$normalized" =~ ^[0-9]{3}$ ]]; then
    printf '%s' "$normalized"
    return 0
  fi

  if [ "$normalized" = "NO_CURL" ]; then
    printf '%s' "curl-missing"
    return 0
  fi

  if [ "$code" = "000" ]; then
    printf '%s' "$(printf '%s' "$normalized" | cut -c1-40)"
    return 0
  fi

  printf '%s' "$(printf '%s' "$normalized" | cut -c1-60)"
}

format_http_probe_attempt() {
  local label detail code="$3" short_label short_detail
  short_label="$(shorten_http_probe_label "$1")"
  detail="$2"
  short_detail="$(shorten_http_probe_detail "$detail" "$code")"
  if [ -n "$short_detail" ]; then
    printf '%s=%s' "$short_label" "$short_detail"
  else
    printf '%s=%s' "$short_label" "${code:-000}"
  fi
}

probe_gitlab_http() {
  local endpoints=(
    "http://127.0.0.1:8080/-/readiness|readiness (workhorse:8080)"
    "http://127.0.0.1/-/readiness|readiness (nginx:80)"
    "https://127.0.0.1/-/readiness|readiness (nginx:443, self-signed)"
    "http://127.0.0.1:8080/users/sign_in|страница входа (workhorse:8080)"
    "https://127.0.0.1/users/sign_in|страница входа (nginx:443, self-signed)"
  )
  local attempts=()
  local entry url desc opts command output quoted_url code clean_output

  for entry in "${endpoints[@]}"; do
    IFS='|' read -r url desc <<<"$entry"
    opts='-sS'
    [[ "$url" == https://* ]] && opts='-ksS'
    printf -v quoted_url '%q' "$url"
    command="if command -v curl >/dev/null 2>&1; then curl ${opts} --max-time 10 --connect-timeout 5 -o /dev/null -w '%{http_code}' ${quoted_url}; else echo NO_CURL; fi"
    output=$(dexec "$command" 2>&1 || true)
    output="${output//$'\r'/}"
    code="${output##*$'\n'}"
    clean_output="${output//$'\n'/ }"
    attempts+=("$(format_http_probe_attempt "$desc" "${clean_output:-n/a}" "$code")")
    if [ "$clean_output" = "NO_CURL" ]; then
      printf '%s' "curl недоступен в контейнере"
      return 1
    fi
    if [[ "$code" =~ ^[0-9]{3}$ ]] && [ "$code" != "000" ]; then
      printf 'HTTP %s (%s)' "$code" "$desc"
      return 0
    fi
  done

  local summary
  summary=$(IFS='; '; echo "${attempts[*]}")
  printf 'HTTP недоступен (%s)' "$summary"
  return 1
}

probe_gitlab_http_host() {
  local http_port="${PORT_HTTP:-80}"
  local raw_host="${HOST_IP:-}"
  local effective_host="" url_host="" url="" desc="" display_url=""
  local attempts=()
  local output code clean_output summary
  local -a curl_args

  if ! command -v curl >/dev/null 2>&1; then
    printf '%s' "curl недоступен на хосте"
    return 1
  fi

  if [ -z "$raw_host" ] || [ "$raw_host" = "0.0.0.0" ]; then
    effective_host="127.0.0.1"
  else
    effective_host="$raw_host"
  fi

  url_host="$effective_host"
  if [[ "$url_host" == *:* ]] && [[ "$url_host" != \[* ]]; then
    url_host="[${url_host}]"
  fi

  url="http://${url_host}:${http_port}/users/sign_in"
  display_url="$url"
  desc="host login (${display_url})"

  curl_args=(-sS --max-time 10 --connect-timeout 5 -o /dev/null -w "%{http_code}")
  output=$(curl "${curl_args[@]}" "$url" 2>&1 || true)
  output="${output//$'\r'/}"
  code="${output##*$'\n'}"
  clean_output="${output//$'\n'/ }"
  attempts+=("$(format_http_probe_attempt "$desc" "${clean_output:-n/a}" "$code")")

  if [[ "$code" =~ ^[0-9]{3}$ ]]; then
    case "$code" in
      2??|3??|401|403)
        printf 'HTTP %s (%s)' "$code" "$desc"
        return 0
        ;;
    esac
  fi

  summary=$(IFS='; '; echo "${attempts[*]}")
  printf 'HTTP недоступен (%s)' "$summary"
  return 1
}

report_basic_health() {
  local context="${1-}" mode="${2-}" check_db=1
  [ "$mode" = "skip-db" ] && check_db=0

  LAST_HEALTH_OK=1
  LAST_HEALTH_ISSUES=""
  LAST_HEALTH_HTTP_INFO=""
  LAST_HEALTH_HOST_HTTP_INFO=""

  if [ -n "$context" ]; then
    log "[>] Базовая проверка состояния GitLab (${context}):"
  else
    log "[>] Базовая проверка состояния GitLab:"
  fi

  local issues=()

  if ! container_running; then
    warn "    - Контейнер ${CONTAINER_NAME} не запущен"
    issues+=("контейнер не запущен")
    LAST_HEALTH_OK=0
    LAST_HEALTH_ISSUES="контейнер не запущен"
    LAST_HEALTH_HTTP_INFO="контейнер не запущен"
    LAST_HEALTH_HOST_HTTP_INFO="контейнер не запущен"
    return 0
  fi

  local container_state restart_count
  container_state=$(docker inspect -f 'status={{.State.Status}}, pid={{.State.Pid}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
  restart_count=$(container_restart_count)
  log "    - Контейнер: ${container_state}; перезапусков: ${restart_count}"

  local http_output http_info="" http_rc host_http_output host_http_info="" host_http_rc
  if http_output=$(probe_gitlab_http); then
    http_info="$http_output"
    log "    - HTTP (из контейнера): ${http_info}"
    http_rc=0
  else
    http_rc=$?
    http_info="$http_output"
    warn "    - HTTP (из контейнера): ${http_info:-проверка не выполнена}"
  fi
  # shellcheck disable=SC2034 # значение читается из runtime.sh
  LAST_HEALTH_HTTP_INFO="${http_info:-проверка не выполнена}"

  if host_http_output=$(probe_gitlab_http_host); then
    host_http_info="$host_http_output"
    log "    - HTTP (с хоста): ${host_http_info}"
    host_http_rc=0
  else
    host_http_rc=$?
    host_http_info="$host_http_output"
    warn "    - HTTP (с хоста): ${host_http_info:-проверка не выполнена}"
  fi
  # shellcheck disable=SC2034 # значение читается из runtime.sh
  LAST_HEALTH_HOST_HTTP_INFO="${host_http_info:-проверка не выполнена}"

  local ctl_output ctl_rc=0 suppressed_optional_message=""
  if ctl_output=$(dexec 'gitlab-ctl status' 2>&1); then
    ctl_rc=0
  else
    ctl_rc=$?
  fi
  if [ -n "$ctl_output" ] && [ "$ctl_rc" -ne 0 ]; then
    local gitlab_version_for_checks="" non_optional_found=0
    local -a optional_services=() optional_details=()
    gitlab_version_for_checks="$(gitlab_detect_version_for_health_checks)"

    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*(down|fail|warning):[[:space:]]*([a-zA-Z0-9_-]+) ]]; then
        local svc="${BASH_REMATCH[2]}" reason=""

        if gitlab_service_optional "$svc" "$gitlab_version_for_checks" reason; then
          if [[ " ${optional_services[*]} " != *" $svc "* ]]; then
            [ -n "$reason" ] || reason="необязательный сервис для GitLab ${gitlab_version_for_checks:-unknown}"
            optional_services+=("$svc")
            optional_details+=("$svc: $reason")
          fi
        else
          non_optional_found=1
        fi
      fi
    done <<< "$ctl_output"

    if [ "$non_optional_found" -eq 0 ] && [ ${#optional_services[@]} -gt 0 ]; then
      ctl_rc=0
      suppressed_optional_message="Игнорирую статус служб: $(IFS='; '; echo "${optional_details[*]}")"
    fi
  fi
  if [ -n "$ctl_output" ]; then
    if [ "$ctl_rc" -eq 0 ]; then
      log "    - Службы (gitlab-ctl status):"
    else
      warn "    - gitlab-ctl status завершился с кодом ${ctl_rc}"
      issues+=("gitlab-ctl status rc=${ctl_rc}")
      log "      вывод команды:"
    fi
    printf '%s\n' "$ctl_output" | sed 's/^/      /'
    if [ -n "$suppressed_optional_message" ]; then
      log "      ${suppressed_optional_message}"
    fi
  else
    warn "    - gitlab-ctl status не вернул данных"
    issues+=("gitlab-ctl status не вернул данных")
  fi

  if [ "$check_db" -eq 1 ]; then
    if dexec 'gitlab-psql -d gitlabhq_production -c "SELECT 1;" >/dev/null 2>&1'; then
      log "    - PostgreSQL: SELECT 1 выполняется"
    else
      warn "    - PostgreSQL: нет ответа на SELECT 1"
      issues+=("PostgreSQL SELECT 1 не выполняется")
    fi
  else
    log "    - PostgreSQL: проверка пропущена (ожидаем готовность)"
  fi

  if [ "${http_rc:-1}" -ne 0 ]; then
    issues+=("HTTP (из контейнера): ${http_info:-проверка не выполнена}")
  fi
  if [ "${host_http_rc:-1}" -ne 0 ]; then
    issues+=("HTTP (с хоста): ${host_http_info:-проверка не выполнена}")
  fi

  if [ "${http_rc:-1}" -ne 0 ] || [ "${host_http_rc:-1}" -ne 0 ]; then
    print_http_failure_diagnostics "$context"
  else
    HTTP_DIAG_LAST_HASH=""
  fi

  if [ ${#issues[@]} -gt 0 ]; then
    LAST_HEALTH_OK=0
    LAST_HEALTH_ISSUES=$(IFS='; '; echo "${issues[*]}")
  else
    LAST_HEALTH_OK=1
    # shellcheck disable=SC2034 # используется внешними сценариями для итогового отчёта
    LAST_HEALTH_ISSUES="OK"
  fi

  return 0
}

print_http_failure_diagnostics() {
  local context="$1"

  log "    - Диагностика HTTP (${context:-без контекста}):"

  if [ "${HTTP_FAILURE_HINT_SHOWN:-0}" -eq 0 ]; then
    log "      Где искать дополнительную информацию на хосте:"
    log "        Лог миграции: ${LOG_FILE:-не задан}"
    log "        Логи GitLab: $DATA_ROOT/logs"
    HTTP_FAILURE_HINT_SHOWN=1
  fi

  if ! container_running; then
    log "      Контейнер ${CONTAINER_NAME} не запущен — HTTP недоступен и логи не собрать"
    return
  fi

  local script
  script=$(cat <<'EOS'
tail_lines=${HTTP_LOG_TAIL_LINES:-40}

filter_log_noise() {
  local file="$1"

  case "$file" in
    /var/log/gitlab/gitlab-workhorse/current)
      awk '
        /"level":"info"/ {
          if (/"msg":"Send static file"/) { next }
          if (/"msg":"access"/) {
            if (/"status":[45][0-9][0-9]/) { print; next }
            next
          }
          if (/"msg":"success"/ && /"subsystem":"imageresizer"/) { next }
        }
        { print }
      '
      ;;
    /var/log/gitlab/puma/puma_stdout.log)
      awk '!/PumaWorkerKiller: Consuming/'
      ;;
    /var/log/gitlab/gitlab-rails/production.log)
      awk '!/^Creating scope / && !/^Raven [0-9.]+ configured not to capture errors/'
      ;;
    *)
      cat
      ;;
  esac
}

print_log_tail() {
  local file="$1"
  local raw filtered raw_lines

  if [ ! -f "$file" ]; then
    return
  fi

  if command -v tai64nlocal >/dev/null 2>&1 && [ "${file##*/}" = "current" ]; then
    raw="$(tail -n "$tail_lines" "$file" | tai64nlocal)"
  else
    raw="$(tail -n "$tail_lines" "$file")"
  fi

  if [ -z "$raw" ]; then
    return
  fi

  filtered="$(printf '%s\n' "$raw" | filter_log_noise "$file")"

  if [ -n "$filtered" ]; then
    printf '%s\n' "$filtered"
    return
  fi

  raw_lines=$(printf '%s\n' "$raw" | awk 'END{print NR}')
  printf '[отфильтрованы %s строк(и) без значимых событий]\n' "$raw_lines"
}

for file in \
  /var/log/gitlab/gitlab-workhorse/current \
  /var/log/gitlab/nginx/current \
  /var/log/gitlab/nginx/gitlab_error.log \
  /var/log/gitlab/puma/puma_stdout.log \
  /var/log/gitlab/puma/puma_stderr.log \
  /var/log/gitlab/gitlab-rails/production.log; do
  if [ -f "$file" ]; then
    echo "----- $file -----"
    print_log_tail "$file"
    echo
  fi
done
EOS
)

  if [ -n "$script" ]; then
    local diagnostics="" diagnostics_hash=""
    diagnostics=$(dexec "$script" 2>&1 || true)

    if [ -n "$diagnostics" ]; then
      diagnostics_hash=$(string_fingerprint "$diagnostics")
    fi

    if [ -n "$diagnostics_hash" ] && [ "$diagnostics_hash" = "$HTTP_DIAG_LAST_HASH" ]; then
      log "      (Диагностика логов не изменилась — повторный вывод пропущен)"
    else
      HTTP_DIAG_LAST_HASH="$diagnostics_hash"
      printf '%s\n' "$diagnostics" | sed 's/^/      /' >&2
    fi
  else
    HTTP_DIAG_LAST_HASH=""
  fi

  log "      Команды для ручной диагностики:"
  log "        docker logs --tail 200 $CONTAINER_NAME"
  log "        docker exec -it $CONTAINER_NAME gitlab-ctl tail nginx"
  log "        docker exec -it $CONTAINER_NAME gitlab-ctl tail gitlab-workhorse"
  log "        docker exec -it $CONTAINER_NAME gitlab-ctl tail puma"
}

ensure_gitlab_health() {
  local context="$1" mode="${2-}"
  report_basic_health "$context" "$mode"
  [ "${LAST_HEALTH_OK:-0}" = "1" ]
}

ensure_permissions() {
  if ! permissions_is_pending; then
    log "[>] Выравнивание прав не требуется — пропускаю"
    return
  fi

  local image running=0
  image=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)
  if [ -z "$image" ]; then
    warn "Не удалось определить образ контейнера для update-permissions"
    return
  fi

  if container_running; then
    running=1
    log "[>] Останавливаю контейнер перед выравниванием прав…"
    if ! docker stop "$CONTAINER_NAME" >/dev/null 2>&1; then
      warn "Не удалось остановить контейнер $CONTAINER_NAME"
    fi
    sleep 5
  fi

  log "[>] Выравниваю права (update-permissions)…"
  if run_update_permissions_image "$image"; then
    permissions_clear_pending
  else
    warn "update-permissions завершился с ошибкой"
  fi

  if [ $running -eq 1 ]; then
    log "[>] Запускаю контейнер после выравнивания прав…"
    if ! docker start "$CONTAINER_NAME" >/dev/null 2>&1; then
      warn "Не удалось запустить контейнер $CONTAINER_NAME"
    fi
    sleep "$WAIT_AFTER_START"
  fi
}

wait_gitlab_ready() {
  local ctl_timeout=${READY_TIMEOUT:-900}
  local ctl_progress=${READY_STATUS_INTERVAL:-30}
  local http_timeout=${READY_HTTP_TIMEOUT:-$ctl_timeout}
  local http_progress=${READY_HTTP_PROGRESS:-15}
  local http_stable_window=${READY_HTTP_STABLE_WINDOW:-30}
  local ctl_waited=0
  local ctl_last_report=0
  local ctl_fmt_total="∞"
  local ctl_success=0
  local start_ts now

  log "[>] Ожидаю готовность gitlab-ctl status (таймаут ${ctl_timeout}s)…"

  if [ "${ctl_timeout}" -gt 0 ]; then
    ctl_fmt_total=$(printf "%02d:%02d" $((ctl_timeout / 60)) $((ctl_timeout % 60)))
  fi

  start_ts=$(date +%s)

  while true; do
    if dexec 'gitlab-ctl status >/dev/null 2>&1'; then
      ctl_success=1
      break
    fi

    sleep 3
    now=$(date +%s)
    ctl_waited=$((now - start_ts))

    if [ "${ctl_timeout}" -gt 0 ] && [ "$ctl_waited" -ge "${ctl_timeout}" ]; then
      break
    fi

    if [ "${ctl_progress}" -gt 0 ] && [ $((ctl_waited - ctl_last_report)) -ge "${ctl_progress}" ]; then
      local fmt_waited
      fmt_waited=$(printf "%02d:%02d" $((ctl_waited / 60)) $((ctl_waited % 60)))
      if [ "${ctl_timeout}" -gt 0 ]; then
        log "    …жду уже ${fmt_waited} из ${ctl_fmt_total}"
      else
        log "    …жду уже ${fmt_waited}"
      fi
      ctl_last_report=$ctl_waited
    fi
  done

  if [ "$ctl_success" -eq 0 ]; then
    if [ "${ctl_timeout}" -gt 0 ]; then
      err "gitlab-ctl status не ответил за ${ctl_timeout}s"
    else
      err "gitlab-ctl status не ответил"
    fi
    report_basic_health "после ожидания gitlab-ctl status" "skip-db"
    return 1
  fi

  ok "gitlab-ctl status OK"

  log "[>] Ожидаю доступность HTTP GitLab (стабильность ${http_stable_window}s; таймаут ${http_timeout}s)…"

  local http_start_ts http_waited=0
  local http_last_report=0
  local container_ready_since=0
  local host_ready_since=0
  local container_status=""
  local host_status=""
  local sleep_interval=5
  local ready=0

  http_start_ts=$(date +%s)

  while true; do
    now=$(date +%s)
    http_waited=$((now - http_start_ts))

    local container_rc=0 host_rc=0
    container_status=$(probe_gitlab_http 2>&1) || container_rc=$?
    host_status=$(probe_gitlab_http_host 2>&1) || host_rc=$?

    if [ "$container_rc" -eq 0 ]; then
      if [ "$container_ready_since" -eq 0 ]; then
        container_ready_since=$now
        log "    HTTP из контейнера стал отвечать: ${container_status}"
      fi
    else
      container_ready_since=0
    fi

    if [ "$host_rc" -eq 0 ]; then
      if [ "$host_ready_since" -eq 0 ]; then
        host_ready_since=$now
        log "    HTTP с хоста стал отвечать: ${host_status}"
      fi
    else
      host_ready_since=0
    fi

    if [ "$container_ready_since" -gt 0 ] && [ "$host_ready_since" -gt 0 ]; then
      local earliest_ready="$container_ready_since"
      if [ "$host_ready_since" -lt "$earliest_ready" ]; then
        earliest_ready="$host_ready_since"
      fi
      local stable_elapsed=$((now - earliest_ready))
      if [ "$stable_elapsed" -ge "$http_stable_window" ]; then
        ready=1
        break
      fi
    fi

    if [ "${http_timeout}" -gt 0 ] && [ "$http_waited" -ge "${http_timeout}" ]; then
      break
    fi

    if [ "${http_progress}" -gt 0 ] && [ $((http_waited - http_last_report)) -ge "${http_progress}" ]; then
      local waited_fmt reason_msg
      waited_fmt=$(format_duration "$http_waited")

      if [ "$container_ready_since" -gt 0 ] && [ "$host_ready_since" -gt 0 ]; then
        local stable_elapsed stable_left earliest_ready
        earliest_ready="$container_ready_since"
        if [ "$host_ready_since" -lt "$earliest_ready" ]; then
          earliest_ready="$host_ready_since"
        fi
        stable_elapsed=$((now - earliest_ready))
        if [ "$stable_elapsed" -lt "$http_stable_window" ]; then
          stable_left=$((http_stable_window - stable_elapsed))
          reason_msg="ожидание стабильности ещё $(format_duration "$stable_left") из $(format_duration "$http_stable_window")"
        else
          reason_msg="ожидание стабильности"
        fi
      else
        reason_msg="ожидание готовности HTTP"
      fi

      log "    …HTTP ещё не готов (${reason_msg}; общее ожидание ${waited_fmt}); контейнер: ${container_status:-недоступен}; хост: ${host_status:-недоступен}" \
        " (статус контейнера: $(container_status_summary))"
      http_last_report=$http_waited
    fi

    sleep "$sleep_interval"
  done

  if [ "$ready" -eq 0 ]; then
    if [ "${http_timeout}" -gt 0 ]; then
      err "HTTP GitLab недоступен за $(format_duration "${http_timeout}")"
    else
      err "HTTP GitLab недоступен"
    fi
    report_basic_health "после ожидания готовности GitLab" "skip-db"
    return 1
  fi

  ok "HTTP GitLab готов (контейнер: ${container_status}; хост: ${host_status})"

  report_basic_health "после ожидания готовности GitLab" "skip-db"
}

wait_postgres_ready() {
  log "[>] Ожидаю PostgreSQL (unix socket и статус)…"
  local timeout=${POSTGRES_READY_TIMEOUT:-$READY_TIMEOUT}
  local progress=${POSTGRES_READY_PROGRESS:-30}
  local waited=0 socket_waited=0
  local reconfigure_attempts=0
  local fmt_timeout="∞"

  if [ "${timeout:-0}" -gt 0 ]; then
    fmt_timeout=$(format_duration "$timeout")
  fi

  until dexec 'test -S /var/opt/gitlab/postgresql/.s.PGSQL.5432 && gitlab-ctl status postgresql >/dev/null 2>&1'; do
    sleep 3
    waited=$((waited + 3))

    if [ "${progress:-0}" -gt 0 ] && [ $((waited % progress)) -eq 0 ]; then
      if [ "${timeout:-0}" -gt 0 ]; then
        log "[wait] PostgreSQL ещё не поднялся (ожидание $(format_duration "$waited") из ${fmt_timeout}). Статус контейнера: $(container_status_summary)"
      else
        log "[wait] PostgreSQL ещё не поднялся (ожидание $(format_duration "$waited")). Статус контейнера: $(container_status_summary)"
      fi
    fi

    if [ "${timeout:-0}" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
      reconfigure_attempts=$((reconfigure_attempts + 1))
      warn "PostgreSQL не поднялся за ${fmt_timeout} — запускаю reconfigure и продолжаю ждать (попытка ${reconfigure_attempts})"
      dexec 'gitlab-ctl reconfigure >/dev/null 2>&1 || true'
      waited=0
    fi
  done

  socket_waited=$waited
  if [ "$socket_waited" -gt 0 ]; then
    log "[wait] Unix socket PostgreSQL стал доступен через $(format_duration "$socket_waited")"
  fi

  # Доппроверка коннекта
  log "[>] Проверяю подключение к PostgreSQL…"
  waited=0
  until dexec 'gitlab-psql -c "SELECT 1;" >/dev/null 2>&1'; do
    sleep 5
    waited=$((waited + 5))

    if [ "${progress:-0}" -gt 0 ] && [ $((waited % progress)) -eq 0 ]; then
      if [ "${timeout:-0}" -gt 0 ]; then
        log "[wait] SELECT 1 ещё не выполняется (ожидание $(format_duration "$waited") из ${fmt_timeout}). Статус контейнера: $(container_status_summary)"
      else
        log "[wait] SELECT 1 ещё не выполняется (ожидание $(format_duration "$waited")). Статус контейнера: $(container_status_summary)"
      fi
    fi

    if [ "${timeout:-0}" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
      err "PostgreSQL не принимает подключения за ${fmt_timeout}"
      log "[status] Текущий статус контейнера: $(container_status_summary)"
      log "[status] Последние строки /var/log/gitlab/postgresql/current:"
      dexec 'tail -n 20 /var/log/gitlab/postgresql/current' 2>&1 \
        | sed -e "s/^/[status] /" >&2 || true
      return 1
    fi
  done

  ok "PostgreSQL готов"
  report_basic_health "после ожидания PostgreSQL"
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
  local timeout=${UPGRADE_COMPLETION_TIMEOUT:-1800}
  local poll_interval=${UPGRADE_COMPLETION_POLL_INTERVAL:-15}
  local quiet_window=${UPGRADE_RECONFIGURE_QUIET_WINDOW:-300}
  local progress_interval=${UPGRADE_COMPLETION_PROGRESS_INTERVAL:-60}
  local ready_retry_delay=${UPGRADE_COMPLETION_READY_RETRY:-60}
  local log_file="/var/log/gitlab/reconfigure.log"

  local start_time current_time elapsed=0
  local last_report=0
  local stat_info="" stat_rc=0
  local current_mtime=0 current_size=0
  local last_mtime=0 last_size=0
  local last_growth_ts=0
  local seen_activity=0
  local last_ready_attempt=0

  start_time=$(date +%s)
  last_growth_ts=$start_time

  if [ "$poll_interval" -le 0 ]; then
    poll_interval=15
  fi

  local timeout_display="∞"
  if [ "$timeout" -gt 0 ]; then
    timeout_display=$(format_duration "$timeout")
  fi

  log "[>] Ожидаю завершение апгрейда (таймаут ${timeout_display})…"

  while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))

    stat_rc=0
    stat_info=""
    stat_info=$(dexec "stat -c '%Y %s' '$log_file'" 2>/dev/null) || stat_rc=$?
    stat_info="${stat_info//$'\r'/}"; stat_info="${stat_info//$'\n'/ }"

    if [ "$stat_rc" -eq 0 ] && [ -n "$stat_info" ]; then
      current_mtime=${stat_info%% *}
      current_size=${stat_info##* }

      if ! [[ "$current_mtime" =~ ^[0-9]+$ ]]; then
        current_mtime=0
      fi
      if ! [[ "$current_size" =~ ^[0-9]+$ ]]; then
        current_size=0
      fi

      if [ "$last_mtime" -eq 0 ]; then
        last_mtime=$current_mtime
        last_size=$current_size
      fi

      if [ "$current_mtime" -gt "$last_mtime" ] || [ "$current_size" -gt "$last_size" ]; then
        seen_activity=1
        last_mtime=$current_mtime
        last_size=$current_size
        last_growth_ts=$current_time
      fi
    fi

    local ctl_ok=0
    if dexec 'gitlab-ctl status >/dev/null 2>&1'; then
      ctl_ok=1
    fi

    local quiet_enough=0
    local since_growth=$((current_time - last_growth_ts))

    if [ "$seen_activity" -eq 1 ]; then
      if [ "$since_growth" -ge "$quiet_window" ]; then
        quiet_enough=1
      fi
    else
      if [ "$since_growth" -ge "$quiet_window" ]; then
        quiet_enough=1
      fi
    fi

    if [ "$progress_interval" -gt 0 ] && [ $((elapsed - last_report)) -ge "$progress_interval" ]; then
      local log_state="нет данных"
      if [ "$stat_rc" -eq 0 ] && [ -n "$stat_info" ]; then
        log_state="mtime=${current_mtime}, size=${current_size}"
      fi
      log "[wait] Апгрейд всё ещё идёт (ожидание $(format_duration "$elapsed")); gitlab-ctl: $([ "$ctl_ok" -eq 1 ] && echo OK || echo FAIL); reconfigure.log: ${log_state}; тишина ${since_growth}s"
      last_report=$elapsed
    fi

    if [ "$ctl_ok" -eq 1 ] && [ "$quiet_enough" -eq 1 ]; then
      if [ $((current_time - last_ready_attempt)) -lt "$ready_retry_delay" ]; then
        continue
      fi
      last_ready_attempt=$current_time
      if wait_gitlab_ready; then
        ok "Апгрейд завершён: службы в норме и HTTP доступен"
        return 0
      fi
      warn "GitLab ещё не готов после reconfigure — продолжаю ожидание"
    fi

    if [ "$timeout" -gt 0 ] && [ "$elapsed" -ge "$timeout" ]; then
      err "Апгрейд не завершился за $(format_duration "$timeout")"
      report_basic_health "после ожидания завершения апгрейда"
      return 1
    fi

    sleep "$poll_interval"
  done
}
