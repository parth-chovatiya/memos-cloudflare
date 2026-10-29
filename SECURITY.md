# Security Policy

## Where to report

- **Vulnerabilities in Memos itself** (the app, its API, its UI): report them to the
  upstream project, see [usememos/memos](https://github.com/usememos/memos/security).
- **Vulnerabilities in this deployment template** (the Worker, `run.sh`, the
  Dockerfile, how secrets or the R2 replica are handled): please report them
  privately through this repository's **Security > Report a vulnerability** tab
  rather than opening a public issue.

## Keeping your instance safe

- Disable public sign-ups in Memos right after creating your admin account.
- Scope the R2 API token to the `memos-litestream` bucket with Object Read & Write
  only. Never use an account-wide token.
- Keep secrets in `wrangler secret put` / `.dev.vars`, never in committed files.
- Upgrade Memos regularly by bumping `MEMOS_VERSION` in the Dockerfile.
