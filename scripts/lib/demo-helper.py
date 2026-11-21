#!/usr/bin/env python3
"""Helpers for scripts/dev-demo.sh (screenshot environment).

Two subcommands:

  transcripts <home>
      Writes the sample conversations under <home>/.claude/projects/ in the
      transcript line format crates/shiibar-cc/src/conversations/transcript.rs
      parses, and sets each file's mtime (the History listing's updated_at
      is the file mtime, conversations/mod.rs `sweep`).

  placeholder --root R --name N --cli PATH --session S [--end none|stop|permission]
      Starts a long-lived stand-in for one `claude` process and replays that
      session's hook reports from it. The hook (`shiibar-cc report`) walks its
      process ancestry and reports the pid of the first process with a
      controlling terminal (DESIGN.md §4.1), and the daemon ignores a report
      with a different session_id from a pid it already tracks (§3.6). So
      every demo session needs its own process that owns a terminal and
      stays alive: here a pty child, which runs each report in a new session
      (no controlling terminal), making the walk stop at the pty child.

Everything printed or stored here is fictional sample data.
"""

import json
import os
import pty
import signal
import subprocess
import sys
import time
import uuid

# --------------------------------------------------------------------------
# Sample data
# --------------------------------------------------------------------------

P = "/Users/example/projects"

# Running rows (dev-demo.sh stage / banner) reuse these session ids, so
# selecting a Running row shows the matching sample conversation.
SID_WORK = "6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f01"
SID_IDLE = "6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f02"
SID_WAIT = "6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f03"
SID_BANNER = "6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f04"

MIN = 60
HOUR = 60 * MIN
DAY = 24 * HOUR

