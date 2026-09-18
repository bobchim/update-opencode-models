<div align="center">

# 🔄 OpenCode Model Updater

**Keep your OpenCode model list in sync with every provider — without losing your customizations.**

[![Bash](https://img.shields.io/badge/Bash-3.2%2B-4EAA25?logo=gnubash&logoColor=white)](#requirements)
[![jq](https://img.shields.io/badge/jq-required-1F6FEB?logo=jq&logoColor=white)](#requirements)
[![curl](https://img.shields.io/badge/curl-required-073551?logo=curl&logoColor=white)](#requirements)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)](#requirements)
[![Dry Run](https://img.shields.io/badge/safe--by--default-dry--run-brightgreen)](#dry-run---dry-run)

`update_opencode_models.sh` queries each provider's OpenAI-compatible
`/v1/models` endpoint and merges the results into `opencode.json` safely.

</div>

---

> [!IMPORTANT]
> The script is **safe to re-run**. Existing model entries are never overwritten,
> so your `reasoningEffort`, context/output limits, and feature flags survive.
> A timestamped backup is created before every real write.

---

## 📖 Table of Contents

- [✨ Features](#-features)
- [📦 Requirements](#-requirements)
- [🗂️ Files It Reads and Writes](#️-files-it-reads-and-writes)
- [🚀 Installation](#-installation)
- [🧭 Usage](#-usage)
  - [Default Mode](#default-mode)
  - [Direct Mode (`--direct`)](#direct-mode---direct)
  - [Dry Run (`--dry-run`)](#dry-run---dry-run)
  - [Help (`--help`)](#help---help)
- [🛡️ What Is Preserved vs. Updated](#️-what-is-preserved-vs-updated)
- [🧩 Default Model Config](#-default-model-config)
- [🔑 How Providers and API Keys Are Resolved](#-how-providers-and-api-keys-are-resolved)
- [💾 Backups](#-backups)
- [🧪 Examples](#-examples)
- [🛠️ Troubleshooting](#️-troubleshooting)
- [🚦 Exit Codes](#-exit-codes)

---

## ✨ Features

| | |
|---|---|
| 🔁 **Idempotent** | Run it as often as you like — the result is stable. |
| 🛡️ **Non-destructive** | Existing model configs (limits, `reasoningEffort`, flags) are preserved. |
| 🧹 **Self-cleaning** | Models removed on the server are pruned from your config. |
| 🧭 **Two merge modes** | Default prefix-stripping mode, or `--direct` raw mode. |
| 🧪 **Dry run** | Preview every add/keep/remove with zero writes. |
| 💾 **Automatic backups** | Timestamped backup written before each real run. |
| 🧯 **Fault-tolerant** | A bad provider is skipped; the rest still update. |

---

## 📦 Requirements

| Dependency | Why it is needed |
|:----------:|------------------|
| `bash` | Script runtime (macOS system `/bin/bash` 3.2 is supported) |
| `curl` | Fetch models from each provider |
| `jq` | Read and merge the JSON config |

<details>
<summary><strong>Installation commands</strong></summary>

**macOS (Homebrew)**

```bash
brew install jq
```

`curl` and `bash` ship with macOS.

**Debian / Ubuntu**

```bash
sudo apt-get install curl jq
```

**Fedora**

```bash
sudo dnf install curl jq
```

</details>

---

## 🗂️ Files It Reads and Writes

| Path | Purpose | Modified? |
|------|---------|:---------:|
| `~/.config/opencode/opencode.json` | Provider and model configuration | **Yes** (the target) |
| `~/.local/share/opencode/auth.json` | API keys, one per provider | No (read-only) |
| `/tmp/opencode_backup_<timestamp>.json` | Timestamped backup of the config | Created per run |
| `/tmp/opencode_updated_$$.json` | Temp working file | Auto-removed |
| `/tmp/opencode_provider_$$.json` | Temp per-provider file | Auto-removed |
| `/tmp/models_fetch_$$.json` | Temp API response | Auto-removed |

These paths are defined as variables at the top of the script. Edit them there if
your setup differs:

```bash
CONFIG_FILE="$HOME/.config/opencode/opencode.json"
AUTH_FILE="$HOME/.local/share/opencode/auth.json"
```

---

## 🚀 Installation

```bash
# 1. Make it executable
chmod +x update_opencode_models.sh

# 2. (Optional) Put it on your PATH
mkdir -p ~/.local/bin
mv update_opencode_models.sh ~/.local/bin/
```

> [!TIP]
> Once it is on your `PATH`, run it from anywhere with just
> `update_opencode_models.sh`.

---

## 🧭 Usage

```bash
./update_opencode_models.sh [--direct] [--dry-run] [--help]
```

With no options, the script runs in **default mode** and writes changes.

### Default Mode

```bash
./update_opencode_models.sh
```

- Strips the provider prefix from each model id. For example,
  `boiler50/Model` → `Model`.
- Deduplicates model names **within each provider's own list** (not across
  providers).
- Use this when each provider is an independent backend that may return
  prefixed model ids.

### Direct Mode (`--direct`)

```bash
./update_opencode_models.sh --direct
```

- Uses the raw model ids exactly as returned by the server.
- No prefix stripping, no deduplication.
- Use this to reproduce the previous behavior or when your provider returns
  clean, unprefixed ids.

### Dry Run (`--dry-run`)

```bash
./update_opencode_models.sh --dry-run
```

- Computes and prints exactly what would be added, kept, and removed.
- Writes **nothing** to `opencode.json` and creates **no backup**.

Combine with `--direct` as needed:

```bash
./update_opencode_models.sh --direct --dry-run
```

### Help (`--help`)

```bash
./update_opencode_models.sh --help
```

Prints the built-in usage text and exits `0`.

---

## 🛡️ What Is Preserved vs. Updated

The merge is intentionally conservative. Think of it as **"sync the key set, keep
the values."**

### ✅ Preserved (never overwritten)

- **Existing model entries that still exist on the server** are kept byte-for-byte
  as they are in `opencode.json`. This includes any user customization such as:
  - `reasoningEffort`
  - context / output `limit` values
  - `tools`, `skill`, `task`, `lsp`, `codesearch`, `websearch`, `webfetch` flags
  - any other per-model options you added
- **Providers you have configured but that are unreachable** are left untouched
  (they are simply skipped and reported as a warning).
- **All other top-level configuration** (anything outside each provider's
  `models` object) is preserved, since only `provider.<name>.models` is replaced.
- **Other providers** are preserved, because updates are applied one provider at a
  time to a working copy.

> [!NOTE]
> In default mode, a prefixed key such as `boiler50/Model` is migrated to the
> bare name `Model` **while keeping its customizations**.

### ♻️ Updated

- **New models** returned by the server but not yet in your config are added
  using the [default model config](#-default-model-config).
- **Removed models** — entries present in your config but no longer returned by
  the server — are **deleted** from that provider's `models` object.

### At a glance

| Situation | Result |
|-----------|--------|
| Model on server **and** in config | ✅ Keep existing entry unchanged (customizations survive) |
| Model on server, **not** in config | ➕ Add with default model config |
| Model in config, **not** on server | ➖ Remove |
| Provider has no `baseURL` | ⏭️ Skip (warn) |
| Provider has no API key | ⏭️ Skip (warn) |
| Server unreachable / non-200 / empty | ⏭️ Skip (warn) |
| `--dry-run` | 🧪 Report only; no write, no backup |

---

## 🧩 Default Model Config

Newly discovered models are added with this default (defined as `MODEL_CONFIG`):

```json
{
  "tools": true,
  "skill": true,
  "task": true,
  "lsp": true,
  "codesearch": true,
  "websearch": true,
  "webfetch": true,
  "limit": {
    "context": 262144,
    "output": 128000
  }
}
```

> [!TIP]
> Customize it by editing the `MODEL_CONFIG` variable near the top of the script.

---

## 🔑 How Providers and API Keys Are Resolved

- **Providers** are read from the `provider` keys in `opencode.json`
  (`.provider | keys[]`). The `auth.json` file is *not* used to discover
  providers.
- **`baseURL`** is read from `.provider.<name>.options.baseURL`. The host and
  port are extracted, and `/v1/models` is appended. Both `http://` and `https://`
  prefixes are accepted, and a trailing `/v1` is ignored.
- **API keys** are read from `auth.json` as `.<provider>.key`, with a fallback
  direct lookup. The request uses `Authorization: Bearer <key>`.
- Each model fetch has a **10-second timeout** (`curl --max-time 10`).

> [!NOTE]
> The script only ever requests `http://<host:port>/v1/models`. It sends no
> telemetry and never modifies `auth.json`.

---

## 💾 Backups

Before writing, the script copies your config to:

```text
/tmp/opencode_backup_YYYYMMDD_HHMMSS.json
```

The backup path is printed at the end of the run.

<details>
<summary><strong>How to restore a backup</strong></summary>

```bash
cp /tmp/opencode_backup_<timestamp>.json ~/.config/opencode/opencode.json
```

In `--dry-run` mode no backup is created because nothing is written.

</details>

---

## 🧪 Examples

**Preview changes across all providers without touching anything:**

```bash
./update_opencode_models.sh --dry-run
```

**Apply changes using the default prefix-stripping behavior:**

```bash
./update_opencode_models.sh
```

**Use raw ids with no stripping or deduplication, and preview first:**

```bash
./update_opencode_models.sh --direct --dry-run
./update_opencode_models.sh --direct
```

<details>
<summary><strong>Typical output</strong></summary>

```text
==========================================
OpenCode Model Updater
Mode: default (strip prefix, per-provider dedup)
==========================================
[INFO] Reading providers from config...
[INFO] Found 2 provider(s) in config: boiler50, local
[INFO] Backup created: /tmp/opencode_backup_20260918_101500.json
[OK] Updated boiler50 (192.0.2.10:8888): 12 models (10 kept as-is) (+ added: NewModel) (- removed: OldModel)
[WARN] No API key for local - skipped

==========================================
Update Complete!
==========================================
Backup saved to: /tmp/opencode_backup_20260918_101500.json
```

</details>

---

## 🛠️ Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `[ERROR] Missing required dependencies (curl, jq)` | Install `curl` and/or `jq` (e.g. `brew install jq`). |
| `[ERROR] Config file not found: ...` | The config path does not exist. Verify `CONFIG_FILE` and that OpenCode has been run at least once. |
| `[ERROR] No providers found in config file` | Your `opencode.json` has no `provider` section. Add a provider before running. |
| `[WARN] No baseURL for <provider> - skipped` | The provider lacks `.provider.<name>.options.baseURL`. |
| `[WARN] No API key for <provider> - skipped` | No `.<provider>.key` found in `auth.json`. Re-authenticate with OpenCode. |
| `[WARN] Failed to fetch models from <provider> ...` | Server unreachable, returned non-200, or the response was empty. Check the host/port and key. |
| Models disappear unexpectedly | They were not returned by the server during this run. Restore from the printed backup if needed. |
| Customizations were lost | This should not happen for models still present on the server. Restore from the backup and open an issue. |

> [!WARNING]
> Always review `--dry-run` output before running destructively in a production
> configuration, and keep the printed backup path.

---

## 🚦 Exit Codes

| Code | Meaning |
|:----:|---------|
| `0` | Success (including `--help` and `--dry-run`) |
| `1` | Missing dependencies, missing config file, or no providers found |
| `2` | Unknown command-line option |

---

<div align="center">

Made for the [OpenCode](https://opencode.ai) community

</div>
