# src/tools

Standalone scripts shipped with llm-docker but not part of the container image or the daemon. Each one is self-contained and can be run without cloning the repo.

---

## provision-llmdocker.sh

Set up an `llmdocker` user on a remote server so containers can SSH out to it.

> **Warning — `llmdocker` effectively IS root.** The sudoers file grants full `NOPASSWD` sudo with a small block-list against typo mistakes that would take out root itself. That block-list is a **speed-bump against fat-fingers, NOT a security boundary** — `sudo bash` still gives a root shell. Only run this on servers you fully control.

**What it does on the target host:**

1. Creates user `llmdocker` (home `/home/llmdocker`, shell `/bin/bash`) if missing.
2. Installs the caller-provided public key into `~llmdocker/.ssh/authorized_keys`.
3. Drops `/etc/sudoers.d/llmdocker` with **full `NOPASSWD` sudo** and only these typo-guards — root cannot be *accidentally* deleted or taken over:
   - Delete root: `userdel root`, `deluser root`
   - Change root's password: `passwd root`, `passwd -l/-d root`, `chage * root`
   - Modify root's account: `usermod * root`
   - `su` to root as a shell (any form)
   - `rm /root` / `rm -r /root` / `rm -rf /root/*`
4. Validates the sudoers file with `visudo -c` before installing.

Idempotent — re-running is safe. Supports Debian/Ubuntu, RHEL/Rocky/Alma/Fedora/Amazon, and Alpine (via `/etc/os-release`).

---

**Usage — from the llm-docker installer (automatic):**

Step 6b of `install.sh` offers to run this against a hostname you provide. It handles the pubkey plumbing for you.

**Usage — standalone (later, or against a server the installer didn't touch):**

```
# From your Mac, with an admin ssh login you already have set up:
PUBKEY="$(cat ~/.llm-docker/llmdocker_ed25519.pub)"      # or wherever your key lives
ssh admin@server.example.com \
    "bash -s -- --pubkey '$PUBKEY'" \
    < src/tools/provision-llmdocker.sh
```

Or curl-pipe from raw GitHub (no clone needed):

```
PUBKEY="ssh-ed25519 AAAA... llmdocker@my-mac"
curl -fsSL https://raw.githubusercontent.com/RussianRoulette84/llm-docker/master/src/tools/provision-llmdocker.sh \
  | ssh admin@server.example.com "bash -s -- --pubkey '$PUBKEY'"
```

Or if you'd rather pipe the key on stdin:

```
printf '%s\n' "$PUBKEY" | ssh admin@server "bash -s -- --pubkey-stdin" < src/tools/provision-llmdocker.sh
```

---

**Verifying afterwards:**

```
# should succeed (llmdocker has full sudo)
ssh llmdocker@server.example.com 'echo hi; sudo -n apt-get update -y'

# should be denied (typo-guards on root)
ssh llmdocker@server.example.com 'sudo -n /bin/rm -r /root'
ssh llmdocker@server.example.com 'sudo -n /usr/bin/passwd root'
ssh llmdocker@server.example.com 'sudo -n /bin/su -'
```

---

**Adjusting the typo-guard list:**

The `Cmnd_Alias LLMD_DENY` block inside `provision-llmdocker.sh` is the typo-guard set — it stops fat-finger `passwd root` / `rm /root` / `su -` mistakes, nothing more. Add or remove entries to taste, but don't confuse it with an allowlist: llmdocker already has full sudo, so every other command works. If you actually need to bound what llmdocker can do, replace `ALL=(ALL) NOPASSWD: ALL, !LLMD_DENY` with an explicit allowlist.
