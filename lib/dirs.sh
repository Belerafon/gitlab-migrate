# lib/dirs.sh
ensure_dirs() {
  mkdir -p "$DATA_ROOT"/{config,data,logs}
  if [ -n "$(ls -A "$DATA_ROOT/config" 2>/dev/null || true)" ] \
  || [ -n "$(ls -A "$DATA_ROOT/data" 2>/dev/null || true)" ] \
  || [ -n "$(ls -A "$DATA_ROOT/logs" 2>/dev/null || true)" ]; then
    if ask_yes_no "Найдены существующие каталоги в $DATA_ROOT. Пересоздать (удалить содержимое)?" "n"; then
      docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
      rm -rf "$DATA_ROOT" 2>/dev/null || true
      mkdir -p "$DATA_ROOT"/{config,data,logs}
      ok "Каталоги пересозданы"
      state_clear
    else
      ok "Сохраняю существующие каталоги."
    fi
  fi
  chmod 700 "$DATA_ROOT/config"
  chmod 750 "$DATA_ROOT"/{data,logs}
  chown -R root:root "$DATA_ROOT/config"
}