# Each conversation has a session id and a cwd. It also has a title, an age
# in seconds (now - mtime) and the turns. A turn is ("user", text),
# ("assistant", text), or ("tool", name, input, result) for an assistant
# tool_use line followed by the user tool_result line. The conversation pane shows only human
# utterances and assistant text (DESIGN.md §4.6), so tool turns are there
# to make the files look like real transcripts.
CONVERSATIONS = [
    {
        "sid": SID_WORK,
        "cwd": f"{P}/blog",
        "title": "Draft a post about the new release pipeline",
        "age": 0,
        "turns": [
            ("user", "Draft a post about the new release pipeline. Audience: readers who "
                     "followed the old manual process. Keep it under 800 words."),
            ("tool", "Read", {"file_path": f"{P}/blog/notes/release-pipeline.md"},
             "- tag push triggers the build\n- artifacts signed in CI\n- draft release created automatically"),
            ("assistant", "I read your notes. Here is the outline I'm going to follow:\n\n"
                          "1. **Why we changed it** - the manual steps that kept going wrong\n"
                          "2. **What happens now** - tag push, CI build, signed artifacts, draft release\n"
                          "3. **What you need to do** - nothing, unless you publish releases\n"
                          "4. **Rollback** - how a bad release is pulled\n\n"
                          "I'll write the draft into `posts/2026-11-release-pipeline.md`."),
            ("user", "Sounds good. Mention that the changelog is generated from commit titles."),
        ],
    },
    {
        "sid": SID_IDLE,
        "cwd": f"{P}/dotfiles",
        "title": "Clean up the zsh aliases",
        "age": 3 * MIN,
        "turns": [
            ("user", "Clean up the zsh aliases. Remove anything that points at tools I no longer have installed."),
            ("tool", "Bash", {"command": "grep -c '^alias' zsh/aliases.zsh"}, "47"),
            ("assistant", "There are 47 aliases. 12 of them call commands that are not on your PATH:\n\n"
                          "- `dc`, `dcu`, `dcd` (docker-compose v1)\n"
                          "- `hs`, `hss` (an old static site generator)\n"
                          "- 7 aliases for a VPN client\n\n"
                          "Should I remove all 12?"),
            ("user", "Yes, remove them all."),
            ("tool", "Edit", {"file_path": f"{P}/dotfiles/zsh/aliases.zsh"}, "The file has been updated."),
            ("assistant", "Done - removed 12 stale aliases. `zsh -n zsh/aliases.zsh` reports no syntax errors."),
        ],
    },
    {
        "sid": SID_WAIT,
        "cwd": f"{P}/weather-cli",
        "title": "Run the release checklist",
        "age": 1 * MIN,
        "turns": [
            ("user", "Run the release checklist for 1.4.0."),
            ("assistant", "Working through `RELEASING.md`:\n\n"
                          "- [x] version bumped in `Cargo.toml`\n"
                          "- [x] changelog entry present\n"
                          "- [ ] tests pass\n"
                          "- [ ] tag pushed\n\n"
                          "Next I'll run the full test suite."),
            ("tool", "Bash", {"command": "cargo test --all-features"}, ""),
        ],
    },
    {
        "sid": SID_BANNER,
        "cwd": f"{P}/recipe-app",
        "title": "Write release notes for v2.3",
        "age": 10 * MIN,
        "turns": [
            ("user", "Write release notes for v2.3 from the merged pull requests since v2.2."),
            ("tool", "Bash", {"command": "git log --oneline v2.2..HEAD"},
             "a1b2c3d Add pagination to the recipes API\n9f8e7d6 Compress uploaded images\n5c4b3a2 Fix date parsing in imports"),
            ("assistant", "## v2.3\n\n"
                          "### Added\n- Pagination for `GET /recipes` (`?page=` and `?per_page=`)\n\n"
                          "### Changed\n- Uploaded images are compressed before storage\n\n"
                          "### Fixed\n- Dates in imported CSV files are parsed in the user's time zone"),
            ("user", "Looks good. Add it to CHANGELOG.md."),
            ("tool", "Edit", {"file_path": f"{P}/recipe-app/CHANGELOG.md"}, "The file has been updated."),
            ("assistant", "The v2.3 release notes are in CHANGELOG.md: one addition, one change and one fix since v2.2."),
        ],
    },
    {
        "sid": "6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f05",
        "cwd": f"{P}/recipe-app",
        "title": "Add pagination to the recipes API",
        "age": 25 * MIN,
        "turns": [
            ("user", "Add pagination to GET /recipes. It currently returns every row."),
            ("tool", "Read", {"file_path": f"{P}/recipe-app/src/routes/recipes.ts"},
             "router.get('/recipes', async (req, res) => {\n  res.json(await db.recipe.findMany());\n});"),
            ("assistant", "The handler loads the whole table. I'd add `page` and `per_page` query "
                          "parameters with a cap, and return the total so the client can render page links:\n\n"
                          "```ts\n"
                          "router.get('/recipes', async (req, res) => {\n"
                          "  const page = Math.max(1, Number(req.query.page) || 1);\n"
                          "  const perPage = Math.min(100, Number(req.query.per_page) || 20);\n"
                          "  const [items, total] = await Promise.all([\n"
                          "    db.recipe.findMany({ skip: (page - 1) * perPage, take: perPage, orderBy: { id: 'asc' } }),\n"
                          "    db.recipe.count(),\n"
                          "  ]);\n"
                          "  res.json({ items, total, page, perPage });\n"
                          "});\n"
                          "```\n\n"
                          "This changes the response shape from an array to an object, so the frontend "
                          "list view needs a matching update."),
            ("user", "Go ahead, and update the frontend too."),
            ("tool", "Edit", {"file_path": f"{P}/recipe-app/src/routes/recipes.ts"}, "The file has been updated."),
            ("tool", "Edit", {"file_path": f"{P}/recipe-app/web/src/RecipeList.tsx"}, "The file has been updated."),
            ("tool", "Bash", {"command": "npm test"}, "Tests: 42 passed, 42 total"),
            ("assistant", "Both sides are updated and all 42 tests pass. Summary:\n\n"
                          "- `GET /recipes` accepts `page` (default 1) and `per_page` (default 20, max 100)\n"
                          "- the response is `{ items, total, page, perPage }`\n"
                          "- `RecipeList` shows previous / next buttons and the page count"),
            ("user", "Thanks. Does the order stay stable when two recipes have the same title?"),
            ("assistant", "Yes. The query orders by `id`, which is unique, so a page never repeats "
                          "or skips a row even when titles collide."),
        ],
    },
    {
        "sid": "6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f06",
        "cwd": f"{P}/weather-cli",
        "title": "Fix the flaky retry test",
        "age": 2 * HOUR,
        "turns": [
            ("user", "test_retry_backoff fails about one run in ten on CI. Can you find out why?"),
            ("tool", "Read", {"file_path": f"{P}/weather-cli/tests/retry.rs"},
             "let start = Instant::now();\nclient.fetch().await.unwrap_err();\nassert!(start.elapsed() >= Duration::from_millis(300));"),
            ("assistant", "The test measures wall-clock time around real sleeps. On a busy CI runner the "
                          "timer can fire a little early relative to `Instant`, so the `>= 300ms` "
                          "assertion occasionally fails.\n\n"
                          "A sturdier approach is to pause Tokio's clock and advance it manually, so "
                          "the test checks the backoff schedule instead of the machine's timing."),
            ("user", "Do that."),
            ("tool", "Edit", {"file_path": f"{P}/weather-cli/tests/retry.rs"}, "The file has been updated."),
            ("tool", "Bash", {"command": "for i in $(seq 50); do cargo test -q retry || break; done"}, "50 runs, 0 failures"),
            ("assistant", "The test now uses `tokio::time::pause()` and checks the three backoff delays "
                          "(100ms, 200ms, 400ms) directly. 50 consecutive runs passed."),
        ],
    },
    {
        "sid": "6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f07",
        "cwd": f"{P}/blog",
        "title": "Set up RSS feed generation",
        "age": 5 * HOUR,
        "turns": [
            ("user", "Generate an RSS feed for the blog at build time."),
            ("assistant", "I'll add a build step that reads the front matter of every post and writes "
                          "`public/feed.xml`. A few questions first:\n\n"
                          "1. Full post content or summaries only?\n"
                          "2. How many items?\n"
                          "3. Should drafts be excluded? (I'd assume yes)"),
            ("user", "Summaries, the latest 20, and yes, exclude drafts."),
            ("tool", "Write", {"file_path": f"{P}/blog/scripts/build-feed.mjs"}, "File created successfully."),
            ("assistant", "Added `scripts/build-feed.mjs` and hooked it into `npm run build`. The feed "
                          "validates with the W3C validator's rules for required channel and item fields."),
        ],
    },
    {
        "sid": "6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f08",
        "cwd": f"{P}/dotfiles",
        "title": "Migrate the Neovim config to Lua",
        "age": 26 * HOUR,
        "turns": [
            ("user", "Convert my init.vim to init.lua. Keep the behavior the same."),
            ("tool", "Read", {"file_path": f"{P}/dotfiles/nvim/init.vim"}, "set number\nset expandtab\nnnoremap <leader>w :w<CR>"),
            ("assistant", "Here is how the main pieces translate:\n\n"
                          "| Vimscript | Lua |\n"
                          "| --- | --- |\n"
                          "| `set number` | `vim.opt.number = true` |\n"
                          "| `set expandtab` | `vim.opt.expandtab = true` |\n"
                          "| `nnoremap <leader>w :w<CR>` | `vim.keymap.set('n', '<leader>w', '<cmd>w<cr>')` |\n\n"
                          "I'll split the result into `options.lua`, `keymaps.lua` and `plugins.lua`."),
            ("user", "Splitting is fine."),
            ("tool", "Write", {"file_path": f"{P}/dotfiles/nvim/init.lua"}, "File created successfully."),
            ("assistant", "Done. `nvim --headless +qa` starts without errors, and the old `init.vim` is "
                          "kept as `init.vim.bak` until you're happy with the new setup."),
        ],
    },
    {
        "sid": "6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f09",
        "cwd": f"{P}/recipe-app",
        "title": "Investigate slow image uploads",
        "age": 2 * DAY + 3 * HOUR,
        "turns": [
            ("user", "Uploading a photo takes 8 seconds on the staging server. Where does the time go?"),
            ("tool", "Bash", {"command": "grep -n 'upload' logs/staging.log | tail -5"},
             "upload received 4.1MB in 0.6s\nresize done in 6.9s\nstored in 0.4s"),
            ("assistant", "Almost all of it is the resize step: 6.9 of roughly 8 seconds. The resizer "
                          "decodes the full-resolution image and runs three resize passes one after another.\n\n"
                          "Options, cheapest first:\n\n"
                          "- resize from the largest output size down, instead of from the original each time\n"
                          "- run the three sizes in parallel\n"
                          "- move resizing to a background job and show a placeholder"),
            ("user", "Let's try the first two."),
            ("assistant", "With both changes the resize step takes 1.8 seconds on the same photo, and "
                          "the output images are byte-identical in size to before."),
        ],
    },
    {
        "sid": "6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f10",
        "cwd": f"{P}/scripts",
        "title": "Write a backup script with rsync",
        "age": 4 * DAY + 5 * HOUR,
        "turns": [
            ("user", "Write a script that backs up ~/Documents to the external drive with rsync, "
                     "keeping the last 7 daily snapshots."),
            ("assistant", "I'll use `--link-dest` so unchanged files are hard links to the previous "
                          "snapshot and each snapshot only costs the space of what changed:\n\n"
                          "```sh\n"
                          "#!/bin/sh\n"
                          "set -eu\n"
                          "dest=/Volumes/Backup/documents\n"
                          "today=$(date +%Y-%m-%d)\n"
                          "rsync -a --delete --link-dest=\"$dest/latest\" \"$HOME/Documents/\" \"$dest/$today/\"\n"
                          "ln -sfn \"$dest/$today\" \"$dest/latest\"\n"
                          "ls -1d \"$dest\"/20* | head -n -7 | xargs rm -rf\n"
                          "```"),
            ("user", "head -n -7 doesn't work on macOS."),
            ("assistant", "Right, BSD `head` has no negative counts. Replace the last line with:\n\n"
                          "```sh\n"
                          "ls -1d \"$dest\"/20* | sort -r | tail -n +8 | xargs rm -rf\n"
                          "```\n\n"
                          "That sorts newest first and removes everything after the seventh entry."),
        ],
    },
]


