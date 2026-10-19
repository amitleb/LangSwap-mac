# LangSwap (Mac)

**Type Hebrew or English without thinking about the keyboard.**
If you type in the wrong keyboard, LangSwap notices after a word or two, rewrites the text in the right language, and switches the keyboard for you. You just keep typing.

```
nv vnmc tjh?                     →  מה המצב אחי?
׳ישא גם טםו ׳שמא כרםצ צק?        →  what do you want from me?
this is great but tbh hfuk kf,uc cgcrh,  →  this is great but אני יכול לכתוב בעברית
```

Small menu-bar app for macOS. Free, open source, runs 100% on your Mac. Nothing is sent anywhere.

## What it does

- **Wrong keyboard → fixed.** Works on a single word (5+ letters) or mid-sentence: only the wrong part is converted, the words before it stay.
- **Typos fixed as you type**, in English and Hebrew (`speling` → `spelling`, `יםה` → `יפה`). Words with capitals (names, brands) are never touched.
- **Cmd+Z** right after a fix = undo. That word is never "fixed" again.
- **Double-tap Shift** = convert the last words by hand. Select text first to convert just the selection.
- **Language badge**: when you click into a text field, a small `EN` / `עב` badge shows the current keyboard.
- **🔒 in the menu bar** = paused, because another app is protecting a password field (macOS hides typing from all apps then).

Uses about 0% CPU and ~60 MB of memory. Each check takes about 1 ms.

## Install

1. Download **LangSwap.zip** from [Releases](../../releases/latest) and unzip it.
2. Drag **LangSwap.app** into **Applications**.
3. macOS will block it the first time, because the app is not from the App Store and not signed with a paid Apple developer account. Fix it once with **one** of these:
   - **Terminal:** paste this line and press Enter
     ```
     xattr -dr com.apple.quarantine /Applications/LangSwap.app
     ```
   - **Or:** try to open the app, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
4. Open LangSwap. You will see **אA** in the menu bar.
5. Allow it in **System Settings → Privacy & Security → Accessibility** (turn LangSwap on). The ⚠︎ next to אA disappears after a few seconds.
6. Click **אA** → **Start at login**.

You need both keyboards enabled: **Hebrew** and **ABC** (or U.S.) in System Settings → Keyboard → Input Sources. macOS 13 or newer, Apple Silicon or Intel.

**Accessibility "is on" but nothing happens?** Select LangSwap in the Accessibility list, remove it with **–**, open the app again and allow it again. macOS ties the permission to the exact app build.

## Why it needs Accessibility

To see what you type and to retype a fix, an app needs Accessibility access. That is the same access any keyboard tool needs. LangSwap keeps only your last few words in memory, never saves them (unless you turn on the debug log yourself), and has no network code. Read `main.swift` to check.

## Build it yourself

Needs Apple's free command-line tools (`xcode-select --install`).

```
git clone https://github.com/amitleb/LangSwap-mac.git
cd LangSwap-mac
./build.sh                       # builds and installs to ~/Applications/LangSwap.app
open ~/Applications/LangSwap.app
```

Tests (no typing, runs the real engine on a fake text field):

```
swiftc -O main.swift -o LangSwapTest -framework AppKit -framework Carbon -framework ServiceManagement
./LangSwapTest --selftest
./LangSwapTest --lists tests/en_common.txt tests/he_common.txt
./LangSwapTest --sim "nv vnmc tjh? " en
```

`./release.sh` builds a universal zip into `dist/`.

### Or let an AI assistant do it

Paste this into Claude (Cowork or Claude Code) or any coding assistant that can run commands on your Mac:

> Clone https://github.com/amitleb/LangSwap-mac, read the README, and build and install LangSwap on my Mac with `./build.sh`. Before building, check that Apple's command-line tools are installed (`xcode-select -p`) and install them if not. Run the self test (`--selftest`) and tell me the result. Then open the app and walk me through allowing it in System Settings → Privacy & Security → Accessibility. Do not change anything else on my Mac.

## Limits (honest)

- It fixes most wrong-keyboard text, not all. Short single words (under 5 letters) wait for the next word. Use double-tap Shift for the rest.
- Typos that form another real word (`form` / `from`) are not caught. Hebrew typo fixing is weaker than English.
- Retyping happens with simulated keys. A few apps (terminals, games, some remote desktops) may handle it badly: use **אA → Disable in <app>**.
- Every new build needs the Accessibility permission again (unsigned app).

## Credits

Word-frequency lists from [FrequencyWords](https://github.com/hermitdave/FrequencyWords) by Hermit Dave, CC BY-SA 4.0 (see `NOTICE.md`). Built with Claude.

## License

MIT for the code (see `LICENSE`). The word lists keep their own license (CC BY-SA 4.0).
