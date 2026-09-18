# Arcanum on iOS

A checklist for the first person to open https://marquezhv.com/arcanumweb/ on an
iPhone. Written without a device in hand: what was checked, what was changed,
what is still a guess.

## The short version

The browser build is probably fine on an iPhone by accident rather than by
design. Nothing here was made worse, three things that were plainly wrong were
fixed, and the app now asks iOS not to evict the catalogue it has downloaded -
which is the one iOS behaviour that made the app look broken on a return visit.
The app has never once reported a safe-area inset to Flutter, so nothing about
the notch can be confirmed until somebody looks.

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
- **`lib/core/platform/web_storage.dart`, and the two files it switches
  between.** One new call, made from `main.dart` inside the branch that only
  runs in a browser, asking the browser to move this origin's storage into
  persistent mode - the mode WebKit's own storage policy exempts from eviction.
  What it is asked, what each answer means, and why none of them is put on
  screen is in the next section.
- The safe-area finding above is still not fixable from Dart, and nothing under
  `lib/` was changed for it.

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
- **No `navigator.storage.estimate()`.** Considered alongside the request, and
  decided against. It answers with this whole origin's usage - the SQLite
  database, the card art this app has cached, the WebAssembly build, everything
  under one number - so it cannot tell a collector what the catalogue is taking,
  which was the only thing it would have been for. MDN is explicit that the
  figures are approximations, and WebKit says the quota moves with how often the
  site is visited and how popular it is, so the number would be both mislabelled
  and unstable. It would also be a second browser call on the boot path, for
  information no decision in the app reads.
- **No offline support.** That is `--pwa-strategy` and the deployment, not this
  branch of it.
- **`orientation: portrait-primary`** stays in the manifest even though
  `main.dart` allows every orientation. iOS ignores it entirely; on installed
  Android it locks the app upright. A question for whoever owns the Android
  story.

## What the app asks the browser for now

Once per page load, `main()` calls `requestPersistentStorage()`, inside the
`kIsWeb` branch that builds the rest of the browser-only pieces. It is not
awaited: Firefox answers the request with a permission prompt, and a boot screen
that waits for somebody to find a dialog is a boot screen that has hung.

Two questions are put to `navigator.storage`, in this order, and the order is
the whole of the decision:

1. `persisted()` - is this origin already in persistent mode? Asked first
   because an origin the browser is already keeping should not have to ask for
   something it already holds, which in a browser that answers by prompting its
   user is a dialog for a permission the site has.
2. `persist()` - the request itself, made only if the first answer was no.

There are three ways that can end, and the app treats all three the same on
screen: it says nothing and carries on. The differences are only in what it
means:

