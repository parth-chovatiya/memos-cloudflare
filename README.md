# Memos on Cloudflare

Self-host [Memos](https://github.com/usememos/memos), the open-source, privacy-first
note-taking service, entirely on Cloudflare: a Worker in front, Memos in a
[Cloudflare Container](https://developers.cloudflare.com/containers/), and your data
continuously backed up to R2 by [Litestream](https://litestream.io).

No VPS to patch, the container sleeps when idle, and the database survives every
restart and redeploy.

> This is an independent deployment template, not affiliated with the Memos project.
> It runs the official, unmodified `neosmemo/memos` image. See [Credits](#credits).

## How it works

```text
Browser -> Worker -> Durable Object "singleton" -> Container
                                                   +- litestream replicate (PID 1)
                                                   |    +- memos (SQLite, WAL)
                                                   +- streams WAL every 1s -> R2 bucket "memos-litestream"
```

- The container disk is ephemeral: it is wiped whenever the container sleeps
  (after 15 min idle), is redeployed, or crashes.
- On every boot, [run.sh](run.sh) restores the SQLite database from R2, then runs
  Memos under Litestream, which streams every change back to R2 about once a second
  and does a final sync on shutdown.
- A single, fixed Durable Object guarantees exactly one Memos instance, so there is
  only ever one writer to the replica.

## Requirements

- A Cloudflare account on the **Workers Paid** plan ($5/month). Containers require it.
- [Docker](https://docs.docker.com/get-docker/) running locally. Wrangler builds the
  image on your machine and pushes it to Cloudflare.
- Node.js 22 or newer (see [.nvmrc](.nvmrc)).

## Install

### 1. Clone and log in

```bash
git clone <this-repo-url> memos-cloudflare
cd memos-cloudflare
npm install
npx wrangler login
```

### 2. Create the R2 bucket

```bash
npx wrangler r2 bucket create memos-litestream
```

### 3. Create an R2 API token

Litestream talks to R2 through its S3-compatible API, which needs its own credentials.

In the Cloudflare dashboard, go to **R2 > Manage API tokens > Create API token**:

- Permissions: **Object Read & Write**
- Specify bucket: **memos-litestream** only

Keep the **Access Key ID** and **Secret Access Key** it shows; you need them next.

### 4. Set the secrets

Your account ID is shown by `npx wrangler whoami` (and on the R2 overview page).

```bash
npx wrangler secret put R2_ACCOUNT_ID
npx wrangler secret put R2_ACCESS_KEY_ID
npx wrangler secret put R2_SECRET_ACCESS_KEY
```

If Wrangler asks whether to create the `memos` Worker, answer yes.

### 5. Deploy

```bash
npm run deploy
```

The first deploy takes a few minutes while the image builds and uploads. Wrangler
prints your URL, e.g. `https://memos.<your-subdomain>.workers.dev`.

### 6. Create your account

Open the URL. The first boot can take up to a minute; a `503` with "Memos is starting"
just means retry shortly. Sign up: **the first account becomes the admin**. Then go
to **Settings > System** and disable public sign-ups, or anyone who finds your URL
can register.

To watch it boot: `npm run logs` (look for `run.sh: restoring`, then Memos listening
on port 5230).

## Configuration

All per-deployment settings are secrets, so you never need to edit tracked files.

| Name | Kind | Required | Purpose |
| --- | --- | --- | --- |
| `R2_ACCOUNT_ID` | secret | yes | Builds the R2 S3 endpoint |
| `R2_ACCESS_KEY_ID` | secret | yes | R2 API token used by Litestream |
| `R2_SECRET_ACCESS_KEY` | secret | yes | R2 API token used by Litestream |
| `MEMOS_INSTANCE_URL` | secret | no | Public URL Memos uses for absolute links, e.g. a custom domain |
| `R2_BUCKET` | var in [wrangler.jsonc](wrangler.jsonc) | yes | Defaults to `memos-litestream` |
| `LITESTREAM_ALLOW_EMPTY` | var in [wrangler.jsonc](wrangler.jsonc) | yes | Leave `"false"`; see below |

To use a custom domain, add it under **Workers & Pages > memos > Settings > Domains &
Routes**, then `npx wrangler secret put MEMOS_INSTANCE_URL`.

## Data safety

**The empty-replica safety latch.** On the very first boot there is no backup yet,
so the restore is allowed to find nothing. Once Memos has booted successfully, the
Worker records that in its Durable Object storage. From then on, if the container
boots and can't find the backup (wrong credentials, bucket, or path), it refuses to
start instead of booting an empty Memos and replicating that over your history.
This happens automatically; there is nothing to toggle after the first deploy.

To deliberately start over with an empty database (for example after switching to a
new, empty bucket), set `"LITESTREAM_ALLOW_EMPTY": "true"` in
[wrangler.jsonc](wrangler.jsonc), deploy, then set it back to `"false"` and deploy
again.

**Never run two instances against the same bucket.** Two Litestream writers on one
replica path corrupt it. `max_instances` is 1 for this reason; don't raise it. For
the same reason, don't run `npm run dev` with your production secrets: give local
development its own bucket (see [Local development](#local-development)).

**Attachments.** Memos stores uploads inside the SQLite database by default. That's
safe, since they are replicated with everything else, but it grows every snapshot
and slows every cold start. For heavy use, create a second bucket (e.g.
`memos-assets`) and set **Memos > Settings > Storage** to S3 with endpoint
`https://<ACCOUNT_ID>.r2.cloudflarestorage.com` and region `auto`. Do **not** choose
local file storage: the container disk is wiped on every restart.

**Container disk size.** The `basic` instance has a 4 GB disk, and the database is
restored onto it on every boot. Keep the database comfortably below that, or pick a
larger `instance_type` in [wrangler.jsonc](wrangler.jsonc).

## Local development

```bash
npx wrangler r2 bucket create memos-litestream-dev
cp .dev.vars.example .dev.vars   # fill in your R2 credentials
npm run dev                      # builds the container locally with Docker
npm run check                    # regenerate types and typecheck
```

`.dev.vars` points at the separate `memos-litestream-dev` bucket, so local runs never
touch your production backup.

## Backup and restore

Your backup is the `memos/` prefix in the `memos-litestream` bucket:

```bash
npx wrangler r2 object list memos-litestream --prefix memos/
```

To rebuild a plain SQLite file locally (with [Litestream](https://litestream.io/install/)
installed):

```bash
export LITESTREAM_ACCESS_KEY_ID=<R2 access key id>
export LITESTREAM_SECRET_ACCESS_KEY=<R2 secret access key>
litestream restore -o ./restored.db \
  "s3://memos-litestream/memos?endpoint=https://<ACCOUNT_ID>.r2.cloudflarestorage.com&region=auto"
```

Running this occasionally is a good way to confirm your backup actually works.

## Upgrading Memos

The Memos version is pinned in the [Dockerfile](Dockerfile) (`ARG MEMOS_VERSION`) so
a redeploy never runs unplanned database migrations. To upgrade:

1. Read the [Memos release notes](https://github.com/usememos/memos/releases).
2. Take a local copy of your data with the restore command above.
3. Bump `MEMOS_VERSION` to the new tag and run `npm run deploy`.

## Troubleshooting

- **`503 Memos is starting or unavailable`** right after a deploy or idle period is
  a normal cold start. If it persists, check `npm run logs`.
- **`run.sh: R2_... is not set`** or **`Missing config`**: a secret is missing;
  repeat step 4.
- **Container won't start after it worked before**: usually the safety latch found
  no backup. Check the secrets and that `R2_BUCKET` matches your bucket.
- **Docker build fails**: make sure Docker is running. The build pulls from Docker
  Hub (`neosmemo/memos`, `litestream/litestream`).

## Credits

This project just packages other people's excellent work for Cloudflare:

- **[Memos](https://github.com/usememos/memos)** by the
  [usememos](https://github.com/usememos) team and contributors, the note-taking
  app itself. MIT License. If you like Memos, star and support the
  [upstream project](https://github.com/usememos/memos).
- **[Litestream](https://github.com/benbjohnson/litestream)** by Ben Johnson and
  contributors, streaming SQLite replication. Apache License 2.0.
- **[Cloudflare Containers](https://developers.cloudflare.com/containers/)** and
  [`@cloudflare/containers`](https://github.com/cloudflare/containers).

No Memos or Litestream source code is included in this repository; their official
Docker images are used at build time, under their own licenses.

## License

The deployment code in this repository is released under the [MIT License](LICENSE).
