# uem-add-supported-model.sh

A bash script that adds a supported device model ID to macOS internal app records in Workspace ONE UEM via the REST API. Authenticates using OAuth 2.0 client credentials.

## Requirements

- `bash` 4+
- `curl`
- `jq`
- A WS1 UEM OAuth client (client ID + secret) with MAM read/write permissions

## Setup

### 1. Make the script executable

```bash
chmod +x uem-add-supported-model.sh
```

### 2. Set your credentials

You can either export environment variables or pass them as flags on every run. Environment variables are recommended so credentials aren't visible in your shell history.

```bash
export WS1_CLIENT_ID="your-client-id"
export WS1_CLIENT_SECRET="your-client-secret"
export WS1_TOKEN_URL="https://uat.uemauth.workspaceone.com/connect/token"
export WS1_API_BASE_URL="https://as1831.awmdm.com"
```

> **Tip:** Add these exports to a `.env` file and `source` it before running:
> ```bash
> source .env && ./uem-add-supported-model.sh --model-id 121 --all
> ```

## Usage

```
./uem-add-supported-model.sh --model-id <id> [--bundle-id <bundle_id> | --all] [OPTIONS]
```

### Required argument

| Flag | Description |
|------|-------------|
| `--model-id <id>` | The numeric model ID to add (e.g. `121` for MacBook Neo) |

### Target (one required)

| Flag | Description |
|------|-------------|
| `--bundle-id <bundle_id>` | Update a single app identified by its bundle ID |
| `--all` | Update all macOS internal apps in the environment |

### Optional flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview changes without making any API calls |
| `--api-base <url>` | Override `WS1_API_BASE_URL` |
| `--token-url <url>` | Override `WS1_TOKEN_URL` |
| `--client-id <id>` | Override `WS1_CLIENT_ID` |
| `--client-secret <s>` | Override `WS1_CLIENT_SECRET` |
| `-h, --help` | Show usage |

## Examples

### Add MacBook Neo to a single app (dry run first)

```bash
./uem-add-supported-model.sh \
  --model-id 121 \
  --bundle-id com.ws1.macos.MarkEdit \
  --dry-run
```

### Add MacBook Neo to a single app (for real)

```bash
./uem-add-supported-model.sh \
  --model-id 121 \
  --bundle-id com.ws1.macos.MarkEdit
```

### Add MacBook Neo to all macOS apps (dry run first — recommended)

```bash
./uem-add-supported-model.sh --model-id 121 --all --dry-run
```

### Add MacBook Neo to all macOS apps

```bash
./uem-add-supported-model.sh --model-id 121 --all
```

### Use a different environment (e.g. production)

```bash
./uem-add-supported-model.sh \
  --model-id 121 \
  --all \
  --api-base "https://your-prod-instance.awmdm.com" \
  --token-url "https://uemauth.workspaceone.com/connect/token" \
  --client-id "prod-client-id" \
  --client-secret "prod-client-secret"
```

## How it works

1. Requests an OAuth 2.0 bearer token using client credentials
2. Fetches all internal apps from the UEM API (filtered to macOS / platform 10)
3. For each target app, checks whether the model ID is already in `SupportedModels`
4. If not present, sends a `PUT /api/mam/apps/internal/{id}` request with the updated model list
5. Skips apps that already have the model — safe to re-run

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | All updates succeeded (or nothing needed updating) |
| `1` | One or more updates failed, or a required argument was missing |

## Finding model IDs

Model IDs are numeric values used by UEM to identify device hardware families. Common macOS model IDs:

| ID | Model |
|----|-------|
| 14 | MacBook Pro |
| 15 | MacBook Air |
| 16 | Mac Mini |
| 30 | iMac |
| 31 | Mac Pro |
| 35 | MacBook |
| 113 | Mac Studio |
| 121 | MacBook Neo |

To discover IDs for new models, check an existing app in the UEM console that already has the new model assigned, or query the picklist API:

```bash
curl -H "Authorization: Bearer <token>" \
  "https://<api-base>/api/mdm/picklists/platforms/10/devicemodels"
```
