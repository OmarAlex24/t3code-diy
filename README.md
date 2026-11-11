# t3code-diy

Run your own modified build of [T3 Code](https://github.com/pingdotgg/t3code) on your Mac and keep
it current with upstream, without an Apple Developer account. By default your build is its own app,
"T3 Code Custom", running next to the official one.

**Unofficial.** This is a personal kit. It is not made, endorsed or supported by T3 Tools / Ping.
Don't report problems with your DIY build to the T3 Code team.

There are two ways to use it: run someone else's branch (no fork needed), or keep your own fork
building every day.

## Try Omar's sandbox build

Omar's fork ([OmarAlex24/t3code](https://github.com/OmarAlex24/t3code), branch
`feat/sandbox-environments`) adds sandbox environments. Save a sandbox config once (Boat, Daytona,
Vercel, Upstash or Celesto), and every new thread you start on it gets its own throwaway cloud
machine that clones the repo from GitHub and runs the thread there. Background and feedback:
[discussion #27949](https://github.com/pingdotgg/t3code/discussions/27949).

You don't need a fork. The kit clones Omar's branch, rebases it onto upstream `main` on your Mac
every day, runs the sandbox tests, and builds a "T3 Code Custom" app that sits next to your normal
T3 Code, with its own data and settings:

```sh
git clone https://github.com/OmarAlex24/t3code-diy.git
cd t3code-diy
./bin/t3code-diy install --yes --no-push \
  --fork-url https://github.com/OmarAlex24/t3code.git \
  --branch feat/sandbox-environments \
  --test-group '^(apps/server/src/sandbox/.*\.test\.ts|packages/contracts/src/sandbox[^/]*\.test\.ts)$' \
  --test-group '^apps/web/src/.*Sandbox[^/]*\.browser\.test\.tsx$'
```

`--no-push` matters: you can't push to Omar's repo, and without it every run would fail at the push
step. Install clones about 700 MB of history (minutes, depending on your connection), then the
first build starts right away and takes roughly 10 to 20 minutes: tests, a Rust helper, the
Electron build and signing. Follow it with `~/.t3code-diy/kit/bin/t3code-diy status`, and once a
build is in the feed:

```sh
~/.t3code-diy/kit/bin/t3code-diy install-app
```

Then open T3 Code Custom and set up a sandbox config as described in the fork's
[docs/user/remote-access.md](https://github.com/OmarAlex24/t3code/blob/feat/sandbox-environments/docs/user/remote-access.md).

## Make your own

Fork `pingdotgg/t3code`, put your changes on a branch, and point the kit at it:

```sh
./bin/t3code-diy install --yes \
  --fork-url git@github.com:you/t3code.git --branch my-changes \
  --test-group '^apps/server/src/myfeature/.*\.test\.ts$'
```

The kit keeps that branch rebased onto upstream and pushes it back to your fork after the tests
pass (force-with-lease, see [Caveats](#caveats)). Leave out `--yes` to be asked for each setting.

## Requirements

`install` checks all of these and tells you what's missing:

- A Mac with Apple Silicon (arm64 only)
- Xcode Command Line Tools (`xcode-select --install`), for git, codesign, clang and python3
- Node 22 or newer and [Vite+](https://viteplus.dev) (`vp`), which T3 Code uses for installs and tests
- Rust from [rustup.rs](https://rustup.rs) plus `rustup target add aarch64-apple-darwin` (the app
  ships a small Rust helper, so this isn't optional)
- [Claude Code](https://docs.claude.com/en/docs/claude-code), logged in (`claude auth login`), or
  the [Codex CLI](https://developers.openai.com/codex/cli), logged in (`codex login`) with
  `--resolver codex`. It resolves rebase conflicts when upstream and the branch collide.
- About 15 GB of free disk (repo, dependencies, a pristine upstream checkout for the test gate,
  the last 3 builds)

## What it does

Every day (and when you log in) a launchd job on your Mac:

1. fetches upstream `main` and the branch you follow, and rebases that branch onto upstream
   (with `git rerere` on, so a conflict you resolved once stays resolved)
2. if the rebase conflicts, runs Claude Code or Codex headless to resolve it
3. runs the branch's own tests (your `--test-group`s) plus upstream's `vp run check:changed`
4. pushes the rebased branch back to your fork (skipped with `--no-push`)
5. builds the macOS app, signs it with a self-signed certificate that lives only on your Mac,
   and publishes it to a feed served on `127.0.0.1`

Your app's own "update available" button then installs the new build, like the official app does
with its releases.

If nothing changed since the last build it does nothing. If the rebase or the tests fail, nothing
gets pushed or published and your branch is put back where it was. The push happens right after
the tests pass, so if the build or signing fails after that, the rebased branch is already on your
fork but nothing is published. Either way the app you have installed stays as it is, and you get a
macOS notification with the path to the log.

Everything runs on your machine with your Claude (or Codex) login and your signing key. There's no CI, no
secrets in GitHub, and no binaries to download: you build your own.

## Install

Either command above does it. Without `--yes`, `install` asks for the repo URL, branch, whether to
push, feed port, schedule and conflict resolver.

`./bin/t3code-diy install --help` lists every option. Install puts everything in
`~/.t3code-diy/` (set `DIY_HOME` to use another place): the config, a clone of the branch's repo, the
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

Other commands: `update` runs the job by hand in your terminal (`--force` builds even if nothing
changed, `--no-push` skips the push), `run` starts the launchd job now and returns right away,
`log [--tail N]` prints the last run's log, `config get/set` reads or changes one setting (below),
`uninstall` removes the launchd jobs (`--purge` also deletes `~/.t3code-diy`).

## Conflict resolver

When `git rerere` can't replay a resolution, the job hands the stopped rebase to an agent:
Claude Code (`claude -p`) by default, or Codex (`codex exec`). Pick one, its model, and how hard
it thinks:

```sh
~/.t3code-diy/kit/bin/t3code-diy config set RESOLVER_PROVIDER codex RESOLVER_MODEL gpt-5.5
~/.t3code-diy/kit/bin/t3code-diy config set RESOLVER_PROVIDER claude RESOLVER_MODEL opus
~/.t3code-diy/kit/bin/t3code-diy config set RESOLVER_EFFORT high
~/.t3code-diy/kit/bin/t3code-diy config set RESOLVER_MODEL '' RESOLVER_EFFORT ''   # the CLI's own defaults
```

`RESOLVER_EFFORT` is empty by default, which means whatever the CLI picks on its own. Claude takes
`low`, `medium`, `high`, `xhigh` or `max` (it becomes `claude --effort`); Codex takes those plus
`none` and `minimal` (it becomes `-c model_reasoning_effort=...`). Ultracode, Codex's Ultra and
Ultrathink aren't on the list: they spin up extra agents or live in the prompt, which isn't what
you want from a one-shot rebase. Switch providers and an effort the new CLI doesn't have just goes
back to empty, so `RESOLVER_PROVIDER claude` after Codex's `minimal` leaves you on Claude's default.

`set` checks every value before it writes anything, and won't switch to a CLI that isn't installed
and logged in. Model names are what T3 Code shows (`opus`, `claude-opus-4-6[1m]`, `gpt-5.5`); the
agent gets `RESOLVER_TIMEOUT_MIN` minutes (default 90). Configs from before this used
`CLAUDE_MODEL`; that value carries over as `RESOLVER_MODEL` and the next write renames it.
`install --resolver codex --model gpt-5.5 --effort high` does the same at install time. Older
configs have no `RESOLVER_EFFORT` line and keep working; the next write adds it.

`config set` also takes `RESOLVER_TIMEOUT_MIN`, `PUSH` and `RUN_CHECK_CHANGED`. `config get KEY`
reads any plain setting. Schedule, port, labels and the `SIDE_*` values still go through `install`,
because launchd or a rebuild has to pick them up.

## In the app

Each build puts `T3CODE_DIY_BIN` (the path to `~/.t3code-diy/kit/bin/t3code-diy`) in the app's
`Info.plist`, next to the side-by-side keys. A fork that knows about it shows a Custom build card
in Settings, About: the last update and its result, the log, an Update now button and the
conflict resolver picker (provider, model and effort, written with `config set`). It talks to the kit only through the commands below, so the kit and the
app can be updated separately. Without the key (anybody else's fork, or the official app) nothing
changes. Side-by-side builds also get `T3CODE_DESKTOP_DISPLAY_NAME="$SIDE_APP_NAME"`, which a fork
that reads it uses for the window title and the About panel.

## Machine-readable status

`t3code-diy status --json` prints one JSON object and never asks anything. It stays off the
network and takes a fraction of a second, so it's fine to poll. `schema` goes up only when a field
changes meaning or goes away; new fields can show up any time, so ignore the ones you don't know.

```json
{
  "schema": 1,
  "kit": { "bin": "/Users/you/.t3code-diy/kit/bin/t3code-diy", "home": "/Users/you/.t3code-diy" },
  "mode": "side-by-side",
  "app": {
    "name": "T3 Code Custom",
    "path": "/Applications/T3 Code Custom.app",
    "installedVersion": "0.1.8-nightly.20261105.900004",
    "forkBuild": true,
    "latestBuild": "0.1.8-nightly.20261105.900005"
  },
  "fork": { "url": "git@github.com:you/t3code.git", "branch": "my-changes" },
  "upstream": { "url": "https://github.com/pingdotgg/t3code.git", "branch": "main" },
  "resolver": { "provider": "claude", "model": "opus", "effort": "", "timeoutMinutes": 90 },
  "schedule": { "loaded": true, "hour": 5, "minute": 0, "atLogin": true, "nextRun": "2026-11-05T05:00:00-06:00" },
  "running": false,
  "lastRun": {
    "result": "ok",
    "reason": "built 0.1.8-nightly.20261105.900005",
    "startedAt": "2026-11-04T18:25:37-06:00",
    "endedAt": "2026-11-04T18:39:04-06:00",
    "version": "0.1.8-nightly.20261105.900005",
    "log": "/Users/you/.t3code-diy/logs/update-20261104-182537.log"
  }
}
```

- `app.installedVersion` is `null` when the app isn't in `/Applications`; `latestBuild` is the newest
  build in the feed, which the app picks up through its own updater.
- `schedule.nextRun` is the next daily run (local time, ISO 8601), `null` when the job isn't loaded.
  Runs at login aren't predictable, so they aren't in it.
- `resolver.effort` is `""` when the CLI picks its own effort. Kits from before `RESOLVER_EFFORT`
  leave it out, so treat a missing one the same way.
- `running` is true from the moment launchd starts the job until it exits.
- `lastRun` is `null` before the first run. `result` is one of `ok` (a new build is in the feed),
  `up_to_date` (nothing changed), `running`, `conflict_unresolved`, `tests_failed`,
  `migration_collision`, `rebase_failed`, `push_failed`, `build_failed`, `interrupted` (the run
  died without finishing: killed, or the Mac shut down) and `error` (anything else). `reason` is one
  plain sentence. On every result but `ok` the installed app is exactly as it was. `endedAt`
  is `null` while it runs.

Exit codes: `run`, `config` and `log` exit 0 on success, 1 when something is wrong (the message is
on stderr) and 2 for a bad command line.

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
| icon | upstream's Nightly icon | T3 Code Dev's blueprint (`ICON`) |
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

**Icon.** So you can tell the two apps apart in the Dock, side-by-side builds get T3 Code Dev's
blueprint icon (`assets/dev/blueprint-macos-1024.png` from the repo being built). Want your own?
Pass `install --icon path/to/icon.png` with a 1024px PNG that's already shaped like a macOS icon
(transparent margins, rounded square). Relative paths are inside the repo being built, so an
icon you commit to your fork works too. `--icon ''` keeps the stock icon. It's the `ICON` line in
the config; after changing it run `update --force` and update the app from inside it. If the
file is missing at build time, the run logs it and builds with the stock icon instead of failing.
Replace mode keeps the stock icon unless you pass `--icon`.

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
  When a fork test group fails, the files of its failing tests run once more on their own, and if
  that re-run passes the failures count as flaky (a loaded machine makes browser tests time out now
  and then); the log names them. When the output doesn't pin the failure on a test (a file that
  won't load, an error outside the tests such as a browser session that never connected), every
  file of the group runs once more, one at a time, and if they all pass the failure counts as flaky
  too; the log says why. A re-run that fails blocks the build, and the failure says how many tests
  failed and names the first, or says that no test was named even file by file. A check:changed
  test failure is re-run alone the same way, and one that fails again only counts as OK if the same
  test also fails on a pristine upstream checkout (`~/.t3code-diy/upstream-check`). Anything else
  blocks the build.
- Browser tests (`*.browser.test.tsx`) need Playwright's headless Chromium. The gate downloads the
  version the repo pins into `~/.t3code-diy/playwright-browsers` (once, about 100 MB), the same
  step upstream's CI runs.
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

The sandbox command in [Try Omar's sandbox build](#try-omars-sandbox-build) is a real example of
test groups.

## Caveats

The basics:

- **Unofficial.** Not made, endorsed or supported by T3 Tools / Ping. Problems with a DIY build
  go here, not to the T3 Code team.
- **macOS on Apple Silicon only.** No Intel, no Linux, no Windows.
- **Self-signed.** The app is signed with a certificate made on your Mac, not by Apple. It isn't
  notarized, so it's meant for the Mac that built it, and passkeys don't work (below).
- **Local feed only.** Updates come from `127.0.0.1` on your Mac. Nothing is downloaded from
  anyone else and there's nothing to share.
- **Following someone else's branch** means running their code with your provider logins, rebased
  on your Mac. Your local rebase can differ from theirs, and their force-pushes are picked up on
  the next run. Read the diff if you care.

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
- The window title and the About panel say "T3 Code (Nightly)" (the name inside the app's code)
  unless your fork reads `T3CODE_DESKTOP_DISPLAY_NAME`, which the kit sets to your app's name. The
  app name, menu and Dock say yours either way.
- **Icon caching.** Finder and the Dock cache icons, so after an update that changes the icon the
  old one can stick around. Quit the app, then run `killall Dock Finder`; if it's still the old
  one, `touch "/Applications/T3 Code Custom.app"` first. The small permission prompts the app
  shows keep the stock icon: they read the copy packed inside `app.asar`, which the kit leaves
  alone.

Both modes:

- **Passkeys don't work** in a self-signed build: they need an Apple-issued entitlement. Email and
  OAuth sign-in work.
- **T3 Connect** works because the build uses the public Clerk and relay settings upstream ships in
  `.env.example` (install copies it to `.env`). If upstream changes or removes those, Connect stops
  working in your build.
- **Database migrations.** Upstream numbers its migrations in
  `apps/server/src/persistence/Migrations.ts`, and the migrator skips every id up to the highest one
  a database recorded. A fork migration added there takes the next free id, which upstream ships
  sooner or later, and then the two can't both live in one database. So keep your fork's migrations
  in their own list with their own history table (in Omar's fork, `ForkMigrations.ts` and
  `t3_fork_migrations`), and leave upstream's list exactly as upstream has it. The job checks this
  before every rebase and stops with `migration_collision` if your fork adds anything to upstream's
  list; moving it out is up to you, since databases that already ran it need their history moved
  too. The official app never reads the fork's table, so the fork's tables in a database are just
  extra tables to it. Rollback still restores your pre-switch database, because the fork build may
  have run upstream migrations newer than the official release; anything you did in the fork build
  stays in the fork-era copy.
- **The conflict agent runs unattended.** Claude Code gets permission to edit files, run git
  add/commit/rebase --continue and the test commands in the managed repo, nothing else (`git push`,
  `git config` and `git remote` are denied). Codex has no per-command allowlist, so it runs with its
  sandbox off (the rebase writes to `.git` and `vp i` writes outside the repo, which its sandbox
  refuses). Neither can push, and that part doesn't depend on the agent: for its run every remote's
  push URL in `.git/config` points nowhere and SSH and credential prompts are off. The real URLs
  are saved first and put back afterwards, even when the run fails or is killed (then the next run
  puts them back), and a remote the agent added is removed. After the agent exits the job checks
  that your branch on GitHub didn't move. The script itself pushes, and only after the tests pass.
  Claude Code runs with background tasks off and a 30-minute command timeout, so it waits for its
  test runs instead of moving them to the background and waiting for a report that never comes.
  When the agent runs out of time, it is stopped along with every process it started. Read the
  logs now and then.
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
