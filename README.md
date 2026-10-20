# QuotaSwap

A macOS menu bar app for people who use more than one Claude account in the Claude desktop app.

- **One-click account switching.** No signing out, no browser sign-in. QuotaSwap keeps a local snapshot of each account's login and swaps them.
- **Your Code sessions follow you.** The desktop app keeps a separate Code session list per account. QuotaSwap merges those lists when you switch, so every account shows every session, with its full history.
- **Usage for every account, with pace.** Each account shows its 5-hour and weekly usage and when each resets. A tick on the bar marks how much of the window has passed. The bar turns red when you are using faster than the clock, yellow when you are on pace, and green when you are behind it.

The menu bar shows the signed-in account's usage, for example `5h 42% · Wk 26%`.

Not affiliated with or endorsed by Anthropic. Use it within Anthropic's terms for your plans.

## Install

Requires macOS 13 or later. Builds are notarized and universal (Apple silicon and Intel).

```bash
brew install --cask hellotaotao/tap/quotaswap
```

Or download the DMG from [Releases](https://github.com/hellotaotao/QuotaSwap/releases).

## Getting started

1. Sign in to Claude as usual, then open QuotaSwap from the menu bar and click **Save this account**.
2. Click **Add account…**. Claude restarts at its sign-in screen, and the account you just saved stays saved.
3. Sign in to your other account in Claude, then click **Save this account** in QuotaSwap again.
4. From now on, click **Use account** next to any account to switch.

The first time QuotaSwap reads usage, macOS asks whether it may use the "Claude Safe Storage" keychain item. QuotaSwap needs it to decrypt Claude's session cookie on your Mac. Choose **Always Allow** so you are not asked again.

Use **Add account…** rather than Claude's own **Log out**. Logging out may revoke the saved login on Anthropic's side, and you would have to sign in and save that account again.

## How it works

QuotaSwap relies on undocumented details of the Claude desktop app. That is why it runs a self-check before every change.

| What | Where |
|---|---|
| Login snapshot per account: the OAuth token cache from `config.json` and the `Cookies` database, both still encrypted by Claude | `~/Library/Application Support/Claude-accounts/` (readable only by you) |
| Code session lists, one per account | `~/Library/Application Support/Claude/claude-code-sessions/` |
| Session transcripts, shared by all accounts | `~/.claude/projects/` |

**Switching** quits Claude, saves the current account's latest login (tokens rotate, so the snapshot is refreshed every time you leave an account), merges the Code session lists, restores the target account's login, and reopens Claude. Running chats and Code sessions stop when Claude quits; QuotaSwap asks before it does that.

**Usage** comes from the same endpoint claude.ai uses for its usage page, called with each account's saved session cookie. Nothing is refreshed or rotated, so checking usage never invalidates a saved login.

**Self-check.** Before any change, QuotaSwap verifies that Claude's config fields, cookie database and session index still look as expected. If a Claude update changes them, switching is disabled and the menu explains which check failed. Nothing is written in that state.

**Privacy.** Everything stays on your Mac. The only network requests are the usage requests to claude.ai. There is no telemetry.

## Command line

The Homebrew cask also installs a `quotaswap` command:

```text
quotaswap list                 saved accounts, * marks the signed-in one
quotaswap usage                5-hour and weekly usage of every saved account
quotaswap doctor               check the Claude internals QuotaSwap relies on
quotaswap use ACCOUNT          switch Claude to ACCOUNT (name, email, or a unique prefix)
quotaswap save [NAME]          save the signed-in account
quotaswap add                  sign Claude out locally to add another account
quotaswap rename OLD NEW       change a saved account's short name
quotaswap sync [--dry-run]     merge Code session lists across accounts
```

## Uninstall

```bash
brew uninstall --zap --cask quotaswap
```

`--zap` also deletes the saved login snapshots in `~/Library/Application Support/Claude-accounts/`. Claude itself keeps whichever account was signed in last.

## Build from source

```bash
scripts/build-app.sh      # universal build/QuotaSwap.app; SIGN_ID=- signs ad hoc
scripts/test-fake.sh      # end-to-end tests against a fake Claude directory
```

The tests need `python3` with the `cryptography` package to forge encrypted cookies. They never touch your real Claude data.

## License

MIT