- **Granted** (`StorageDurability.persistent`). WebKit's storage policy
  ([Updates to Storage Policy](https://webkit.org/blog/14403/updates-to-storage-policy/))
  exempts an origin in persistent mode from eviction, so the catalogue and this
  browser's copy of the collection stay until somebody removes them. This is
  what the change is for.
- **Refused** (`StorageDurability.evictable`). The browser understood and said
  no. WebKit grants the request on heuristics, and the one it names is whether
  the site is open as a Home Screen web app - so on an iPhone this is the
  ordinary answer for a tab, and the same collector opening the app from the
  home screen icon is answered the other way by the same code. Nothing is
  broken by it: the collection is on the account and the catalogue is on the
  provider, so the cost of a refusal is a download that was always going to
  happen and a first launch that feels slow.
- **Nothing to answer with** (`StorageDurability.unanswerable`). No
  `navigator.storage` at all, no `persist` on it, or a call that threw. The
  Storage API is secure-context only, so this is also the answer at the
  plain-HTTP LAN address `tool/serve_web.dart` serves.

**Nothing about the answer is shown to a collector, and that is the deliberate
part.** A refusal would be a warning on every visit about a state the app was
built to survive, and there is nothing to press: the one thing that changes
WebKit's mind is adding the app to the Home Screen, which no page can do for
anybody. A prompt on first launch would also be worse than the silence it
replaced - the app works, it just works the way it always did. What is left is
one line in the console (`[storage] persistent`, `[storage] evictable` or
`[storage] unanswerable`), which is where somebody who can see it can still act
on it. If a later decision is that a collector should be told, the place to tell
them is Settings, beside the switch for the server catalogue, and not the boot
path.

The phone is untouched: the call sits in the `kIsWeb` branch, the file it
imports resolves to a stub on the phone through the same conditional export
`web_database.dart` uses, and a phone answers `unanswerable` if it is ever
asked at all. A browser with no Storage API behaves exactly as the app did
before this existed.

The deciding is separated from the asking: `storage_durability.dart` holds the
three answers and the function that reads them out of the browser, and knows
nothing about JavaScript, so `test/core/storage_durability_test.dart` drives it
with a browser that is already persistent, that refuses, that has no API, or that
throws. `web_storage_web.dart` is the only file that touches
`navigator.storage`.

That browser file cannot be reached from a test on the VM, and the run that
should have reached it did not finish here: `flutter test --platform chrome`
compiled the test and launched Chrome twice, and then said nothing for ten
minutes both times. So the interop was checked by hand instead, with the same
four pieces of it - the `@JS('navigator.storage')` getter, the two methods
called through a JS extension type, the `hasProperty` guard, and the promise
read back as a bool - compiled by `dart compile js` and driven from a `file://`
page in headless Chrome. There, `navigator.storage` resolved, both methods were
present, and both answered `false` immediately: a fresh profile with no
engagement is exactly the refusal path, and the point of the exercise was that a
refusal arrives as a `false` rather than as a promise that never settles. That
also retires the one thing this document could not otherwise have claimed - on
Chrome at least, the `@JS` name for a nested property like `navigator.storage`
does resolve. What the same page does on an iPhone is still step 2 of the list
below.

## What to look at first, in order

1. Add to Home Screen from the Share sheet, then open it from the icon. It should
   come up with no Safari bars. If Safari chrome is there, the manifest display
   mode or the apple capability tag is not being read, and nothing else on this
   list is being tested.
2. What the browser said about keeping the data, which needs a Mac and a cable
   the first time: open Safari on the Mac, connect the phone, and use Develop >
   [the phone] > the Arcanum page to read its console. Every load leaves exactly
   one line, `[storage] persistent` or `[storage] evictable`;
   `[storage] unanswerable` means there was no `navigator.storage` to ask,
   which on HTTPS is not expected on any iOS that has the Storage API at all and
   is worth reporting. The comparison that matters is the same build as a tab and
   as the Home Screen app: WebKit grants the request on heuristics and names the
   Home Screen app as one, so a tab saying `evictable` and the icon saying
   `persistent` is the expected pair. There is no other way to see this - the
   answer is deliberately never put on screen.
3. The status bar. The app's own top bar should sit below the clock, not under
   it, and the clock should be legible.
4. The bottom navigation bar. All five labels clear of the home indicator, and
   the swipe-up gesture still works from the bottom edge.
5. Rotate to landscape. Nothing clipped at the notch side, and no content pushed
   under the left or right edge.
6. The strips above and below the app, and in landscape at the sides, should be
   `#07070C`. White is what issue 71278 shows and what this branch changed the
   page background to fix; if they are still white, the colour is being painted
   by WebKit rather than by the page, and that is worth writing down.
7. Sign in, add a card, then leave the app (home, or another app) for a minute
   and come back. The card should still be there and should appear in the other
   browser: that is the `hidden` flush being caught before iOS suspends the
   process.
8. A search field and a bottom sheet with the keyboard up. The field should be
   above the keyboard, not behind it.
9. With two browsers signed in to the same account, change something in one and
   watch the other. Then background the phone for a few minutes and repeat: this
   is the only way to see whether the realtime socket is picked up again.
10. Long press some text and double tap a card. A browser would select and zoom;
    the app should not. The engine turns both off, so this is the quickest check
    that its own page styling survived.

## Still unknown without the device

- Whether iOS grants standalone mode from the manifest alone on this version, or
  whether the prefixed tag was doing the work.
- Whether the layout viewport really is inset inside the safe area in standalone
  mode, or whether the app is drawing under the status bar and home indicator.
  The strips in steps 3, 4 and 6 are what answer this. If content is under the
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
- Whether iOS grants `persist()` to a tab at all, and what it does for a Home
  Screen web app - whether the request is granted on the first load or only
  after the app has been opened a few times. WebKit documents the heuristic as
  "like whether the website is opened as a Home Screen Web App" and stops there.
- Whether a Home Screen web app is already in persistent mode before anything
  asks, in which case `persisted()` answers true, the request is never made on
  an iPhone, and step 2 is confirming a line that came from the first of the two
  questions rather than the second.
- Whether a persistent origin really does survive the seven idle days. WebKit's
  policy says eviction skips an origin "or its storage is in persistent mode",
  and describes the seven-day rule separately as a consequence of Intelligent
  Tracking Prevention; nobody here has left a persistent origin alone for eight
  days to watch. The cheap version of this test is a tab that reports
  `evictable`, opened once, left alone for a week, and then asked whether the
  catalogue is still there.
- Whether iOS ever shows the collector anything for the request. WebKit's own
  account of it is heuristics and no prompt, and the prompt is Firefox's
  documented behaviour; a dialog appearing on an iPhone would be news, and would
  also mean the request at boot is the wrong moment for it.

## Notes for whoever deploys

Changes under `web/` reach the phone only after `flutter build web --release`
and a deploy: `build/web` is generated, and the live site was still serving the
old shell when this was written. iOS takes its copy of the home screen icon at
the moment the app is added, so after any icon change the icon has to be removed
and added again. `dart run tool/serve_web.dart` serves `build/web` over plain
HTTP on the LAN, which Safari does not treat as a secure origin - anything odd
there should be re-checked against the deployed HTTPS URL before it is believed.
