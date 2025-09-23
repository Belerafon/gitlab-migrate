# lib/chef.sh
# shellcheck shell=bash

# AWK-программа для фильтрации потока Chef, уменьшает шум и оставляет только ключевые события.
# Используем heredoc, чтобы избежать ручного экранирования и появления лишних символов.
CHEF_FILTER_AWK=$(cat <<'AWK'
BEGIN {
  current_recipe="";
  printed_stage["Running reconfigure"]=0;
  printed_stage["Waiting for Database"]=0;
  printed_stage["Database upgrade is complete"]=0;
  printed_stage["Toggling deploy page"]=0;
  printed_stage["Toggling services"]=0;
  printed_stage["==== Upgrade has completed ===="]=0;
  printed_stage["Please verify everything is working"]=0;
}
{
  line=$0;
  gsub(/\r/, "", line);
  trimmed=line;
  gsub(/^[[:space:]]+/, "", trimmed);
  lower=trimmed;
  lower=tolower(lower);

  if (trimmed ~ /^Starting Chef Infra Client/) {
    print "[chef] " trimmed;
    next;
  }
  if (trimmed ~ /^Running handlers/ || trimmed ~ /^Chef Infra Client (finished|failed)/) {
    print "[chef] " trimmed;
    next;
  }

  if (trimmed ~ /^Recipe: /) {
    recipe=substr(trimmed, 9);
    if (recipe != current_recipe) {
      current_recipe=recipe;
      print "[chef] Recipe → " recipe;
    }
    next;
  }

  for (stage in printed_stage) {
    if (stage != "" && index(trimmed, stage) == 1) {
      if (printed_stage[stage] == 0) {
        print "[chef] " stage;
        printed_stage[stage]=1;
      }
      next;
    }
  }

  if (index(lower, "error") || index(lower, "fatal") || index(lower, "critical")) {
    print "[chef][ERR] " trimmed;
    next;
  }
  if (index(lower, "warn")) {
    print "[chef][WARN] " trimmed;
    next;
  }

  if (trimmed ~ /^\*/) {
    if (trimmed ~ /\(up to date\)/ || trimmed ~ /\(skipped due to/) {
      next;
    }
    sub(/^\* +/, "", trimmed);
    print "[chef]   • " trimmed;
    next;
  }

  if (trimmed ~ /^-/) {
    if (trimmed ~ /\(up to date\)/ || trimmed ~ /\(skipped due to/) {
      next;
    }
    print "[chef]     " trimmed;
    next;
  }
}
AWK
)

# Фильтр реального времени для потока Chef.
chef_filter_stream() {
  awk "$CHEF_FILTER_AWK"
}

# Применяет тот же фильтр к файлу лога Chef.
chef_filter_log_file() {
  local log_file="$1"
  [ -f "$log_file" ] || return 1
  awk "$CHEF_FILTER_AWK" "$log_file"
}
