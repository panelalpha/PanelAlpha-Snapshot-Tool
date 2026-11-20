<div align="center">

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset=".github/assets/panelalpha.svg"><img src=".github/assets/panelalpha-light.svg" alt="PanelAlpha Snapshot Tool" width="360"></picture></p>

<h1>Snapshots of a whole<br>PanelAlpha server.</h1>

<h3>
One script that saves the panel's databases, files and settings to an encrypted store, and puts them back on the same or a new server.
</h3>

<h3>
<a href="#get-it-running"><b>Get started</b></a> ·
<a href="https://www.panelalpha.com/documentation/multi-server-edition/system-configuration/snapshot-tool"><b>Documentation</b></a> ·
<a href="#talk-to-us-on-discord"><b>Discord</b></a>
</h3>

<p>
<a href="#what-a-snapshot-contains">What is saved</a> ·
<a href="#restoring">Restoring</a> ·
<a href="#moving-to-a-new-server">New server</a> ·
<a href="#faq">FAQ</a>
</p>

<p>
<a href="https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/releases"><img src="https://img.shields.io/github/v/release/panelalpha/PanelAlpha-Snapshot-Tool?color=E65E12" alt="Latest release"></a>
<a href="#what-it-works-with"><img src="https://img.shields.io/badge/Debian_%2F_Ubuntu-a80030" alt="Debian or Ubuntu"></a>
<a href="#licence"><img src="https://img.shields.io/badge/license-Apache_2.0-0b7285" alt="Apache 2.0"></a>
<a href="https://discord.gg/9twHWR7xGX"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white" alt="Join Discord"></a>
</p>

</div>

---

## What is the Snapshot Tool?

The PanelAlpha Snapshot Tool is a script, `pasnap.sh`, that you run as `root` on a PanelAlpha server. It saves everything the server needs to come back after a failure: databases, Docker volumes, configuration files and certificates. Each saved copy is a **snapshot**.

