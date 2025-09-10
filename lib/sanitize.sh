# lib/sanitize.sh
# shellcheck shell=sh
sanitize_log() {
  awk '
    /GITLAB_ROOT_PASSWORD/ {
      gsub(/GITLAB_ROOT_PASSWORD"=>"[^"]+/, "GITLAB_ROOT_PASSWORD\"=>\"[REDACTED]")
    }
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
    { print }
  '
}
