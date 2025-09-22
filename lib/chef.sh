# lib/chef.sh
# shellcheck shell=bash

# AWK-программа для фильтрации потока Chef, уменьшает шум и оставляет только ключевые события.
# Мы используем только двойные кавычки внутри, чтобы не усложнять экранирование.
CHEF_FILTER_AWK=$'BEGIN {\n'\
'  current_recipe="";\n'\
'  printed_stage["Running reconfigure"]=0;\n'\
'  printed_stage["Waiting for Database"]=0;\n'\
'  printed_stage["Database upgrade is complete"]=0;\n'\
'  printed_stage["Toggling deploy page"]=0;\n'\
'  printed_stage["Toggling services"]=0;\n'\
'  printed_stage["==== Upgrade has completed ===="]=0;\n'\
'  printed_stage["Please verify everything is working"]=0;\n'\
'}\n'\
'{\n'\
'  line=$0;\n'\
'  gsub(/\r/, "", line);\n'\
'  trimmed=line;\n'\
'  gsub(/^[[:space:]]+/, "", trimmed);\n'\
'  lower=trimmed;\n'\
'  lower=tolower(lower);\n'\
'\n'\
'  if (trimmed ~ /^Starting Chef Infra Client/) {\n'\
'    print "[chef] " trimmed;\n'\
'    next;\n'\
'  }\n'\
'  if (trimmed ~ /^Running handlers/ || trimmed ~ /^Chef Infra Client (finished|failed)/) {\n'\
'    print "[chef] " trimmed;\n'\
'    next;\n'\
'  }\n'\
'\n'\
'  if (trimmed ~ /^Recipe: /) {\n'\
'    recipe=substr(trimmed, 9);\n'\
'    if (recipe != current_recipe) {\n'\
'      current_recipe=recipe;\n'\
'      print "[chef] Recipe → " recipe;\n'\
'    }\n'\
'    next;\n'\
'  }\n'\
'\n'\
'  for (stage in printed_stage) {\n'\
'    if (stage != "" && index(trimmed, stage) == 1) {\n'\
'      if (printed_stage[stage] == 0) {\n'\
'        print "[chef] " stage;\n'\
'        printed_stage[stage]=1;\n'\
'      }\n'\
'      next;\n'\
'    }\n'\
'  }\n'\
'\n'\
'  if (index(lower, "error") || index(lower, "fatal") || index(lower, "critical")) {\n'\
'    print "[chef][ERR] " trimmed;\n'\
'    next;\n'\
'  }\n'\
'  if (index(lower, "warn")) {\n'\
'    print "[chef][WARN] " trimmed;\n'\
'    next;\n'\
'  }\n'\
'\n'\
'  if (trimmed ~ /^\*/) {\n'\
'    if (trimmed ~ /\(up to date\)/ || trimmed ~ /\(skipped due to/) {\n'\
'      next;\n'\
'    }\n'\
'    sub(/^\* +/, "", trimmed);\n'\
'    print "[chef]   • " trimmed;\n'\
'    next;\n'\
'  }\n'\
'\n'\
'  if (trimmed ~ /^-/) {\n'\
'    if (trimmed ~ /\(up to date\)/ || trimmed ~ /\(skipped due to/) {\n'\
'      next;\n'\
'    }\n'\
'    print "[chef]     " trimmed;\n'\
'    next;\n'\
'  }\n'\
'}\n'

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
