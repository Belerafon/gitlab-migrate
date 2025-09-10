# lib/sanitize.sh
# shellcheck shell=sh
sanitize_log() {
  awk '
    BEGIN { IGNORECASE=1 }
    /BEGIN RSA PRIVATE KEY/ {
      print "[REDACTED RSA PRIVATE KEY]"
      skip=1
      next
    }
    /END RSA PRIVATE KEY/ {
      skip=0
      next
    }
    skip { next }
    /(^|[^A-Za-z0-9])(password|token|secret|key)([^A-Za-z0-9]|$)/ {
      print "[REDACTED SENSITIVE DATA]"
      next
    }
    { print }
  '
}
