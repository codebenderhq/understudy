# understudy

The coding agent Worklyn's understudy clients use to maintain their apps.

## Install

```sh
curl -fsSL https://worklyn.com/understudy/install | bash
```

(Coming soon.)

## Sign in

```sh
understudy auth login
```

Authenticates via OAuth against worklyn.me. Your Worklyn account determines
which models and quotas are available.

## Support

team@worklyn.com

## Attribution

understudy is built on [opencode](https://github.com/anomalyco/opencode)
(MIT licensed). This project is **not affiliated with or endorsed by the
opencode team**. All product identity is applied at build time; the source
tree tracks upstream with a near-zero committed diff (see
`script/understudy-transform.sh` and `.github/workflows/sync.yml`).
