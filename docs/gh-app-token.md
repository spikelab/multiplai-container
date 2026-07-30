# GitHub App tokens on the macOS host (`multiplai-gh-token`)

**Goal:** the App private key never enters a container and never reaches a repo. A
container calls `multiplai-gh-token` over the SSH bridge and gets back only a 1-hour
installation token (`ghs_…`).

**Storage: mode-600 files under `~/.local/state/multiplai-gh-token/<app>/`.** Not the login
Keychain — that was the original design and it is **impossible**, not merely awkward: a
non-interactive SSH session cannot read the login keychain at all. See
[Why not the Keychain](#why-not-the-keychain-settled--do-not-re-litigate).

Several Apps can live side by side; each is a directory, and a session picks one with
`GH_TOKEN_APP=<app>`.

```
~/.local/state/multiplai-gh-token/        (mode 700)
  default                                 optional — the app used when none is named
  mint.log                                audit log, one line per mint (mode 600)
  <app>/                                  (mode 700)
    app-id                                the numeric App ID          (mode 600)
    app.pem                               the RSA private key         (mode 600)
    org                                   the org/user login it is installed on (mode 600)
```

## Why a file, and what it costs

The Keychain being out, the choice was between a LaunchAgent in the GUI session proxying
the mint over a socket, and a plain file the SSH session reads directly. We chose the file:
**fewest moving parts, no launchd, no daemon lifecycle**. The security delta is smaller
than "plaintext key on disk" sounds:

- With **FileVault on**, the file is encrypted at rest at the volume level anyway.
- Its in-session exposure — readable by any process running as you — is *exactly* what the
  Keychain ACL granted too, since `-T /usr/bin/security` trusts a binary any such process
  can simply exec, and `-A` trusts everything.
- What you genuinely give up: protection against someone holding your **unlocked disk but
  not your login session** (a mounted backup, a borrowed FileVault-unlocked machine).

If that last row ever matters, the LaunchAgent+socket design is the upgrade path and the
minting logic moves across unchanged.

Options ruled out earlier, recorded so they aren't re-proposed:

- **Secure Enclave / Touch ID is impossible here.** GitHub requires the App JWT to be
  signed with **RS256** — an RSA key ([docs](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app)).
  The Secure Enclave only holds EC P-256 keys. No hardware-backed, biometric-gated option
  exists for this credential. Verified 2026-07-28.
- **1Password would work but isn't installed** — `op` and `envchain` are both absent from
  the Mac. Prior research also flags that 1Password's biometric prompt displays on the
  physical machine and *blocks* remote connections over SSH, with Service Accounts (a
  long-lived token) as the documented workaround — which reintroduces exactly the
  long-lived-credential problem this removes. If you later standardise on 1Password,
  swapping `read_cred` in `multiplai-gh-token` for `op read` is a two-line change — and
  unlike the Keychain it would actually work over SSH.

## What this does and does not protect against

| Threat | Protected? |
|---|---|
| Key accidentally committed to a repo | ✅ lives outside any repo, mode 600 |
| Key exfiltrated by a compromised container | ✅ **the key never enters the container** |
| Stolen laptop / disk image / Time Machine backup | ⚠️ only as far as FileVault protects it |
| Another process running as you | ❌ can read the file (as it could the Keychain item) |
| Container asks the host to mint a token | ❌ **by design — that's the feature** |
| Token printed into an agent transcript | ❌ never echo it — see [Transcript hygiene](#transcript-hygiene) |

Be clear-eyed about the last two rows: nothing here stops a compromised agent from
*obtaining a token*, because minting is precisely what is being authorised. What it buys is
that the agent can only ever hold a **1-hour, installation-scoped** credential, and can
never hold the key that mints them. Revocation is one step (remove the container's SSH key,
or uninstall the App) rather than "rotate a PAT and hope nothing cached it".

This is the same trade SSH agent forwarding makes, and it is strictly better than a
long-lived PAT sitting in the container's environment.

## Setup

### 1. Create the App and install it

On GitHub: **Settings → Developer settings → GitHub Apps → New GitHub App** (create it
under the **organisation**, not your personal account, if it is meant to act on org repos).

- **Permissions** — grant only what the sessions need. A useful baseline for code work:
  *Repository permissions* → Contents: Read & write · Pull requests: Read & write ·
  Issues: Read & write · Metadata: Read-only (implied). Add Actions/Checks read if you
  want CI visibility. The minted token carries **exactly** the installation's grant:
  `multiplai-gh-token` sends an empty POST body and does no down-scoping, deliberately.
- **Where can this App be installed** — "Only on this account" is fine.
- Then **Install App** on the account/org and choose the repositories. The installation is
  what the token is scoped to; changing the repo selection changes every future token with
  no client change.
- On the App's settings page, **Generate a private key**. GitHub hands you the `.pem` once,
  at creation time — it only ever gives you the *private* half. Note the **App ID** at the
  top of the same page.

### 2. Install the App ID, the key, and the org

Three files in one mode-700 directory. `multiplai-gh-token` **enforces** these permissions
and refuses to run otherwise — a 0644 private key is the one mistake this design must never
fail silently on. It also refuses symlinks, so the mode check can't be sidestepped.

```bash
APP=myapp          # the profile name you will put in GH_TOKEN_APP
ORG=my-org         # the account/org the App is installed on

umask 077
mkdir -p ~/.local/state/multiplai-gh-token/"$APP"
chmod 700 ~/.local/state/multiplai-gh-token ~/.local/state/multiplai-gh-token/"$APP"

PEM=./my-app.2026-07-30.private-key.pem     # whatever GitHub named it
[ -s "$PEM" ] || echo "STOP: no such pem: $PEM"
head -1 "$PEM"                              # BEGIN RSA PRIVATE KEY, not PUBLIC

cp "$PEM" ~/.local/state/multiplai-gh-token/"$APP"/app.pem
echo "<your App ID from the App settings page>" > ~/.local/state/multiplai-gh-token/"$APP"/app-id
echo "$ORG" > ~/.local/state/multiplai-gh-token/"$APP"/org
chmod 600 ~/.local/state/multiplai-gh-token/"$APP"/*

# Optional: make a bare `multiplai-gh-token` (no argument) pick this one.
# Not needed if only one profile exists — that one is used automatically.
echo "$APP" > ~/.local/state/multiplai-gh-token/default
chmod 600 ~/.local/state/multiplai-gh-token/default
```

### 3. Verify — without minting anything

```bash
~/.local/bin/multiplai-gh-token --check "$APP"
```

`--check` validates the directory (modes, ownership, symlinks, that `app.pem` is a usable
RSA private key), prints the App ID, the org, the file modes and the **public-key
fingerprint**, and exits. It makes **no network call and prints no token**, which is what
makes it the diagnostic you can safely run inside an agent session. Compare the fingerprint
with the one GitHub shows on the App's settings page.

Then remove the duplicates — a secret in two places is two places to leak it and two to
forget to rotate:

```bash
rm "$PEM"      # the download, if you still have it
```

Check the obvious leftovers too: `~/Downloads`, the Trash (empty it), and anywhere your
browser auto-saved it. A Time Machine backup taken *before* this point still contains the
original `.pem` — if that matters, generate a new key in the App settings (old keys can be
deleted there) and redo step 2 with it.

### 4. Install the script and allowlist the verb

Both ship in this repo and are installed for you by `multiplai-kit/setup.sh` from the
**pinned** container checkout, on the same gates as the SSH gateway:

```bash
cd ~/.multiplai-runtimes/default && git pull && ./setup.sh
ls -l ~/.local/bin/multiplai-gh-token          # -rwxr-xr-x
grep -c multiplai-gh-token ~/.local/bin/container-build-gateway.sh   # 1 branch
```

Installing the host script and the gateway verb from the same tag is deliberate: they are
two halves of one contract, and shipping them from different generations is exactly the
version skew the gateway gate exists to prevent.

The gateway branch accepts **at most** an optional leading `--json` or `--check` plus one
app name, validates the name against `[A-Za-z0-9._-]` with a leading alphanumeric, rejects
every other flag, and pins argv[0] to `$HOME/.local/bin/multiplai-gh-token` — `~/.local/bin`
is not on the login PATH that the gateway's `zsh -lc` resolves through.

### 5. Point a session at it

In the kit, one line in the profile that identity uses:

```bash
# ~/.multiplai-runtimes/default/env.<profile>
GH_TOKEN_APP="myapp"
```

**One identity per profile.** `GH_TOKEN_APP` and a PAT (`GH_TOKEN` /
`GH_TOKEN_KEYCHAIN`) declared in configuration at the same time is a **hard launch error**,
not a precedence rule — a silent winner means running as the wrong GitHub identity. So keep
the PAT in its own profile and `GH_TOKEN_APP` in another, with neither in `.env`. See the
kit's `docs/PROFILES.md`.

## Using it from a session

**There is no idiom to learn.** `gh` and `git` are authenticated from the first command and
stay that way:

```bash
gh api /installation/repositories --jq '.repositories | length'
git ls-remote https://github.com/<org>/<repo>          # no token in the URL
```

That works because the kit ships two hooks (`dotfiles/hooks/gh-app-auth.sh` at
SessionStart, `dotfiles/hooks/gh-app-refresh.sh` on PreToolUse(Bash)) which mint through
`dotfiles/hooks/gh-tok` and store the token in **gh's own credential store** (`hosts.yml`),
and because the kit already runs `gh auth setup-git`, which makes `gh auth git-credential`
git's credential helper. The refresh hook checks the cached expiry **at the moment of use**,
so a session that sat idle for nine hours re-mints on its next command. The kit owns that
contract — see `multiplai-kit/README.md` and `dotfiles/CLAUDE.md`; it is not duplicated here
so the two repos cannot drift into disagreeing.

Cache (container-side, mode 600 in a mode-700 directory):

```
~/.cache/multiplai/gh/<app>.json        the full mint response (.token, .expires_at)
~/.cache/multiplai/gh/<app>.json.exp    the expiry as a bare epoch integer
```

A missing, unparseable or expired cache is always treated as "re-mint"; the token is never
printed, logged, or passed on argv.

### When it doesn't work

| Symptom | Meaning |
|---|---|
| `Bad credentials (HTTP 401)`, exit **1** | the token expired or was revoked — the refresh hook failed or is not registered |
| `requires authentication`, exit **4** | there is no token at all — nothing was stored in `hosts.yml` |
| `DENIED: command not in allowlist` | the host gateway predates the verb — re-run `./setup.sh` on the Mac |
| `ssh: connect …` from `gh-tok` | the host bridge is unreachable; the container has no other route to the key |

Transcript-safe diagnostics, in order:

```bash
ssh host.docker.internal multiplai-gh-token --check "$GH_TOKEN_APP"   # prints no token
gh auth status
"$CLAUDE_CONFIG_DIR/hooks/gh-tok" "$GH_TOKEN_APP" >/dev/null; echo "rc=$?"
```

## Transcript hygiene

> ⚠️ **Never run a token-printing form bare in an agent session.** `multiplai-gh-token` and
> `multiplai-gh-token --json` print the token on stdout — correct for their contract, but in
> an agent session that stdout lands in the transcript on disk *and* in API logs. This
> happened on 2026-07-28: a `contents:write` token covering 12 org repos sat in a transcript
> for ~5 minutes. Redirect, or use `--check`:
>
> ```bash
> T=$(ssh host.docker.internal multiplai-gh-token "$GH_TOKEN_APP" 2>/dev/null)
> GH_TOKEN="$T" gh api /installation/repositories --jq '.repositories[].full_name'
> ```

**If one does leak, revoke it — don't wait out the hour.** A token revokes itself:

```bash
GH_TOKEN="$LEAKED" gh api -X DELETE /installation/token -i   # => HTTP 204
GH_TOKEN="$LEAKED" gh api /installation/repositories         # => Bad credentials
```

Then check the audit log for mints you can't account for.

## Audit

Every mint appends one tab-separated line to `~/.local/state/multiplai-gh-token/mint.log`
(mode 600):

```
2026-07-30T16:04:11Z	app=myapp	install=12345678	expires=2026-07-30T17:04:11Z	client=192.168.x.x 51234 22	cmd=multiplai-gh-token --json myapp
```

`app=` is what makes a multi-App log readable. Worth a glance occasionally — an unexpected
mint is the signal that something reached the bridge that shouldn't have. `--check` runs are
**not** logged: they mint nothing.

## Migrating from `dolce-gh-token`

The predecessor was a single-App script with a hardcoded org, credentials at
`~/.local/state/dolce-gh-token/` and its gateway verb hand-patched onto the host (so the
next `./setup.sh` deleted it). Migration is a move plus one new file:

```bash
APP=<app>                # the profile name, e.g. the org in lowercase
ORG=<org>                # what dolce-gh-token had hardcoded

umask 077
mkdir -p ~/.local/state/multiplai-gh-token/"$APP"
mv ~/.local/state/dolce-gh-token/app-id  ~/.local/state/multiplai-gh-token/"$APP"/app-id
mv ~/.local/state/dolce-gh-token/app.pem ~/.local/state/multiplai-gh-token/"$APP"/app.pem
echo "$ORG" > ~/.local/state/multiplai-gh-token/"$APP"/org
echo "$APP" > ~/.local/state/multiplai-gh-token/default
chmod 700 ~/.local/state/multiplai-gh-token ~/.local/state/multiplai-gh-token/"$APP"
chmod 600 ~/.local/state/multiplai-gh-token/"$APP"/* ~/.local/state/multiplai-gh-token/default

~/.local/bin/multiplai-gh-token --check "$APP"        # no token printed
```

**Only once `--check` and a real mint both pass**, remove the old installation:

```bash
mv ~/.local/state/dolce-gh-token.log ~/.local/state/multiplai-gh-token/mint.log 2>/dev/null || true
rmdir ~/.local/state/dolce-gh-token
rm -f ~/.local/bin/dolce-gh-token
```

Also check `~/.local/bin/container-build-gateway.sh` for a hand-patched `dolce-gh-token)`
branch and confirm `./setup.sh` has replaced the file with the released version — the
generic branch shipped in this repo is what makes the verb survive an update.

## Why not the Keychain (settled — do not re-litigate)

**Does `security find-generic-password` succeed from a non-interactive SSH session?**
**No. Not by any configuration of the item.** Settled empirically 2026-07-28. This is why
the key lives in a file; everything below is the evidence, so nobody spends another hour
on it.

### The decisive experiment

```bash
ssh localhost 'security find-generic-password -s … -a … -w; echo "rc=$?"'
# rc=36                       (errSecInteractionNotAllowed, no message on stderr)
ssh localhost 'security show-keychain-info; echo "rc=$?"'
# security: SecKeychainCopySettings <NULL>: User interaction is not allowed.   rc=36
```

`show-keychain-info` reads the **keychain's own settings** and touches no item — no ACL,
no partition list, no secret. It failing identically proves the refusal is at the
**keychain/session level**, not the item level: the login keychain is locked in the SSH
session's context (Background launchd namespace) while the GUI session has it unlocked.
The same read from a Terminal in the GUI session returns the full value.

Corollaries, each of which cost a wrong theory:

- Item-level fixes cannot work: not `-T /usr/bin/security`, not `-A`, not
  `set-generic-password-partition-list`. All were tried; all left `rc=36`.
- `security unlock-keychain` would work but needs the login password in a script, which
  is the thing this whole design exists to avoid.
- It is **not** the macOS 26 (Tahoe) `security -w` regression some posts describe: that
  would return `rc=0` with empty output. A real refusal returns 36.
- Beware pipes when diagnosing: `security … -w | wc -c` reports **`wc`'s** exit status, so
  the failure reads as `rc=0` with `0` bytes and looks like an empty keychain item.

The SSH session does see the correct search list — `~/Library/Keychains/login.keychain-db`,
the right `HOME` and `USER` — so this is not a "can't find the keychain" problem. It is
**`rc=36` = `errSecInteractionNotAllowed`**: securityd needs the unlock password, has no
UI to ask on, and refuses.

**The partition list is a real thing and still not the fix.** Since macOS Sierra there are
*two* gates on a keychain item: the trusted-application ACL (`-T`) and the **partition
list**, a check on the code-signing origin of the caller (`apple:`, `apple-tool:`,
`teamid:…`, `unsigned:`). It's the missing piece in the well-known Mac-CI codesigning
recipe — `security import -T /usr/bin/codesign` **followed by** `security
set-key-partition-list -S apple-tool:,apple:` — and the generic-password equivalent is
`set-generic-password-partition-list`. Both were applied; `rc=36` was unchanged, because a
session-level refusal happens before any item is consulted. Worth knowing for the Xcode
signing case; irrelevant here.

Reading `security`'s exit codes: it returns the OSStatus truncated to one byte. `44` =
`errSecItemNotFound` (-25300), `36` = `errSecInteractionNotAllowed` (-25308). Worth
knowing, since the message on stderr is often empty.

If you ever want the Keychain back, the only designs that can work are: a **LaunchAgent in
the Aqua session** proxying the mint over a UNIX socket (the key stays in the keychain, no
token at rest), or a **dedicated keychain with an empty password** unlocked by the script
itself — which is security theatre, since an empty-password keychain is no better than the
mode-600 file we chose and has more moving parts.
