<p align="center">
  <img src="docs/assets/duckclip-mascot.png" width="260" alt="DuckClip mascot holding a clipboard">
</p>

<h1 align="center">D U C K C L I P</h1>

<p align="center"><strong>Copy once. Find anything. Paste anywhere.</strong></p>

<p align="center">
  A private macOS clipboard history and AI agent inbox,<br>
  always one keyboard shortcut away.
</p>

<p align="center">
  <a href="#latest-features">Latest features</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="#quick-paste">Quick Paste</a> ·
  <a href="#the-full-library">Full library</a> ·
  <a href="#agent-inbox">Agent inbox</a> ·
  <a href="#keyboard-shortcuts">Shortcuts</a> ·
  <a href="#privacy">Privacy</a>
</p>

<p align="center">
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white">
  <img alt="Local first" src="https://img.shields.io/badge/data-local--first-20B2AA">
  <img alt="Menu bar app" src="https://img.shields.io/badge/app-menu%20bar-FFD43B">
  <a href="https://github.com/dksung94/duckclip/releases/latest"><img alt="Download latest release" src="https://img.shields.io/github/v/release/dksung94/duckclip?display_name=release&label=download&color=6f42c1"></a>
</p>

---

DuckClip remembers text, links, files, and images you copy. It can also collect finished responses from Claude Code, Codex, Gajae Code, Gemini CLI, GitHub Copilot CLI, Cursor, and OpenCode, keeping the original question beside each answer whenever the agent makes it available.

Use the compact Quick Paste window when you want something recent. Open the full library when you need to search deeper or browse agent conversations.

> DuckClip is an early release. Review the retention and privacy settings before using it with sensitive information.

## Latest features

- Write a follow-up beneath any collected agent response and send it back to the session that is still running.
- Read the original question directly above its answer. Short questions stay compact; longer questions grow naturally and become scrollable only when needed.
- Recover question-and-answer context from existing Codex and Claude history with a one-time local scan.
- Reach the exact local tmux pane even when it is hidden behind another pane, plus cmux, Terminal, and iTerm sessions.
- Press `Return` while the follow-up field is focused to send the reply instead of triggering the clipboard action.
- Keep a Rectangle-managed full-screen or half-screen window size while moving between Clipboard and Agents.
- Leave the full library open while you reference another app. Quick Paste remains lightweight and disappears when it loses focus.
- Open Quick Paste only with `⌃⌘V`; opening the regular library never brings up the compact panel.

## Quick Paste

<p align="center">
  <img src="docs/assets/duckclip-quick-paste.png" width="560" alt="DuckClip Quick Paste showing recent clipboard items with Command-number shortcuts">
</p>

Press `⌃⌘V` to open a lightweight list of your nine most recent clipboard items.

- Press `⌘1` through `⌘9` to paste an item immediately.
- Type to search the recent list.
- Use `↑` and `↓`, then press `Return`.
- Recognize text, URLs, images, and files by their icons, thumbnails, and source apps.
- See the destination app before anything is pasted.

Quick Paste closes as soon as the item is sent, so you can stay focused on the app you were already using.
Clicking another app also dismisses Quick Paste without closing DuckClip itself.

## The full library

<p align="center">
  <img src="docs/assets/duckclip-demo.png" width="1080" alt="DuckClip agent library showing agents, conversations, and response details in three columns">
</p>

Press `⇧⌘V` when you need the complete DuckClip library.

- Search across clipboard history and agent responses.
- Filter by source and project.
- See the question that produced an agent answer without opening the original terminal session.
- Reply directly to the terminal tab that is still running an agent conversation.
- Pin important items above the regular timeline.
- Preview screenshots with their dimensions and file size.
- Preview URLs and copied files before using them.
- Copy an item again or paste it back into the app you came from.
- Keep the library visible while working in another app.

The clipboard view uses a simple list and preview. The Agents view uses three clear steps: **agent → conversation → response**. Conversation rows use the original question as their title when available. The response preview places that question in a compact, adaptive card above the answer, while agent answers preserve Markdown headings, paragraphs, and lists.

## Why DuckClip?

| When this happens | DuckClip helps by |
| --- | --- |
| A recent copy is replaced before you paste it | Keeping a searchable history, with pinned items at the top |
| Screenshots all look alike | Showing thumbnails, dimensions, file size, and source app |
| Coding-agent answers are spread across tools and sessions | Organizing them as agent → conversation → response |
| An old agent answer no longer makes sense by itself | Keeping the original question and answer together |
| You only need the thing you copied a moment ago | Letting you paste it with `⌘1` through `⌘9` in Quick Paste |
| An agent finishes or needs your attention | Sending optional completion, input, approval, and failure notifications |
| You need to reference another app while reading an answer | Keeping the full library visible until you close it |
| You are unsure where an item will go | Naming the destination app before paste |

