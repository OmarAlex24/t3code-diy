# t3code-diy

Run your own modified build of [T3 Code](https://github.com/pingdotgg/t3code) on your Mac and keep
it current with upstream, without an Apple Developer account.

**Unofficial.** This is a personal kit. It is not made, endorsed or supported by T3 Tools. Don't
report problems with your DIY build to the T3 Code team.

## What it does

Every day (and when you log in) a launchd job on your Mac:

1. fetches upstream `main` and your fork's branch, and rebases your branch onto upstream
   (with `git rerere` on, so a conflict you resolved once stays resolved)
2. if the rebase conflicts, runs Claude Code headless to resolve it
3. runs your fork's tests plus upstream's `vp run check:changed`
4. pushes the rebased branch back to your fork
5. builds the macOS app, signs it with a self-signed certificate that lives only on your Mac,
   and publishes it to a feed served on `127.0.0.1`

T3 Code's own "update available" button then installs the new build, like it does for the
official one.

If nothing changed since the last build it does nothing. If the rebase or the tests fail, nothing
gets pushed or published and your branch is put back where it was. The push happens right after
the tests pass, so if the build or signing fails after that, the rebased branch is already on your
fork but nothing is published. Either way the app you have installed stays as it is, and you get a
macOS notification with the path to the log.

Everything runs on your machine with your Claude login and your signing key. There's no CI, no
secrets in GitHub, and no binaries to download: you build your own.

## Requirements

- A Mac with Apple Silicon (arm64 only)
- Xcode Command Line Tools (`xcode-select --install`)
- Node and [Vite+](https://viteplus.dev) (`vp`), which T3 Code uses for installs and tests
- Rust from [rustup.rs](https://rustup.rs) plus `rustup target add aarch64-apple-darwin`
- [Claude Code](https://docs.claude.com/en/docs/claude-code), logged in (`claude auth login`)
- A fork of `pingdotgg/t3code` with a branch carrying your changes
- About 15 GB of free disk (repo, dependencies, a pristine upstream checkout for the test gate,
  the last 3 builds)

`install` checks all of this and tells you what's missing.

## Install

```sh
git clone <this repo> t3code-diy
cd t3code-diy
./bin/t3code-diy install
```

It asks for your fork URL, branch, feed port, schedule and Claude model. Or pass everything:

```sh
./bin/t3code-diy install --yes \
  --fork-url git@github.com:you/t3code.git --branch my-changes \
  --test-group '^apps/server/src/myfeature/.*\.test\.ts$'
```

`./bin/t3code-diy install --help` lists every option. Install puts everything in
`~/.t3code-diy/` (set `DIY_HOME` to use another place): the config, a clone of your fork, the
signing keychain, builds, the feed and logs. It loads two launchd jobs, `dev.t3code-diy.feed` and
`dev.t3code-diy.update`, and the first update starts right away. A cold first run takes a while
(dependencies, a Rust build, a full test pass).

Check on it:

```sh
~/.t3code-diy/kit/bin/t3code-diy status
```

When a build is in the feed, switch to it. Do this from Terminal.app, not from a terminal inside
T3 Code, because it asks you to quit the app:

```sh
~/.t3code-diy/kit/bin/t3code-diy switch
```

`switch` backs up `~/.t3/userdata`, the Electron data in `~/Library/Application Support` and the
current `/Applications/T3 Code (Nightly).app` into `~/.t3code-diy/backup/<date>/`, then installs your
build. On first launch macOS asks to let the app use "t3code Safe Storage" in your keychain. Enter
your password and pick **Always Allow**. Updates keep the same signature, so it won't ask again.

To go back to the official app and your pre-switch data:

```sh
~/.t3code-diy/kit/bin/t3code-diy rollback
```

Your fork-era data isn't deleted; it's moved to `~/.t3code-diy/backup/<date>-fork-state/`.

Other commands: `update` runs the job by hand (`--force` builds even if nothing changed,
`--no-push` skips the push), `uninstall` removes the launchd jobs (`--purge` also deletes
`~/.t3code-diy`).

## How updates work

- The build version is `<next patch>-nightly.<UTC date>.<900000+n>`, e.g.
  `0.1.8-nightly.20261104.900003`. The big sequence number makes your builds sort above the
  official nightlies, so the app always sees yours as newer.
- The local feed URL is baked into the app (`Contents/Resources/app-update.yml`). T3 Code's managed
  policy file could also set a feed URL, but it only accepts https, so that route doesn't work for a
  local feed.
- The feed has both `nightly-mac.yml` and `latest-mac.yml`, so either update channel finds it.
- The app is re-signed inside out (binaries, then nested bundles, then the app) with the hardened
  runtime and the build's entitlements minus the ones that need an Apple provisioning profile.
- The test gate runs your `FORK_TEST_GROUPS` (must pass) and `vp run check:changed upstream/main`.
  A check:changed test failure only counts as OK if the same test also fails on a pristine upstream
  checkout (`~/.t3code-diy/upstream-check`). Anything else blocks the build.
- One run at a time (lock file). Logs: `~/.t3code-diy/logs/update-*.log` (last 30 kept).
- Daily time, port, model and the rest live in `~/.t3code-diy/config`. After editing schedule, port
  or labels, re-run `install` so the launchd jobs pick them up.

## Customizing your fork

Do your work in your own clone of your fork, push to your branch, and the next run picks it up.
Don't work inside `~/.t3code-diy/repo`; the job resets that branch on every run.

Tell the gate about your tests with `--test-group` (or `FORK_TEST_GROUPS` in the config). Each entry
is an extended regex over `git ls-files`; the matching files run in one `vp test run`. A group that
matches nothing fails the run, so renamed tests don't silently stop running.

If you write `~/.t3code-diy/fork-notes.md`, it's added to the conflict agent's prompt. A few lines
on what your fork changes and where it lives help it keep your side of a conflict.

Example fork: [OmarAlex24/t3code](https://github.com/OmarAlex24/t3code), branch
`feat/sandbox-environments` (cloud sandbox environments). Its gate looks like:

```sh
FORK_TEST_GROUPS=(
  '^(apps/server/src/sandbox/.*\.test\.ts|packages/contracts/src/sandbox[^/]*\.test\.ts)$'
  '^apps/web/src/.*Sandbox[^/]*\.browser\.test\.tsx$'
)
```

It's only an example; nothing here depends on it.

## Caveats

- **macOS arm64 only.** No Intel, no Linux, no Windows.
- **Passkeys don't work** in a self-signed build: they need an Apple-issued entitlement. Email and
  OAuth sign-in work.
- **T3 Connect** works because the build uses the public Clerk and relay settings upstream ships in
  `.env.example` (install copies it to `.env`). If upstream changes or removes those, Connect stops
  working in your build.
- **Migration collisions.** If your fork adds a database migration, it takes the next free id. When
  upstream later ships its own migration with that id, the two can't both live in one database. The
  job stops with a notification instead of guessing; you decide (usually: move your migration to a
  new id and accept that databases that already ran it need fixing by hand). This is also why
  **rollback only works until upstream ships a conflicting migration**: after that, the official
  app refuses a database your fork migrated. Rollback restores your pre-switch database for that
  reason, but anything you did in the fork build stays in the fork-era copy.
- **The conflict agent runs unattended.** Claude Code gets permission to edit files, run git
  add/commit/rebase --continue and the test commands in the managed repo, nothing else. It can't
  push: `git push` is denied in its permissions and its git sees a dead push URL. The script itself
  pushes, and only after the tests pass. Read the logs now and then.
- **Force-push.** The daily job rewrites your branch (it's a rebase) and pushes it with
  `--force-with-lease`. If you pushed something in between, the push fails and nothing is built.
  Don't use the branch for anything that can't handle being rebased. For pushes over SSH the job
  needs your key available without a prompt (e.g. in the macOS keychain via `ssh-add
  --apple-use-keychain`); over https, a credential helper like `gh auth setup-git`.
- **Remote servers show "behind".** Your build's version doesn't exist on GitHub, so a remote T3
  server you connect to may report the client as out of date. That's expected.
- **Keep the signing identity.** `~/.t3code-diy/signing` holds the certificate, its own keychain and
  the keychain password (in a 0600 file). If you delete it, the installed app stops accepting
  updates (different signature) and macOS asks for keychain access again.

## License

MIT, see [LICENSE](LICENSE). T3 Code itself is MIT licensed by T3 Tools Inc.
