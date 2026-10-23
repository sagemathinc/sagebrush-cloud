# Security policy

## Reporting a vulnerability

Report security issues in this repository **privately**, never in a public
issue or pull request:

- through [GitHub's private vulnerability reporting](https://github.com/sagemathinc/sagebrush-cloud/security/advisories/new)
  for this repository, or
- by email to [security@cocalc.ai](mailto:security@cocalc.ai).

Please include what you found, how to reproduce it, and what it lets someone do.

Fixes are developed in a private repository and published here when they're
ready, with the same history.

## Anything that affects CoCalc

These servers sit at CoCalc's boundary: sign-in with CoCalc, CoCalc accounts and
tokens, the user-content hosting on `cocalcusercontent.com`, and the LTI tool's
connection to cocalc.ai. Issues there can affect CoCalc's users. They're always
private, as above, and CoCalc's own policy also applies:
[SECURITY.md](https://github.com/sagemathinc/cocalc-ai/blob/main/SECURITY.md).

## The open core

Issues in the engine, the front ends, the sync protocol or the sync client
belong to the open core. Its policy is
[sagemathinc/sagebrush's SECURITY.md](https://github.com/sagemathinc/sagebrush/blob/master/SECURITY.md).
If you aren't sure which side an issue is on, report it privately here.
