# lib/dirs.sh
ensure_dirs() {
  mkdir -p "$DATA_ROOT"/{config,data,logs}
  if [ -n "$(ls -A "$DATA_ROOT/config" 2>/dev/null || true)" ] \
  || [ -n "$(ls -A "$DATA_ROOT/data" 2>/dev/null || true)" ] \
  || [ -n "$(ls -A "$DATA_ROOT/logs" 2>/dev/null || true)" ]; then
    if [ "${FORCE_CLEAN:-0}" -eq 1 ] || ask_yes_no "Найдены существующие каталоги в $DATA_ROOT. Пересоздать (удалить содержимое)?" "n"; then
      docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
      rm -rf "$DATA_ROOT" 2>/dev/null || true
      mkdir -p "$DATA_ROOT"/{config,data,logs}
      ok "Каталоги пересозданы"
      state_clear
      FORCE_CLEAN=1

      log "[>] Проверка чистоты окружения…"
      if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
        warn "Контейнер $CONTAINER_NAME всё ещё присутствует"
        docker ps -a --filter "name=$CONTAINER_NAME" || true
      else
        ok "Контейнер $CONTAINER_NAME отсутствует"
      fi

      for d in config data logs; do
        if [ -n "$(ls -A "$DATA_ROOT/$d" 2>/dev/null || true)" ]; then
          warn "$DATA_ROOT/$d не пуст"
          ls -la "$DATA_ROOT/$d" || true
        else
          ok "$DATA_ROOT/$d пуст"
        fi
      done

      if [ -s "$STATE_FILE" ] && grep -qv '^#' "$STATE_FILE"; then
        warn "Файл состояния содержит данные"
        cat "$STATE_FILE" || true
      else
        ok "Файл состояния очищен"
      fi

      log "[>] Свободное место на диске:"
      df -h "$DATA_ROOT" || true
    else
      ok "Сохраняю существующие каталоги."
    fi
  fi
  # config оставляем доступным только root, а data/logs должны быть x-доступны
  # для uid GitLab внутри контейнера (uid=998), иначе PostgreSQL не сможет
  # дойти до /var/opt/gitlab после повторного запуска скрипта.
  chmod 700 "$DATA_ROOT/config"
  chmod 755 "$DATA_ROOT"/{data,logs}
  chown -R root:root "$DATA_ROOT/config"
}
