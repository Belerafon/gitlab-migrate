# GitLab CE Migration Toolkit (modular)

A modular collection of Bash helpers for restoring a GitLab CE 13.1.4 backup and walking it through the officially supported upgrade ladder until GitLab 18.x (or any target version that you configure) inside Docker.

## Highlights
- **Deterministic upgrade ladder** – automatically walks the mandatory GitLab upgrade path (13.0.x → … → 18.4.x) and respects optional "stop" releases required by upstream documentation.
- **PostgreSQL guard rails** – inspects running binaries and data directories before each major PostgreSQL jump, selects the proper `--old-bindir` / `--new-bindir` combination for `pg-upgrade`, and prints the full reasoning to the terminal.
- **Stateful reruns** – stores progress in `STATE_FILE`, allowing you to resume after interruptions and to reuse locally cached Docker images.
- **Snapshot-aware** – captures a `gitlab-snapshot` copy of `/srv/gitlab` after the initial restore and can restart from it without unpacking the original backup again.
- **Verbose logging** – mirrors all stdout/stderr into timestamped files under `logs/` for post-mortem debugging.

## Repository layout
```
gitlab-migrate/
  bin/gitlab-migrate.sh          # entry point
  conf/settings.env              # migration configuration
  lib/                           # modular helpers (logging, docker, backup, upgrades, ...)
  logs/                          # created on demand, stores run logs
```

## Prerequisites
- A host capable of running Docker Engine (root access is required by the scripts).
- Extracted GitLab backup artifacts that match the expected naming convention (see [Backup requirements](#backup-requirements)).
- Enough free disk space for multiple `/srv/gitlab` copies (restore, snapshot, intermediate upgrades).

## Configuration
All runtime configuration lives in [`conf/settings.env`](conf/settings.env):
- **Container & networking:** `CONTAINER_NAME`, `HOST_IP`, and port mappings (`PORT_HTTP`, `PORT_HTTPS`, `PORT_SSH`).
- **Data directories:** `DATA_ROOT` for `/srv/gitlab` on the host and `BACKUPS_SRC` pointing to the extracted backup files.
- **Target version:** `TARGET_VERSION` controls how far the ladder proceeds (see [Target version control](#target-version-control)).
- **Optional stops:** `INCLUDE_OPTIONAL_STOPS` (`yes` / `no` / `list`) and `OPTIONAL_STOP_LIST` fine-tune intermediate releases.
- **State & timing:** `STATE_FILE`, readiness timeouts, and wait intervals for GitLab, PostgreSQL, and background migrations.

Edit the file before the first run and adjust paths and ports to match your environment.

## Migration flow
1. Validate prerequisites (`docker`, root privileges) and load persisted state.
2. Ensure working directories exist, restore from a local snapshot if present, otherwise import the backup and GitLab configuration.
3. Pull or reuse the base Docker image for the source GitLab version and start the container.
4. Wait for GitLab and PostgreSQL readiness, then restore the backup into the container.
5. Create an on-host snapshot of `/srv/gitlab` for future reruns.
6. Build the upgrade ladder, honouring optional stops, and upgrade sequentially, pausing when required to let background migrations finish.

The script is safe to re-run: it will resume from the last confirmed checkpoint and skip already completed steps.

## Quick start
```bash
# 1) Extract the toolkit archive (example path)
tar -xzf gitlab-migrate-modular.tar.gz -C /root

# 2) Review configuration before the first launch
nano /root/gitlab-migrate/conf/settings.env

# 3) Start the migration interactively
bash /root/gitlab-migrate/bin/gitlab-migrate.sh

# 4) To wipe existing /srv/gitlab data without confirmation, add --clean
bash /root/gitlab-migrate/bin/gitlab-migrate.sh --clean

# 5) After the first restore the script creates /srv/gitlab-snapshot.
#    Subsequent runs can reuse it instead of re-extracting the original backup.
```

## Backup requirements
`BACKUPS_SRC` must contain:
- The GitLab configuration archive `gitlab_config.tar` with `gitlab.rb` and `gitlab-secrets.json`.
- The GitLab backup archive named `*_gitlab_backup.tar*` (optionally compressed with `.gz`).

## Target version control
`TARGET_VERSION` accepts three forms:
- `latest` (default) — run through the entire ladder to the newest release registered in `lib/upgrade.sh`.
- A major/minor series (e.g., `17.11` or `18.2`) — stop at the latest patch within that series.
- A full semantic version (e.g., `18.4.1` or `16.11.10`).

After adjusting `TARGET_VERSION`, rerun `bin/gitlab-migrate.sh`. The ladder is automatically trimmed to the specified ceiling.

## Logs and state artifacts
- Run logs: `logs/gitlab-migrate-<timestamp>.log`.
- Snapshot: `/srv/gitlab-snapshot` on the host.
- Persistent state: `STATE_FILE` (defaults to `/root/gitlab_upgrade_state.env`).

These artifacts are safe to remove if you need to force a clean restart.

## Troubleshooting tips
- Use `--reset` to discard the stored state and rebuild the ladder from scratch.
- Check Docker logs with `docker logs <container>` if GitLab fails to start.
- Inspect `logs/gitlab-migrate-*.log` for detailed PostgreSQL upgrade checks.

## License
This repository currently does not ship with an explicit license. Provide one before distributing the toolkit further.
