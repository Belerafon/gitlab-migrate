# lib/chef.sh
# shellcheck shell=bash

# AWK-программа для фильтрации потока Chef, уменьшает шум и оставляет только ключевые события.
# Используем heredoc, чтобы избежать ручного экранирования и появления лишних символов.
CHEF_FILTER_AWK=$(cat <<'AWK'
function flush_warn() {
  if (last_warn_line != "") {
    if (warn_repeat > 1) {
      print "[chef][WARN] " last_warn_line " (×" warn_repeat ")";
    } else {
      print "[chef][WARN] " last_warn_line;
    }
    last_warn_line="";
    warn_repeat=0;
  }
}

function flush_err() {
  if (last_err_line != "") {
    if (err_repeat > 1) {
      print "[chef][ERR] " last_err_line " (×" err_repeat ")";
    } else {
      print "[chef][ERR] " last_err_line;
    }
    last_err_line="";
    err_repeat=0;
  }
}

function reset_resource() {
  current_resource="";
  current_force=0;
  current_has_change=0;
  current_printed=0;
  delete change_lines;
  change_idx=0;
}

function flush_resource(force) {
  if (current_resource == "") {
    return;
  }

  if (force || current_has_change || current_force) {
    if (!current_printed) {
      print "[chef]   • " current_resource;
      current_printed=1;
    }

    if (change_idx > 0) {
      for (i = 0; i < change_idx; i++) {
        if (length(change_lines[i])) {
          print "[chef]       - " change_lines[i];
        }
      }
    }
  }

  reset_resource();
}

BEGIN {
  current_recipe="";
  printed_stage["Running reconfigure"]=0;
  printed_stage["Waiting for Database"]=0;
  printed_stage["Database upgrade is complete"]=0;
  printed_stage["Toggling deploy page"]=0;
  printed_stage["Toggling services"]=0;
  printed_stage["==== Upgrade has completed ===="]=0;
  printed_stage["Please verify everything is working"]=0;

  reset_resource();
}
{
  line=$0;
  gsub(/\r/, "", line);
  trimmed=line;
  gsub(/^[[:space:]]+/, "", trimmed);
  lower=trimmed;
  lower=tolower(lower);

  if (trimmed ~ /^Starting Chef Infra Client/) {
    flush_resource(0);
    flush_warn();
    flush_err();
    print "[chef] " trimmed;
    next;
  }
  if (trimmed ~ /^Running handlers/ || trimmed ~ /^Chef Infra Client (finished|failed)/) {
    flush_resource(0);
    flush_warn();
    flush_err();
    print "[chef] " trimmed;
    next;
  }

  if (trimmed == "") {
    flush_resource(0);
    flush_warn();
    flush_err();
    next;
  }

  if (trimmed ~ /^Recipe: /) {
    flush_resource(0);
    flush_warn();
    flush_err();
    recipe=substr(trimmed, 9);
    if (recipe != current_recipe) {
      current_recipe=recipe;
      print "[chef] Recipe → " recipe;
    }
    next;
  }

  for (stage in printed_stage) {
    if (stage != "" && index(trimmed, stage) == 1) {
      flush_resource(0);
      flush_warn();
      flush_err();
      if (printed_stage[stage] == 0) {
        print "[chef] " stage;
        printed_stage[stage]=1;
      }
      next;
    }
  }

  if (index(lower, "error") || index(lower, "fatal") || index(lower, "critical")) {
    flush_resource(1);
    if (trimmed == last_err_line) {
      err_repeat++;
    } else {
      flush_err();
      last_err_line=trimmed;
      err_repeat=1;
    }
    next;
  }
  if (index(lower, "warn")) {
    flush_resource(1);
    if (trimmed == last_warn_line) {
      warn_repeat++;
    } else {
      flush_warn();
      last_warn_line=trimmed;
      warn_repeat=1;
    }
    next;
  }

  if (trimmed ~ /^\*/) {
    flush_resource(0);
    flush_warn();
    flush_err();
    if (trimmed ~ /\(up to date\)/ || trimmed ~ /\(skipped due to/ || trimmed ~ /action nothing/) {
      next;
    }
    sub(/^\* +/, "", trimmed);
    current_resource=trimmed;
    current_force=0;
    current_has_change=0;
    current_printed=0;

    if (current_resource ~ / action (run|start|stop|restart|migrate)/) {
      current_force=1;
    }
    next;
  }

  if (trimmed ~ /^-/) {
    flush_warn();
    flush_err();
    if (trimmed ~ /\(up to date\)/ || trimmed ~ /\(skipped due to/) {
      next;
    }

    if (current_resource == "") {
      print "[chef]     " trimmed;
      next;
    }

    detail=trimmed;
    sub(/^-[[:space:]]*/, "", detail);
    change_lines[change_idx++] = detail;
    current_has_change=1;
    next;
  }

  if (current_resource != "") {
    if (trimmed ~ /^[\[]/ || trimmed ~ /^[A-Za-z0-9_]+:/) {
      flush_warn();
      flush_err();
      change_lines[change_idx++] = trimmed;
      current_has_change=1;
      next;
    }
  }
}
END {
  flush_resource(0);
  flush_warn();
  flush_err();
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
