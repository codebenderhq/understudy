# understudy

Your understudy, in the terminal.

It studies your apps the way an understudy studies a lead role — then keeps
them performing: fixes, changes, and upkeep, handled with care while you
focus on the work only you can do. You are the lead. It never takes your
stage.

Built by [Worklyn](https://worklyn.com) for its understudy clients.

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
