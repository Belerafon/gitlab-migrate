# lib/upgrade.sh
compute_stops() { echo "13.12"; echo "14.10"; echo "15.11"; echo "16.11"; [ "$DO_TARGET_17" = "yes" ] && echo "17"; }

upgrade_to_series() {
  local series="$1" target
  if [[ "$series" =~ ^[0-9]+\.[0-9]+$ ]] || [[ "$series" =~ ^[0-9]+$ ]]; then
    target="$(latest_patch_tag "$series")"
  else
    target="$series"
  fi
  log "[==>] Апгрейд до gitlab/gitlab-ce:${target}"
  docker pull "gitlab/gitlab-ce:${target}" >/dev/null 2>&1 || warn "pull не обязателен, продолжу"
  run_container "$target"
  wait_gitlab_ready
  wait_postgres_ready

  log "[>] Проверка миграций схемы:"
  dexec 'gitlab-rake db:migrate:status | tail -n +1' || true

  log "[>] Статус фоновых миграций (если задача есть):"
  dexec 'gitlab-rake gitlab:background_migrations:status' >/dev/null 2>&1 && \
  dexec 'gitlab-rake gitlab:background_migrations:status' || echo "(task not available)" >&2

  log "[>] Пауза ${WAIT_BETWEEN_STEPS}s"; sleep "$WAIT_BETWEEN_STEPS"
  set_state LAST_UPGRADED_TO "$target"
}
