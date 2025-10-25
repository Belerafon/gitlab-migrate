#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BASEDIR="$REPO_ROOT"

# Минимальные переменные окружения, которые ожидает backup.sh
export DATA_ROOT="${REPO_ROOT}/tmp-test"
export CONTAINER_NAME="test-container"

# shellcheck source=lib/backup.sh
source "$REPO_ROOT/lib/backup.sh"

gitlab_detect_version_for_health_checks() {
  printf '%s\n' '13.1.0'
}

gitlab_service_optional() {
  local service="$1" version="${2-}" reason_var="${3-}"

  if [ "$service" = "grafana" ]; then
    if [ -n "$reason_var" ]; then
      printf -v "$reason_var" '%s' "Grafana необязательна для версии ${version:-unknown}"
    fi
    return 0
  fi

  return 1
}

chef_filter_log_file() {
  local log_file="$1"
  [ -f "$log_file" ] || return 1
  cat "$log_file"
}

main() {
  local grafana_log="$REPO_ROOT/tests/fixtures/reconfigure/grafana_failure.log"
  local other_log="$REPO_ROOT/tests/fixtures/reconfigure/other_service_failure.log"
  local ignore_reason=""

  if ! should_ignore_reconfigure_failure "$grafana_log" ignore_reason; then
    echo "should_ignore_reconfigure_failure не проигнорировала Grafana" >&2
    exit 1
  fi

  if [[ "$ignore_reason" != Grafana* ]]; then
    echo "Ожидался reason про Grafana, получено: ${ignore_reason}" >&2
    exit 1
  fi

  local other_reason="unset"
  if should_ignore_reconfigure_failure "$other_log" other_reason; then
    echo "should_ignore_reconfigure_failure ошибочно проигнорировала другой сервис" >&2
    exit 1
  fi

  echo "OK: should_ignore_reconfigure_failure корректно различает графану и другие сервисы"
}

main "$@"
