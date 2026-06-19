# Zerro — a high-level overview

Thanks for helping us test Zerro. This is a quick, non-technical tour of what
the app does and how the two modes feel to use. It's deliberately light on
implementation detail — the goal is just to give you a clear mental model
before you start poking at it.

## The one-line version

Zerro is a macOS app that lets you **talk to your screen**. You hit a hotkey,
drag to frame any region of your display, narrate what you want while pointing
at things on screen, and stop. Zerro turns that recording into the right
finished output for the job. Everything heavy happens on your machine first;
recordings cap at about three minutes.

The whole product is built around one motion: **frame it, talk it through, stop.**

## Artifact Mode (the default)

Artifact Mode is the everyday way to use Zerro. You record yourself explaining
or pointing at something, and Zerro decides what kind of output you actually
need and produces it for you, ready to use.

Instead of giving you one fixed format, it produces one of several **typed
artifacts** depending on what you were doing:

- **Agent prompt** — a precise, ready-to-paste instruction for an AI coding
  agent (e.g. Cursor). Great for "here's the bug, here's the fix I want."
- **Message** — a drafted note or email, in the right tone, ready to send.
- **Snippet** — an exact piece of text or code to drop in somewhere.
- **Document** — longer prose: a write-up, summary, or explanation.

You record once, Zerro picks the artifact type that fits, and the result lands
on your clipboard ready to drop into Cursor, your inbox, a spreadsheet, or
wherever it's headed. The core idea is that the output writes itself from your
real recording — you don't fill out a form or pick a template up front.

## Dev Mode

Dev Mode is the more ambitious mode, aimed squarely at developers. The target
experience is: **talk → stop → watch your site change.**

You point Zerro at your app running locally (typically `localhost`), record the
region, and narrate the changes you want out loud — "make this header sticky,
change this button to teal." When you stop, instead of handing you something to
paste, Zerro turns your narration into a precise, repo-scoped coding
instruction and hands it directly to **your own coding agent** (Claude Code,
Codex, or Cursor) running against your project. The agent edits the real files
on disk, your dev server hot-reloads, and you watch the change appear — without
touching the keyboard.

A few things worth knowing as a tester:

- **Zerro is the eyes; your agent is the hands.** Zerro's job is to understand
  what you saw and said and turn it into a clear spec. Your agent's job is to
  find the files and make the edit. Zerro never drives your browser or editor
  directly.
- **It uses the agent you already have.** Dev Mode runs your existing CLI coding
  agent under your own subscription/login. You'll need to have logged into your
  chosen agent once, outside Zerro. The recording-to-instruction step uses
  Zerro's own model; the actual code edits run on your agent.
- **You bind it to a folder.** You explicitly pick which project folder Zerro is
  allowed to edit — it never guesses. That folder is remembered.
- **Pointing matters.** A lot of the magic is that you can literally point your
  cursor at things while you talk ("make *this* bigger") and Zerro resolves what
  you meant to the actual on-screen element.
- **There's a safety net.** Before the agent touches anything, Zerro takes a
  checkpoint of your project's current state, so any run is **one-click
  revertible** back to exactly where you were — including uncommitted work. If
  Zerro isn't confident about what you pointed at, it pauses and asks you to
  confirm rather than guessing.
- **You see what happened.** When the run finishes, Zerro shows you how many
  files changed, with options to revert or keep.

## How to think about the difference

Artifact Mode hands *you* a finished thing to use however you like. Dev Mode
skips the paste step entirely and applies the change to your codebase for you,
using your own agent, with an undo button.

## What we'd love feedback on

- Does the record → talk → stop flow feel natural, or fiddly?
- In Artifact Mode: does Zerro pick the *right* artifact type for what you were
  doing, and is the output actually usable as-is?
- In Dev Mode: does pointing-while-talking resolve to the right elements? Does
  the resulting change match what you asked for? Did revert work cleanly when
  you needed it?
- Anything that felt slow, confusing, or surprising.

Thanks again — fire any and all thoughts our way.
