# OpenCode Model Updater

`update_opencode_models.sh` refreshes the model list in `opencode.json` by
querying each provider's OpenAI-compatible `/v1/models` endpoint. Existing model
entries are never overwritten, so your customizations survive re-runs. A backup
is created before every write.

## Requirements

- `bash`
- `curl`
- `jq`

## Usage

```bash
./update_opencode_models.sh [--direct] [--dry-run] [--help]
```

| Option | Description |
|--------|-------------|
| (none) | Strip the provider prefix from model ids (`boiler50/Model` → `Model`) and deduplicate within each provider. |
| `--direct` | Use the raw model ids as returned, with no stripping or deduplication. |
| `--dry-run` | Print what would change without writing anything or creating a backup. |
| `--help` | Show usage and exit. |

Run `--dry-run` first to preview:

```bash
./update_opencode_models.sh --dry-run
```

## What is preserved

- Existing models that are still on the server keep their config as-is
  (`reasoningEffort`, context/output limits, feature flags, etc.).
- Providers that are unreachable or missing a key are skipped, not modified.
- Everything outside each provider's `models` object is left untouched.

## What is updated

- New models returned by the server are added with the default config below.
- Models no longer returned by the server are removed.

## Default model config

New models are added with:

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

Change the `MODEL_CONFIG` variable near the top of the script to customize this.

## Backup

A backup is written to `/tmp/opencode_backup_<timestamp>.json` before each real
run. The path is printed when the run finishes. To restore:

```bash
cp /tmp/opencode_backup_<timestamp>.json ~/.config/opencode/opencode.json
```

## Notes

- Providers and `baseURL`s come from `opencode.json`; API keys come from
  `~/.local/share/opencode/auth.json`.
- A provider is skipped with a warning if it has no `baseURL`, no API key, or is
  unreachable.
