# Arcanum on iOS

A checklist for the first person to open https://marquezhv.com/arcanumweb/ on an
iPhone. Written without a device in hand: what was checked, what was changed,
what is still a guess.

## The short version

The browser build is probably fine on an iPhone by accident rather than by
design. Nothing here was made worse, three things that were plainly wrong were
fixed, and the app has never once reported a safe-area inset to Flutter, so
nothing about the notch can be confirmed until somebody looks.

## What was checked

**The manifest and the shell.** `web/manifest.json` names the app "arcanum" in
both fields, describes it as "A new Flutter project." and paints itself the
Flutter template blue `#0175C2`; every icon file it points at exists, and
`start_url: "."` resolves to the deployed directory. `web/index.html` is the
untouched `flutter create` template: an `apple-touch-icon`, an
`apple-mobile-web-app-title` of "arcanum", `mobile-web-app-capable`, and no
viewport meta tag.

**The icons are the stock Flutter logo**, on a transparent ground, and the same
logo is what the Android app ships in `android/app/src/main/res/mipmap-*`. The
home screen icon will be a Flutter logo until somebody draws one; iOS composites
its transparency onto black.

**The live deployment** answers 200 for the shell, the manifest, the icons,
`sqflite_sw.js` and `sqlite3.wasm`, with the WebAssembly served as
`application/wasm`, which is the one Safari is strict about. There is no
service worker: the generated one unregisters itself, so an installed icon still
needs the network to boot. Storage is IndexedDB (a dedicated worker, not OPFS).

**The notch.** Flutter's web engine replaces any viewport meta tag on the page
at startup with its own, `width=device-width, initial-scale=1.0,
maximum-scale=5.0`, so `viewport-fit=cover` cannot be opted into from
`index.html`; and nothing in the engine reads `env(safe-area-inset-*)`, so
`MediaQuery.padding` is zero in every browser and every `SafeArea` in the
tree - `home_shell.dart`, the sign-in screen, the boot failure screen - is
inert. `AppBar` and `NavigationBar` therefore take no status bar or home
indicator inset either. Both halves are tracked upstream in flutter/flutter
issue 84833; the fix (PR 191647) is open and not in the 3.47.1 this build uses.
With `viewport-fit` absent, WebKit keeps the page inside the safe area, so the
app lands where it should - the engine's zero insets and the browser's inset
viewport cancel out. That is the "by accident" this document opened with.

What that looks like on a phone with a cutout is unused strips: white ones down
the sides in landscape, white ones top and bottom in portrait, depending on
where the page is running. flutter/flutter issue 71278 has the screenshots, from
an iPhone XS Max, an iPhone 15 and an iPhone 7 - the last of which has no cutout
and nothing wrong with it. The app's own drawing is correct in all of them; it
is the empty space around it that is not.

**Lifecycle.** The engine listens to `visibilitychange` (plus window focus and
blur) and emits `resumed`, `inactive`, `hidden` and `detached`. It never
emits `paused`. So `CollectionWatcher`, which flushes on `hidden`,
`paused` and `detached`, does fire when a tab or an installed app goes away -
Safari included - and `LockGate`, which arms on `paused` and fires on
`resumed`, never arms in a browser at all.

## What changed

- `web/manifest.json` - name and short_name "Arcanum", the real description,
  and `theme_color` / `background_color` moved from Flutter blue to the app's
  own canvas `#07070C`. From iOS 15 the theme colour is what paints the status
  bar of an installed app, and the app's own overlay style carries no colour to
  override it with.
- `web/index.html` - added `apple-mobile-web-app-capable` (older iOS reads
  this, not the manifest, before it will open standalone), "Arcanum" in the
  title and the apple title, a `theme-color` meta, the real description, and a
  page background of `#07070C` so the strips outside the safe area and the
  moment before Flutter paints are not white. Comments say why there is no
  viewport-fit and why the status bar stays opaque.
- Nothing under `lib/`. The safe-area finding above is not fixable from Dart.

## Deliberately not changed

