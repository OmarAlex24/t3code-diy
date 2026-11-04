# t3code-diy

Run your own modified build of [T3 Code](https://github.com/pingdotgg/t3code) on your Mac and keep
it current with upstream, without an Apple Developer account. By default your build is its own app,
"T3 Code Custom", running next to the official one.

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

Your app's own "update available" button then installs the new build, like the official app does
with its releases.

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

When a build is in the feed, install it:

```sh
~/.t3code-diy/kit/bin/t3code-diy install-app
```

That puts `/Applications/T3 Code Custom.app` next to the official app, which stays as it is. Open
it like any app. On first launch macOS asks to let it use "t3code Safe Storage" in your keychain.
Enter your password and pick **Always Allow**. Updates keep the same signature, so it won't ask
again. After that the app updates itself; you only run `install-app` again if you change one of the
`SIDE_*` settings. `uninstall-app` removes it (its data stays).

Other commands: `update` runs the job by hand (`--force` builds even if nothing changed,
`--no-push` skips the push), `uninstall` removes the launchd jobs (`--purge` also deletes
`~/.t3code-diy`).

## Modes

**side-by-side** (default). Your build is a separate app with its own name, bundle id, data and
server, so it runs at the same time as the official T3 Code:

| | official | yours (defaults) |
| --- | --- | --- |
| app | `T3 Code (Nightly).app` | `T3 Code Custom.app` (`SIDE_APP_NAME`) |
| bundle id | `com.t3tools.t3code` | `com.t3tools.t3code.custom` (`SIDE_BUNDLE_ID`) |
| T3 home | `~/.t3` | `~/.t3-custom` (`SIDE_T3_HOME`) |
| Electron profile | `~/Library/Application Support/t3code-v2` | `.../t3code-custom` (`SIDE_USER_DATA_NAME`) |
| server port | 3773 or the next free one | 3873 (`SIDE_PORT`) |
| updates | GitHub releases | your local feed |

Upstream's Beta and Nightly can't run together: they share the bundle id, the profile dir (and with
it the single-instance lock) and `~/.t3`. Only the Dev build is separate, and only because it runs
from a dev server. So the kit separates your build itself:

- The home and port use settings T3 Code already reads (`T3CODE_HOME`, `T3CODE_PORT`). The profile
  dir is hardcoded upstream, so each build applies a 3-line patch
  (`templates/patches/userdata-name.patch`) that adds a `T3CODE_DESKTOP_USER_DATA_NAME` override.
  It goes in after the tests and the push, comes out right after the build, and never gets
  committed. If upstream changes that file so the patch no longer applies exactly, the run stops
  with a notification and nothing is published. The build is also checked for the override before
  it's published.
- The app is renamed the way electron-builder would for another product name, and the three
  values above go into its `Info.plist` (`LSEnvironment`), so it starts the same way from Finder,
  the Dock or after an update. Its baked `app-update.yml` points at your local feed only.

If you change a `SIDE_*` value in the config, run `update --force`, quit the app, then
`install-app`.

**replace**. Your build takes the official app's place: same name, bundle id and data. Pick it with
`install --mode replace`; then you use `switch` and `rollback` instead of `install-app` and
`uninstall-app`. Run those from Terminal.app, not from a terminal inside T3 Code, because they ask
you to quit the app.

`switch` backs up `~/.t3/userdata`, the Electron data in `~/Library/Application Support` and the
current `/Applications/T3 Code (Nightly).app` into `~/.t3code-diy/backup/<date>/`, then installs your
build. `rollback` puts the official app and your pre-switch data back; your fork-era data isn't
deleted, it's moved to `~/.t3code-diy/backup/<date>-fork-state/`.

There's one feed, so switching modes means the app from the other mode stops getting updates.
Configs from before modes existed stay in replace mode.

## How updates work

- The build version is `<next patch>-nightly.<UTC date>.<900000+n>`, e.g.
  `0.1.8-nightly.20261104.900003`. The big sequence number makes your builds sort above the
  official nightlies, so the app always sees yours as newer.
- The local feed URL is baked into your app (`Contents/Resources/app-update.yml`). The official
  app keeps reading GitHub and never sees your feed. T3 Code's managed
  policy file could also set a feed URL, but it only accepts https, so that route doesn't work for a
  local feed.
- The feed has both `nightly-mac.yml` and `latest-mac.yml`, so either update channel finds it.
- The app is re-signed inside out (binaries, then nested bundles, then the app) with the hardened
  runtime and the build's entitlements minus the ones that need an Apple provisioning profile.
  Renaming and the `Info.plist` changes happen before signing, and the feed zip is made from the
  signed app.
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

Side-by-side:

- **Separate everything.** Your app has its own projects, threads, settings and T3 Connect
  sign-in. Provider logins (Claude Code, Codex and so on) live in their own CLIs, so both apps
  share those.
- **Seeing the official app's threads.** Add the official app's server as an environment in your
  app: through T3 Connect (sign in to both with the same account) or over your LAN (turn on network
  access in the official app and pair).
- **First launch imports old v1 storage.** If you still have the pre-2.0 profile
  (`~/Library/Application Support/t3code`), upstream copies its browser storage into the new app's
  profile once (read-only, the old profile isn't changed). Saved environments from back then can
  show up, e.g. this Mac's official server, which is a quick way to see its threads.
- **`t3code://` links** (and browser sign-in callbacks) go to one app only: the one that started
  last, since each app makes itself the handler when it starts. Your app keeps the `t3code` scheme
  because T3 Connect's sign-in uses it as the app's origin, and another scheme may not be accepted.
  If a Google/GitHub sign-in in one app doesn't come back, quit and reopen that app and try again.
- **Two servers** run while both apps are open, so expect roughly twice the memory.
- **Port.** If something else holds `SIDE_PORT`, your app can't start its server. Pick another
  port.
- **Terminals inside your app** see `T3CODE_HOME=~/.t3-custom`, so a `t3` command run there talks
  to your app. Don't use "Install t3 command" in your app unless you want `t3` everywhere to mean
  your build.
- The About panel still says "T3 Code (Nightly)" (the name inside the app's code); the app name,
  menu and Dock say yours.

Both modes:

- **macOS arm64 only.** No Intel, no Linux, no Windows.
- **Passkeys don't work** in a self-signed build: they need an Apple-issued entitlement. Email and
  OAuth sign-in work.
- **T3 Connect** works because the build uses the public Clerk and relay settings upstream ships in
  `.env.example` (install copies it to `.env`). If upstream changes or removes those, Connect stops
  working in your build.
- **Migration collisions.** If your fork adds a database migration, it takes the next free id. When
  upstream later ships its own migration with that id, the two can't both live in one database. The
  job stops with a notification instead of guessing; you decide (usually: move your migration to a
  new id and accept that databases that already ran it need fixing by hand). In side-by-side mode
  your build has its own database, so this never touches the official app's. In replace mode it's
  why **rollback only works until upstream ships a conflicting migration**: after that, the
  official app refuses a database your fork migrated. Rollback restores your pre-switch database
  for that reason, but anything you did in the fork build stays in the fork-era copy.
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
