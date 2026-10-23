# Contributing

**The preferred way to contribute is an issue.** Open an
[issue](https://github.com/sagemathinc/sagebrush-cloud/issues) with a clear
description of the problem or the change you'd like: what you saw, what you
expected, and how to reproduce it. A precise description, or a "prompt" for the
change, is something the team (people and their agents) can implement and review
here.

**Pull requests from outside the team** are accepted under a lightweight
Contributor License Agreement, signed through the CLA Assistant app when you
open your first PR. Without a signed CLA, a PR can't be merged. This repository
is MS-RSL, so the CLA is what lets SageMath, Inc. ship your change.

For everyone:

- Changes land only through reviewed pull requests, never by direct push.
- CI must be green: the `cloud` check runs the server tests and the sync client
  suite against the real server, built against `core.lock`.
- Never commit secrets: keys, tokens, account data or `.env` files. Tests use
  fixed test keys in Miniflare, and deploys read secrets from outside the
  repository.
- **Bumping core:** change `core.lock` to the new core commit in its own PR, and
  let CI test this tree against it. Code in core (the engine, the sync protocol
  and client) is changed in
  [sagemathinc/sagebrush](https://github.com/sagemathinc/sagebrush), not here.
- Security issues: see [SECURITY.md](SECURITY.md). Don't open a public issue
  for them.
