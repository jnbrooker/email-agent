# Mail Agent

A local assistant for running email outreach and replies with Claude, over your own Gmail.
It reads your inbox, decides what needs a reply, drafts (or sends) responses in a consistent
voice, composes cold-outreach to lists of addresses, and pulls pricing out of replies into a
spreadsheet. It runs entirely on your machine and uses **your** Claude subscription and **your**
Gmail — nothing is sent anywhere else.

There are two ways to use it:

- **`app.py`** — a Streamlit web UI (recommended). Point-and-click inbox, reply generation,
  outreach, extraction, a setup wizard, and an auto-run pipeline.
- **`run.sh`** — a headless command-line agent for unattended/scheduled runs.

Both share the same prompt files and the same Gmail/Claude setup.

---

## How it works

- **[Himalaya](https://github.com/pimalaya/himalaya)** is the mail client — it talks to Gmail over
  IMAP/SMTP using a Gmail **app password**.
- **[Claude Code](https://docs.claude.com/en/docs/claude-code)** (`claude -p`, headless) writes the
  email text. It only ever returns text; the app decides whether and where to send.
- **Agents** are email "types" (e.g. arena hospitality, conferencing, football). Each agent is a
  pair of prompt files (`compose-<key>.md`, `reply-<key>.md`). The persona name in every email is
  taken from the selected account, via the `{NAME}` placeholder in those prompts.

Safety model: replies always go back to the sender; outbound only ever goes to an address you put
in the queue **and** allowlist; draft mode is the default; a per-run rate cap limits blast radius.

---

## Requirements

- **Git Bash** (Windows) or any bash shell (macOS/Linux)
- **Python 3.10+**
- **[himalaya](https://github.com/pimalaya/himalaya)** and **jq** on your `PATH`
  (on Windows: `scoop install himalaya jq`)
- **Claude Code** installed and logged in (`claude setup-token`)
- A **Gmail** account with 2-Step Verification enabled

---

## Quick start

```bash
git clone <your-repo-url> mail-agent
cd mail-agent
bash run-ui.sh          # installs streamlit/pandas/openpyxl, opens http://localhost:8502
```

Then open the **Setup** tab and:

1. **Claude login** — click *Test Claude*. If it's not logged in, run `claude setup-token` in a
   terminal (or paste a token in the Setup tab).
2. **Add a Gmail account** — enter an account key (e.g. `me`), your Gmail address, your display
   name, and a Gmail **app password** (create one at
   <https://myaccount.google.com/apppasswords>). This writes your Himalaya config for you.
3. Reselect the account in the sidebar and start using the **Inbox** / **Outreach** tabs.

To add more email types, use **Setup -> Add a new agent**: give it a key, a label, and a description
of what its emails should ask for — it generates the two prompt files and registers them.

---

## The config model (what's yours vs what's shared)

Committed with the repo: `config.example.json` (template), the `compose-*.md` / `reply-*.md`
prompts, `triage-system.md`, `extract-system.md`, `Pricing_Template.xlsx`,
`himalaya-config.sample.toml`.

Created locally and never committed: `config.json` (your accounts + agents), `.env` (optional
Claude token), `~/.config/himalaya/config.toml` (mailbox secrets), and the runtime files
`queue.txt`, `allow.txt`, `decided.txt`, `handled.txt`, `agent.log`.

`.gitignore` already excludes all of the local files, so your secrets and contact data can never be
pushed. The app runs fine with none of them present and creates them as needed.

---

## Files

| File | Purpose |
|------|---------|
| `app.py` | The Streamlit UI |
| `run.sh` | Headless CLI agent (for scheduling) |
| `run-ui.sh` | Launches the UI (`bash run-ui.sh [port]`) |
| `config.example.json` | Template config: accounts + agent definitions |
| `compose-*.md` / `reply-*.md` | Per-agent outbound / reply prompts (use `{NAME}`) |
| `triage-system.md` | Decides REPLY / THANK / WAIT / SKIP for an incoming email |
| `extract-system.md` | Pulls pricing rows out of a reply |
| `Pricing_Template.xlsx` | Spreadsheet the Extract tab fills |
| `himalaya-config.sample.toml` | Reference Gmail mail config |

---

## Command-line agent (optional)

`run.sh` does one pass: read unseen mail -> ask Claude for a reply -> **draft** (default) or **send**
(allowlisted senders only). It also processes an outbound `queue.txt`. Set the sending address with
`MAIL_AGENT_FROM=you@gmail.com` (or it derives from your Himalaya config). Schedule it with cron
(macOS/Linux) or Task Scheduler (Windows) for unattended runs. Keep `MODE="draft"` until you've
watched it produce good drafts, then switch to `"send"` and keep the allowlist short.

---

## Safety

- **Draft mode by default** — nothing sends until you choose to.
- **Allowlist-gated sending** — outbound only to addresses you approved.
- **Rate cap** — limits auto-sends per run.
- Untrusted email content is treated as data, never as instructions.

This sends email in your name — start in draft mode, review, and widen slowly.