- **No `viewport-fit=cover`.** The workaround in the wild is a few lines of
  JavaScript that re-add the descriptor after Flutter has written its own tag to
  the page, and it does take the strips away. It is not taken here because the
  app would then fill the screen and draw its own app bar under the Dynamic
  Island and its navigation bar under the home indicator, with nothing in
  Flutter's web rendering able to know those insets are there. A letterboxed app
  that is entirely visible beats a full-bleed one whose title and tabs are under
  the hardware. It belongs in the same upgrade as an engine that reads the
  insets: whoever moves the app onto such a Flutter should add the tag, check
  the strips are gone, and check nothing has slipped under the cutout.
- **No `navigator.storage.persist()`.** It would exempt the origin from
  eviction in Safari tabs, which is the exact worry that puts people on the home
  screen in the first place - but Firefox can answer it with a permission
  prompt, and it cannot be tested from here. Worth a deliberate decision.
- **No offline support.** That is `--pwa-strategy` and the deployment, not this
  branch of it.
- **`orientation: portrait-primary`** stays in the manifest even though
  `main.dart` allows every orientation. iOS ignores it entirely; on installed
  Android it locks the app upright. A question for whoever owns the Android
  story.

## What to look at first, in order

1. Add to Home Screen from the Share sheet, then open it from the icon. It should
   come up with no Safari bars. If Safari chrome is there, the manifest display
   mode or the apple capability tag is not being read, and nothing else on this
   list is being tested.
2. The status bar. The app's own top bar should sit below the clock, not under
   it, and the clock should be legible.
3. The bottom navigation bar. All five labels clear of the home indicator, and
   the swipe-up gesture still works from the bottom edge.
4. Rotate to landscape. Nothing clipped at the notch side, and no content pushed
   under the left or right edge.
5. The strips above and below the app, and in landscape at the sides, should be
   `#07070C`. White is what issue 71278 shows and what this branch changed the
   page background to fix; if they are still white, the colour is being painted
   by WebKit rather than by the page, and that is worth writing down.
6. Sign in, add a card, then leave the app (home, or another app) for a minute
   and come back. The card should still be there and should appear in the other
   browser: that is the `hidden` flush being caught before iOS suspends the
   process.
7. A search field and a bottom sheet with the keyboard up. The field should be
   above the keyboard, not behind it.
8. With two browsers signed in to the same account, change something in one and
   watch the other. Then background the phone for a few minutes and repeat: this
   is the only way to see whether the realtime socket is picked up again.
9. Long press some text and double tap a card. A browser would select and zoom;
   the app should not. The engine turns both off, so this is the quickest check
   that its own page styling survived.

## Still unknown without the device

- Whether iOS grants standalone mode from the manifest alone on this version, or
  whether the prefixed tag was doing the work.
- Whether the layout viewport really is inset inside the safe area in standalone
  mode, or whether the app is drawing under the status bar and home indicator.
  The strips in steps 2, 3 and 5 are what answer this. If content is under the
  notch, the only fixes available are cosmetic ones in Dart - a hand-added bottom
  pad, keyed on the user agent - and they are worth considering only once
  somebody has seen the problem.
- Whether `visibilitychange` fires when an installed app is backgrounded on
  this iOS, and whether the flush it starts completes before the process is
  suspended. Nothing can make that flush guaranteed; the one-second interval is
  what keeps the window small.
- How long the realtime socket takes to notice it died while the page was
  suspended. iOS stops timers with the page, so a socket dropped underneath a
  backgrounded app is only noticed once the page runs again; the listener does
  re-subscribe and catch up when it finds out (a test in the suite drives that
  path), but the delay after a suspend is the socket library's heartbeat and
  cannot be measured from here.
- Whether the IndexedDB write behind a card is on disk by the time iOS kills a
  suspended app. That is `sqflite_common_ffi_web`'s flush timing, not ours.
- How the Flutter logo looks scaled to the 180pt home screen slot, and whether
  its transparency composites to something acceptable.

## Notes for whoever deploys

Changes under `web/` reach the phone only after `flutter build web --release`
and a deploy: `build/web` is generated, and the live site was still serving the
old shell when this was written. iOS takes its copy of the home screen icon at
the moment the app is added, so after any icon change the icon has to be removed
and added again. `dart run tool/serve_web.dart` serves `build/web` over plain
HTTP on the LAN, which Safari does not treat as a secure origin - anything odd
there should be re-checked against the deployed HTTPS URL before it is believed.