## Get started

DuckClip supports macOS 14 or newer.

1. Download the latest `DuckClip-*.dmg` from [GitHub Releases](https://github.com/dksung94/duckclip/releases/latest).
2. Open the DMG and drag DuckClip into Applications.
3. Launch DuckClip, then keep the duck icon in your menu bar.

DuckClip 0.2 is ad-hoc signed but not Apple-notarized. macOS may block its first launch. Open **System Settings → Privacy & Security**, choose **Open Anyway** beside DuckClip, then confirm **Open**. You only need to do this again after installing a newly built release.

DuckClip appears as a duck in the menu bar and does not take up space in the Dock. The first-run guide explains local storage and the default shortcuts.

Automatic paste needs macOS Accessibility permission. DuckClip asks for it only when you enable or use a feature that pastes on your behalf. You can still copy an item without granting that permission.

## What DuckClip remembers

- Text and URLs
- Files copied from Finder
- Screenshots and other clipboard images
- Final responses from Claude Code, Codex, Gajae Code, Gemini CLI, GitHub Copilot CLI, Cursor, and OpenCode
- The user question behind an agent response when the integration or local session history exposes it
- The project, agent, and session information attached to those responses

Unpinned items can be kept for 1 to 365 days. You choose the retention period in Settings.

## Agent inbox

To connect your coding agents:

1. Open **Settings → Agents → Connections**.
2. Select **Install or Update Integrations**.
3. Restart any agent that was already open.
4. Use the **Test** button beside each provider to confirm that events are arriving.

The same setup flow connects Claude Code, Codex, Gajae Code, Gemini CLI, GitHub Copilot CLI, Cursor, and OpenCode. Installing or updating a DuckClip connection preserves your existing agent settings and only changes entries owned by DuckClip.

Select any collected response to see its original question above the answer and write a follow-up below it. The question card uses only the space its text needs, up to a comfortable scrollable limit. **Send to Session** finds the process that still owns the matching session file and sends your prompt to that exact local tmux pane, cmux, Terminal, or iTerm surface. A tmux pane does not need to be visible or selected. DuckClip never starts a second writer for an active session, and it stops safely if the original session is no longer running.

Live replies currently target sessions running on the same Mac as DuckClip. Sessions inside tmux on an SSH server need a remote bridge and are not supported yet.

If Codex asks whether a new hook should be trusted, run `/hooks` in Codex and review it there. Event coverage differs by agent version, so some providers may report completed responses but not every approval or input request.

### Notifications

Open **Settings → Agents → Notifications** to choose exactly which events should interrupt you.

| Notification | What it means |
| --- | --- |
| Response completed | A connected coding agent finished a response |
| Waiting for your input | The agent needs a choice or more information |
| Approval required | A tool or permission is waiting for approval |
| Agent failed | The agent stopped because of an error |

Notification previews can show status only, the first line of a response, or no response content. Each notification type has its own test action. Available events can vary with the installed agent version.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⇧⌘V` | Open the full DuckClip library |
| `⌃⌘V` | Open Quick Paste |
| `⌘1` … `⌘9` | Paste the matching Quick Paste item immediately |
| `↑` `↓` | Move through items |
| `Return` | Paste or copy the selected item |
| `Return` in the follow-up field | Send the reply to the running agent session |
| `⌘C` | Copy the selected item |
| `Delete` | Delete the selected item |
| `⌘Z` | Undo the most recent deletion |
| `Esc` | Close the current palette |

The full-library shortcut can be changed to `⇧⌘V`, `⌥⌘V`, or `⌃⌥V` in Settings. Quick Paste uses `⌃⌘V`. If macOS or another app has already claimed a shortcut, DuckClip shows the conflict in the menu bar and Settings.

## Privacy

DuckClip is local-first. There is no cloud account or clipboard sync, and its data stays in `~/Library/Application Support/DuckClip`.

- Password-manager and protected or temporary pasteboard content is not recorded by default.
- You can exclude specific applications from clipboard recording.
- You can exclude project folders and their descendants from agent response collection.
- Accessibility permission is used only for automatic paste and Quick Paste.
- Notification permission is requested only when you turn on agent notifications.
- Pausing clipboard recording is always available from the menu bar.

---

<p align="center"><strong>Your clipboard has a better memory now. 🦆</strong></p>