Snapshots go to a **repository**, the place they are stored: a folder on the server, another server over SFTP, or an S3 bucket. The tool uses [Restic](https://restic.net), so every snapshot is encrypted with your password before it leaves the server.

This is for recovering the whole server. The backups you set up in the Admin Area or the Client Area cover single sites, and the two do not replace each other.

## What it works with

The tool looks at `/opt/panelalpha` and decides which kind of server it is on:

| Installation | What the tool finds |
|:---|:---|
| **Multi Server** | `/opt/panelalpha/app` |
| **Single Server** | `/opt/panelalpha/app-lite` and `/opt/panelalpha/shared-hosting` |
| **Engine** | `/opt/panelalpha/shared-hosting` |

When it finds none of them, it stops with an error and changes nothing.

Multi Server works from 0.9.1 to 1.9.8.6. The layout of the panel has stayed the same across these versions. Panels older than 1.8.5 also run Matomo, and the tool saves its database too.

You need Debian or Ubuntu (the installer uses `apt`), Docker with the `docker compose` plugin, `root` access and at least 3 GB free in `/var/tmp`. An Engine server with a large `/home` needs room for a full copy of it.

## Get it running

### Step 1: Download the script

```bash
wget -O /opt/panelalpha/pasnap.sh https://raw.githubusercontent.com/panelalpha/PanelAlpha-Snapshot-Tool/main/pasnap.sh
chmod +x /opt/panelalpha/pasnap.sh
```

### Step 2: Install what it needs

```bash
sudo /opt/panelalpha/pasnap.sh --install
```

This installs `restic`, `jq` and `rsync` with `apt` and checks that Docker runs.

### Step 3: Set up the repository

```bash
sudo /opt/panelalpha/pasnap.sh --setup
```

The setup asks where to store snapshots (`local`, `sftp` or `s3`), the encryption password, how many days to keep snapshots (30 by default) and the hour of the daily snapshot (2 by default). It then connects to the repository and checks that it can log in to the panel's databases.

**Without the encryption password, no snapshot can be restored.** Keep it outside the server, in a password manager or on paper.

### Step 4: Take the first snapshot

```bash
sudo /opt/panelalpha/pasnap.sh --snapshot
```

At the end the tool prints `SUCCESS` and the snapshot ID, for example `a1b2c3d4`.

### Step 5: Take one every day

```bash
sudo /opt/panelalpha/pasnap.sh --cron install
```

This adds a line to the `root` crontab that runs `--snapshot` once a day at the hour from step 3.

On a new server, `--quickstart` does steps 2 to 4 in one go.

## What a snapshot contains

**Multi Server**

- The panel database (`panelalpha` in `database-api`)
- The `api-storage`, `database-api-data` and `redis-data` volumes
- `.env`, `.env-api`, `docker-compose.yml` and the `version` file
- `packages/`, the panel code, with `vendor/`
- Certificates: `crt/`, `/etc/letsencrypt` and any other file that `SSL_CERT_FULLCHAIN` or `SSL_CERT_PRIVKEY` in `.env` points to
- Before 1.8.5: the Matomo database and the `matomo` volume
- The `root` crontab

**Engine**

- The `core` database and every database in `database-users`
- The `core-storage`, `database-core-data` and `database-users-data` volumes
- `.env`, `.env-core` and `docker-compose.yml`
- `/opt/panelalpha/shared-hosting/users` and all of `/home`, copied in full
- The `root` crontab

**Single Server**

- Everything from the Engine list
- The panel database, which lives in `database-core`
- `.env`, `docker-compose.yml` and `data/api-storage` of the panel

A snapshot does not contain the tool's own settings in `/opt/panelalpha/pasnap/.env-backup` or log files.

The tool takes a snapshot while the panel runs. It does not stop any service.

## Restoring

```bash
sudo /opt/panelalpha/pasnap.sh --list-snapshots
sudo /opt/panelalpha/pasnap.sh --restore a1b2c3d4
```

`--restore latest` picks the newest snapshot of this server.

**A restore replaces the panel's current data.** Anything created after the snapshot was taken is gone. The tool asks `Continue with restore? (yes/no)` and does nothing until you type `yes`.

During a restore the tool:

1. Stops the panel's containers.
2. Removes the database volumes and imports the databases from the snapshot.
3. Puts back the volumes, configuration files, `packages/` and certificates.
4. Starts the panel again.
5. Adds the jobs from the old `root` crontab that run PanelAlpha scripts (for example `letsencrypt-renew.sh`) and are missing here. Other jobs from the old server are left out.

On Multi Server the panel starts with an empty Redis. Jobs that were waiting in the queue when the snapshot was taken have already run since then, so they are not run again.

It asks once more before it goes on when:

- The snapshot comes from another kind of installation, for example an Engine snapshot on a Multi Server.
- The snapshot comes from another panel version than the one installed.

On Multi Server the tool then writes this server's IP address to the `host_ip_address` setting. If `SANCTUM_STATEFUL_DOMAINS` in `.env-api` lists hosts, it adds this server's hostname and IP address to the list. When that setting is empty, the default, the tool leaves it empty.

If a certificate file named in `.env` is still missing after the restore, the tool says which one. nginx does not start until that file is in place.

## Moving to a new server

1. On the old server, take a fresh snapshot and note its ID.
2. On the new server, install PanelAlpha of the same kind **and the same version** as the old one.
3. Install the Snapshot Tool and run `--setup` with the same repository and the same encryption password.
4. Check that the new server sees the snapshot: `--list-snapshots`.
5. Restore it: `--restore <id>`.
6. Point your domains at the new server.
7. Add the daily snapshot again with `--cron install`. The restore does not copy it, because the script may sit in another place on the new server.

Full guide: [Migration](docs/migration.md).

## Commands

| Command | What it does |
|:---|:---|
| `--install` | Installs `restic`, `jq` and `rsync` |
| `--setup` | Asks for the repository and password, saves them |
| `--quickstart` | `--install`, `--setup` and `--snapshot` in one go |
| `--snapshot` | Takes a snapshot |
| `--snapshot-bg` | Takes a snapshot in the background, so you can close the terminal |
| `--list-snapshots` | Lists the snapshots in the repository |
| `--restore <id>` | Restores a snapshot, or the newest one with `latest` |
| `--delete-snapshots <id>` | Deletes one snapshot |
| `--test-connection` | Checks that the repository answers |
| `--verify-database` | Checks that the tool can log in to the panel's databases |
| `--cron install` | Adds the daily snapshot to the `root` crontab |
| `--cron status` | Shows the daily snapshot and the last lines of the log |
| `--cron remove` | Removes the daily snapshot |
| `--update` | Updates the script to the newest version |
| `--version` | Shows the version and the installation it found |

| File | What is in it |
|:---|:---|
| `/opt/panelalpha/pasnap/.env-backup` | Repository, password and settings (mode `600`) |
| `/var/log/pasnap.log` | The log of every run |

## Updates

Once a day the script checks GitHub for a newer version. From cron it updates itself. In a terminal it asks first. Set `PASNAP_DISABLE_AUTO_UPDATE=1` to stop updates from cron, or `PASNAP_SKIP_UPDATE_CHECK=1` to stop the check.

## When something does not work

Every run writes to `/var/log/pasnap.log`. When a database dump or import fails, the log has the last lines of the error from MariaDB.

**"Cannot connect to database-api"**. The password in `.env` does not match the database. Run `--verify-database` to see which password works.

**"Insufficient disk space"**. The tool needs 3 GB free in `/var/tmp`. Free up space, or set `BACKUP_TEMP_DIR` in `/opt/panelalpha/pasnap/.env-backup` to a bigger disk.

**Admin two-factor codes fail after a restore.** `APP_KEY` in `.env-api` is not the one from the snapshot. The restore puts it back, so do not change it by hand afterwards.

More cases: [Troubleshooting](docs/troubleshooting.md).

## FAQ

<details>
<summary><b>I lost the encryption password. Can I still restore?</b></summary>

No. Restic encrypts every snapshot with that password and nobody, PanelAlpha included, can open it without it.
</details>

<details>
<summary><b>Does a snapshot stop the panel?</b></summary>

No. The databases are dumped in one transaction while the panel runs. Only a restore stops the containers.
</details>

<details>
<summary><b>Can I restore a snapshot from an older panel version?</b></summary>

Install that older version first, restore, then update the panel as usual. The tool warns when the versions differ, because the restored database would not match the installed code.
</details>

<details>
<summary><b>How long are snapshots kept?</b></summary>

After each snapshot the tool keeps one snapshot per day for the number of days set in `BACKUP_RETENTION_DAYS` (30 by default) and deletes the rest of this server's snapshots.
</details>

<details>
<summary><b>Does it replace site backups?</b></summary>

No. A snapshot brings back the whole server at one point in time. To restore one site, use the backups in the Admin Area or the Client Area.
</details>

## Working on the script

`pasnap.sh` is built from the files in `src/`. Users download that one file, and installed copies update themselves from it, so it stays a single file in the repository.

1. Change the files in `src/`.
2. Run `./build.sh` to write `pasnap.sh`.
3. Commit both.

CI runs `./build.sh --check` and fails when `pasnap.sh` does not match `src/`. More: [Contributing](CONTRIBUTING.md).

## Talk to us on Discord

[Discord](https://discord.gg/9twHWR7xGX) is the main place to reach the PanelAlpha team. Ask a question or tell us what does not work.

<br><div align="center">
<a href="https://discord.gg/9twHWR7xGX">
<img src=".github/assets/discord-banner.png" alt="Talk to us on Discord, the main place to reach the PanelAlpha team" width="760">
</a>
</div><br>

If you prefer a forum, use [community.panelalpha.com](https://community.panelalpha.com/). Bugs in the script go to [GitHub Issues](https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/issues).

## Security

Report a vulnerability privately, never in a public issue: [manage.panelalpha.com/contact](https://manage.panelalpha.com/contact).

## Licence

The PanelAlpha Snapshot Tool is open source under the [Apache License 2.0](LICENSE).
