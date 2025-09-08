# GitLab CE Migration Toolkit (modular)
    
Модульный набор скриптов для восстановления GitLab CE 13.1.4 из бэкапа и пошагового апгрейда до 16.11.x (и опционально 17.x) в Docker.

## Структура
```
gitlab-migrate/
  bin/gitlab-migrate.sh          # Точка входа
  conf/settings.env              # Конфигурация
  lib/log.sh                     # Логирование
  lib/state.sh                   # Состояние/диалог
  lib/docker.sh                  # Docker-помощники и ожидания
  lib/dirs.sh                    # Работа с каталогами /srv/gitlab
  lib/backup.sh                  # Импорт, проверка и восстановление бэкапа
  lib/upgrade.sh                 # «Лестница» версий
```
    
## Быстрый старт
```bash
# 1) Распаковать архив в /root (или любую директорию)
tar -xzf gitlab-migrate-modular.tar.gz -C /root

# 2) Проверить/поправить конфиг (путь BACKUPS_SRC и порты)
nano /root/gitlab-migrate/conf/settings.env

# 3) Запуск
bash /root/gitlab-migrate/bin/gitlab-migrate.sh

# 4) При наличии старых данных ответьте `y` на вопрос очистки — это эквивалент `--clean`
#    или запустите сразу в неинтерактивном режиме:
bash /root/gitlab-migrate/bin/gitlab-migrate.sh --clean
```

## Переезд до 17.x
В конфиге `conf/settings.env` поставьте `DO_TARGET_17="yes"` и повторно запустите точку входа.
