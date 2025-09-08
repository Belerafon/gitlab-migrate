# lib/log.sh
log()  { echo -e "$*" >&2; }
ok()   { echo -e "[✔] $*" >&2; }
warn() { echo -e "[! ] $*" >&2; }
err()  { echo -e "[✘] $*" >&2; }