def slug_for(cwd):
    # Claude Code names the project folder after the cwd with "/" replaced
    # by "-"; the indexer only needs one directory level, any name works.
    return cwd.replace("/", "-")


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(ts))


def write_transcripts(home):
    now = time.time()
    root = os.path.join(home, ".claude", "projects")
    for conv in CONVERSATIONS:
        folder = os.path.join(root, slug_for(conv["cwd"]))
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, conv["sid"] + ".jsonl")
        end = now - conv["age"]
        lines = transcript_lines(conv, end)
        with open(path, "w", encoding="utf-8") as f:
            for line in lines:
                f.write(json.dumps(line, ensure_ascii=False) + "\n")
        os.utime(path, (end, end))


def transcript_lines(conv, end):
    sid, cwd = conv["sid"], conv["cwd"]
    # One line per utterance node, spaced 20s apart, ending at `end`.
    nodes = []
    for turn in conv["turns"]:
        if turn[0] == "tool":
            nodes.extend([("tool_use", turn), ("tool_result", turn)])
        else:
            nodes.append((turn[0], turn))
    step = 20
    t = end - step * (len(nodes) - 1)
    parent = None
    out = []
    tool_id = None
    for kind, turn in nodes:
        node_uuid = str(uuid.uuid4())
        base = {
            "parentUuid": parent,
            "isSidechain": False,
            "cwd": cwd,
            "sessionId": sid,
            "uuid": node_uuid,
            "timestamp": iso(t),
        }
        if kind == "user":
            base.update(type="user", message={"role": "user", "content": turn[1]})
        elif kind == "assistant":
            base.update(type="assistant", message={
                "role": "assistant", "type": "message",
                "content": [{"type": "text", "text": turn[1]}],
            })
        elif kind == "tool_use":
            tool_id = "toolu_" + uuid.uuid4().hex[:24]
            base.update(type="assistant", message={
                "role": "assistant", "type": "message",
                "content": [{"type": "tool_use", "id": tool_id, "name": turn[1], "input": turn[2]}],
            })
        else:
            base.update(type="user", message={"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": tool_id, "content": turn[3]},
            ]})
        out.append(base)
        parent = node_uuid
        t += step
    out.append({"type": "ai-title", "aiTitle": conv["title"], "sessionId": sid})
    return out


