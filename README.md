# sagebrush-cloud

The Cloudflare application behind [sagebrush.space](https://sagebrush.space):
the site Worker, sharing (the share API and the user-content Worker), the sync
server and, soon, the LTI 1.3 tool for learning management systems.

**This is source-available, not open source.** It's published under the
[Microsoft Reference Source License (MS-RSL)](LICENSE.md). The Licensor is
SageMath, Inc. You may read the code for reference; the license doesn't grant
the right to run, modify or redistribute it.

## Earlier history: MIT OR Apache-2.0

These files began in the open core,
[sagemathinc/sagebrush](https://github.com/sagemathinc/sagebrush). Their
contents up to core commit
[`1cf6642c`](https://github.com/sagemathinc/sagebrush/commit/1cf6642c6f24d6a1cb79475309755eaa55dde799)
were published there under **MIT OR Apache-2.0**, and remain available there
under those terms. The history in this repository up to that point is the same
history, kept with `git filter-repo`. Changes made in this repository after it
are MS-RSL.

## What's open, and where

- The Sagebrush engine, the notebook and board front ends, and everything else
  that runs in the browser are in core, under MIT OR Apache-2.0.
- The **sync protocol** is core's open contract: `web/sync-protocol/`.
- The **sync client** is open too: `web/workspace/`.
- Only the servers live here.

## Building against core

This repository holds only the server directories. They're built and tested
inside a core checkout, overlaid at the same paths, so every relative import
resolves as it does in core.

- `core.lock` holds the one core commit this tree is built against. Bumping core
  is a PR that changes it.
- `scripts/with-core.sh -- <command>` makes (or reuses) a cached core worktree
  at `core.lock`, copies this checkout's `web/{site,files,share,sync,lti}` into
  it, and runs the command there. For example:

  ```sh
  scripts/with-core.sh -- bash -c 'pnpm install --frozen-lockfile && pnpm run build && node scripts/build-cli.mjs && bun web/build.ts && (cd web/site && npm ci) && node web/sync/test-sync.mjs'
  ```

- CI (`.github/workflows/ci.yml`) does exactly that, and runs the server tests
  and the open sync client's suite against the real server.

## Security

See [SECURITY.md](SECURITY.md).
