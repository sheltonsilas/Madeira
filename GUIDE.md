# GUIDE.md — getting Madeira onto your iPad from a Windows laptop

Written for someone who has never sideloaded an app before. It covers both
variants, because they install the same way.

> **Read this first, it will save you an hour.** Two things on iOS are not
> optional and cannot be bought or worked around:
>
> 1. **JIT needs an app that is installed "debuggable".** Apple only lets an app
>    create executable memory while a debugger is attached. StikDebug (or the
>    app's own built-in helper) attaches that debugger. Without it the app
>    installs and opens, but **no guest session will start**: this build of FEX
>    is compiled with only the ARM64 JIT core, so there is no interpreter to
>    fall back to. The "Interpreter only" setting records your choice and then
>    says so plainly instead of failing silently.
> 2. **A free Apple ID expires after 7 days.** See the last section, which is
>    the part most people get wrong.

---

## 1. Get the IPA onto your Windows laptop

The IPA is a build artifact. Get it from the GitHub Actions run:

1. Open the fork: <https://github.com/sheltonsilas/Madeira>
2. Open the **Actions** tab.
3. Open the most recent run of **build**.
4. At the bottom, under **Artifacts**, download `Madeira-windows-ipa` (or
   `Madeira-linux-ipa`).
5. Windows will save a `.zip`. **Right-click it → Extract All.** Inside is the
   `.ipa`. Do not try to sign the zip.

If you would rather not use Actions, every run also publishes a Release, so the
IPAs are one click away:

<https://github.com/sheltonsilas/Madeira/releases/latest>

That "latest" link always means the newest build — each run publishes its own
`build-<run number>` release, so the URL never goes stale. Both variants are
there as `Madeira-windows-unsigned.ipa` and `Madeira-linux-unsigned.ipa`.

## 2. Install Sideloadly (easiest) on Windows

Sideloadly is a single Windows program, needs no iTunes and no iCloud.

1. Download from <https://sideloadly.io> and unzip it.
2. **Plug your iPad into the Windows laptop with a USB cable.** Trust the
   computer when the iPad asks.
3. Run `Sideloadly.exe`.
4. Fill in:
   - **Your Apple ID** — the email and password of the Apple ID you want to
     sign with. Sideloadly uses it only to request a signing certificate from
     Apple. **Prefer a separate, throwaway Apple ID** so a mistake cannot lock
     your main account. See the last section.
   - **Your iPad** — pick it from the device dropdown.
   - **IPA file** — the `.ipa` you extracted in step 1.
5. Click **Start**. It may ask to log in to Apple with a special code; type the
   code it shows. That is Apple's two-step flow.
6. Wait. It says **Done** when the app appears on your iPad's Home Screen.

**Sideloadly settings that matter here:**

- Leave **Remove limitation on 3 app limit** enabled if you see it.
- If Sideloadly offers to keep app extensions, **accept**. Madeira ships a JIT
  helper *app extension*; a sideloader that drops extensions leaves the app
  unable to enable JIT, and it will tell you so.

### Alternative: SideStore

SideStore is a third-party app store that lives on the device and refreshes apps
over Wi-Fi, so you never re-sign every week.

1. Install SideStore on the iPad from its official AltStore source.
2. In SideStore's settings, import your pairing file and enable JIT on your own
   apps (it has this built in).
3. Add the IPA by URL or file.

Or skip the manual step entirely: add Madeira's own SideStore source and
SideStore installs **both** variants and re-signs them for you each week,
without you ever downloading an IPA by hand:

<https://github.com/sheltonsilas/Madeira/releases/latest/download/source.json>

That source carries both variants, their icons and their JIT entitlements.

SideStore is the better long-term choice because it handles the weekly refresh
for you. Sideloadly is the faster first try.

## 3. Turn on Developer Mode on the iPad

Sideloaded apps need Developer Mode:

1. **Settings → Privacy & Security → Developer Mode** → turn on.
2. The iPad asks you to restart. **Restart it.**
3. After the restart, a message appears: *"Developer Mode is now turned on. Are
   you sure you want to turn it on?"* → tap **Turn On** → enter your passcode.

If you do not see **Developer Mode** in Settings, see the troubleshooting table
at the end.

## 4. Turn on JIT

This is the step people skip, and then wonder why everything is slow.

### The easy path: the app's own built-in helper

Madeira has a built-in StikJIT helper, so you do not need StikDebug installed.

1. Install and open **LocalDevVPN** from the App Store.
2. In Madeira: **Settings → JIT → JIT setup → Enable JIT**.
3. The app checks the loopback, downloads and mounts a Developer Disk Image if
   needed, and attaches its helper.

You must be **on Wi-Fi** (or in Airplane Mode). **It will not work on cellular
data** — the tunnel that carries the connection does not route cellular.

### The StikDebug path

If the built-in helper fails, use the standalone app. It gives better error
messages and is the path the developers document.

1. Install **StikDebug**. It is no longer on the App Store; get the IPA from
   <https://github.com/StikDebug/StikDebug/releases/latest> and sideload it the
   same way as Madeira.
2. **Create a pairing file** for your iPad from your Windows laptop. This is the
   fiddly part:
   - Follow the maintained guide:
     <https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md>
   - The short version: with the iPad plugged in over USB, run `idevicepair`
     (from [libimobiledevice](https://libimobiledevice.org/)) to generate the
     record, then `idevicepair validate`.
   - The result is a file with a `.plist` extension. Keep it somewhere safe; it
     is a credential for your device.
3. Import the pairing file into StikDebug.
4. Open LocalDevVPN and connect it. **Wi-Fi or Airplane Mode, not cellular.**
5. Open StikDebug. It lists sideloaded apps that carry the `get-task-allow`
   entitlement. **Force-close StikDebug and reopen it** — this is what mounts the
   Developer Disk Image.
6. Select Madeira and enable JIT.
7. Switch back to Madeira. It should show JIT as ready.

### If JIT will not come on

| Symptom | What it means | Fix |
|---|---|---|
| The app is not listed in StikDebug | It was not signed debuggable | Re-sign, and make sure the entitlements are kept |
| "early eof" / cannot reach device | LocalDevVPN is not routing | Turn off cellular data, or use Airplane Mode. Madeira has a Settings option to automate this with a Shortcuts shortcut |
| "stale Developer Disk Image" | iOS updated | Reset the DDI in Settings → JIT → JIT setup, then check setup again |
| "Failed to add observer" | The JIT helper extension was dropped at install time | Re-install and tell the sideloader to keep app extensions |

## 5. First run

**Madeira Windows** boots the Wine prefix and opens the browser. From there,
download a `.exe` or `.msi`, tap **Install** on the download card, and it runs in
the prefix. Installed programs appear in the Apps screen.

**Madeira Linux** opens the environment manager. Be aware that **no guest can be
launched from it yet** — see the honest limitations in the repository README of
this fork.

## 6. The free Apple ID limits — read this honestly

If you signed with a **free** Apple ID:

| Limit | Consequence for Madeira |
|---|---|
| **7-day expiry** | The app stops launching after 7 days. You must re-sign every 7 days, or use SideStore, which does it for you over Wi-Fi. **This is the single biggest annoyance.** |
| **3 apps** | Madeira + StikDebug + LocalDevVPN is 3. Anything more and signing fails. If you are near the limit, delete unused sideloaded apps. |
| **3 apps per 7 days** | Re-signing counts against a rolling quota. |
| **No `increased-memory-limit` entitlement** | Madeira normally asks for a larger memory limit. A free Apple ID cannot grant it, so you will run with a lower ceiling. Large games and the Linux workarounds will suffer first. |
| **App groups / some entitlements stripped** | Sideloading rewrites some entitlements. This is the most common reason JIT does not come on. |

### Mitigations, best first

1. **Use SideStore.** It re-signs automatically on Wi-Fi and removes the 7-day
   treadmill entirely. This is the fix for the main problem.
2. **Use a paid Apple ID ($9.99/year).** This removes the 7-day expiry and the
   3-app limit, and lets the memory-limit entitlement be granted. For an app
   that needs to create executable memory and run a virtual machine, this is the
   honest recommendation.
3. **Use a separate free Apple ID just for sideloading**, so the quota pressure
   and the expiry do not affect your everyday device, and so a mistake cannot
   lock your real account.
4. **Turn off auto-updates to iPadOS betas.** A major iOS update can invalidate
   the Developer Disk Image and stop JIT until it is re-fetched.

## Troubleshooting

| Problem | Fix |
|---|---|
| No **Developer Mode** in Settings | You are on iPadOS 16 or earlier, or you have never accepted a prompt. Sideload once, then look again |
| Sideloadly says the device is not trusted | Unplug and replug, tap **Trust** on the iPad, and unlock it |
| Signing fails with a quota error | 3-app limit reached, or the 7-day quota. Delete apps and wait |
| App installs but every game is slow | JIT is off. Go back to section 4 |
| App will not install at all | Try SideStore instead; it handles the provisioning profile differently |
| A Windows program will not start | Some need the Microsoft VC++ runtime, which is not bundled for licensing reasons. See `docs/BUILDING.md` upstream |

## What has NOT been tested

Everything on a real device. This work was done on a Windows laptop with no Mac
and no iPad. The code has been written and checked for structure, but **no part
of it has been run on hardware.** Expect to fix rough edges. The fork's
`TASK_STATE.md` lists exactly what is verified and what is not.