# --------------------------------------------------------------------------
# Placeholder sessions
# --------------------------------------------------------------------------


def conversation(sid):
    for conv in CONVERSATIONS:
        if conv["sid"] == sid:
            return conv
    raise SystemExit(f"demo-helper: unknown session {sid}")


def hook_payloads(conv, end, home):
    sid, cwd = conv["sid"], conv["cwd"]
    transcript = os.path.join(home, ".claude", "projects", slug_for(cwd), sid + ".jsonl")
    common = {"session_id": sid, "transcript_path": transcript, "cwd": cwd}
    prompts = [t[1] for t in conv["turns"] if t[0] == "user"]
    replies = [t[1] for t in conv["turns"] if t[0] == "assistant"]
    out = [
        ("SessionStart", {**common, "hook_event_name": "SessionStart", "source": "startup"}),
        ("UserPromptSubmit", {**common, "hook_event_name": "UserPromptSubmit", "prompt": prompts[-1]}),
    ]
    if end == "stop":
        out.append(("Stop", {**common, "hook_event_name": "Stop", "stop_hook_active": False,
                             "last_assistant_message": replies[-1], "background_tasks": []}))
    elif end == "permission":
        out.append(("Notification", {**common, "hook_event_name": "Notification",
                                     "message": "Claude needs your permission to use Bash",
                                     "notification_type": "permission_prompt"}))
    return out


def run_placeholder(args):
    opts = {}
    it = iter(args)
    for key in it:
        opts[key.lstrip("-")] = next(it)
    root, name, cli, sid = opts["root"], opts["name"], opts["cli"], opts["session"]
    end = opts.get("end", "none")
    home = os.path.join(root, "home")
    run_dir = os.path.join(root, "run")
    ready = os.path.join(run_dir, name + ".ready")
    log_path = os.path.join(run_dir, name + ".log")
    reports = hook_payloads(conversation(sid), end, home)

    # Detach from the caller's session and terminal, so closing the
    # terminal that ran dev-demo.sh does not hang the placeholder up.
    if os.fork() > 0:
        os._exit(0)
    os.setsid()

    pid, master = pty.fork()
    if pid == 0:
        # The pty child: a session leader whose controlling terminal is the
        # pty slave. It stands in for the `claude` process.
        with open(log_path, "a") as log:
            for event, payload in reports:
                # start_new_session drops the controlling terminal, so the
                # report's ancestor walk stops at this process.
                subprocess.run([cli, "report", event], input=json.dumps(payload).encode(),
                               stdout=subprocess.DEVNULL, stderr=log, stdin=None,
                               start_new_session=True, check=False)
        with open(ready, "w") as f:
            f.write(f"{os.getpid()}\n")
        while True:
            signal.pause()

    # The parent keeps the pty master open (closing it hangs up the child)
    # and drains it until the child exits.
    signal.signal(signal.SIGTERM, lambda *_: (os.kill(pid, signal.SIGTERM), os._exit(0)))
    try:
        while os.read(master, 1024):
            pass
    except OSError:
        pass
    os.waitpid(pid, 0)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "transcripts":
        write_transcripts(sys.argv[2])
    elif len(sys.argv) >= 2 and sys.argv[1] == "placeholder":
        run_placeholder(sys.argv[2:])
    else:
        sys.exit("usage: demo-helper.py transcripts <home> | placeholder --root R --name N "
                 "--cli PATH --session S [--end none|stop|permission]")


if __name__ == "__main__":
    main()
