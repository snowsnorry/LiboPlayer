# Libo Player

Libo Player is a native iPhone app for listening to [Libo/Libo podcasts](https://play.libolibo.me/). Browse shows, search for an episode by title, or sign in with Telegram to see the latest episodes from the shows you follow.

## Library

Library contains followed Shows, Categories, Saved, Downloaded and Latest Episodes. Recently Updated opens the same show pages as the catalog. In an episode list, swipe right to change its played status, or swipe left to save or download it. Either action can be undone independently.

Downloaded audio plays offline after restarting the app. Guest collections and each signed-in account have separate storage. Saved bookmarks are stored on this iPhone and can be added or removed offline.

## Listening

- Filter episodes by played status and mark individual episodes as played or unplayed.
- Resume an episode from your saved position. When it ends, the player skips locked and completed episodes as it moves through the list.
- Listen in the background, control playback from the Lock Screen, and choose a speed from 0.75× to 2×.

The app uses the studio’s account page for Telegram sign-in. Tap **Done** to save the session in the iPhone Keychain. When upgrading from the web-based player, the account page can reuse the existing website login. The app loads the catalog, episodes, search results and subscriptions directly over HTTPS. The public home page supplies the shows as embedded JSON. If the studio rejects a signed-in session, open the account page to sign in again. Subscription episodes require the corresponding access on your Libo/Libo account.

## Session handling

The web player exchanges the Telegram widget result at `POST /webAuth` and stores the studio-issued token in its own origin. The native app hands off that token only when the account screen is confirmed. Requests to the studio API carry the bearer token and, for a linked account, the site's `webAuthed` header. Guest tokens come from `POST /authPlayer`.

On launch the native app checks the saved session by loading the profile it needs for the catalog. A rejected guest session is replaced once. A rejected member session requires confirming the account again. Timeouts and server errors preserve the saved credential. Requests with credentials do not follow redirects.

## Run on iPhone or Simulator

Use Xcode on macOS with the iOS 26.1 SDK or later and an iPhone or simulator running iOS 17 or later. On iOS 26 and later, scrolling down collapses the tab bar and moves the mini-player beside the current tab and Search. The project uses Apple frameworks and has no external package dependencies.

1. Open `LiboPlayer.xcodeproj` in Xcode.
2. Select the `LiboPlayer` scheme and an iPhone simulator. For a physical iPhone, select your device and set your development team under **Signing & Capabilities**. If needed, choose a bundle identifier available to your team.
3. Press **⌘R** to build and run. To follow shows, open the account button on the **All Shows** tab and sign in with Telegram.

## Run the playback checks

From the repository root on macOS, run the following commands to check playback order, resume positions, listening history, and episode filters. These checks run without a simulator or a Libo/Libo account.

```sh
mkdir -p build
xcrun swiftc LiboPlayer/Episode.swift Tests/PlaybackOrderChecks.swift -o build/playback-checks
./build/playback-checks
```

## Run the native API checks

These checks use local fixtures for guest renewal, expired member sessions, catalog parsing, search, playback marks and subscription changes.

```sh
mkdir -p build
xcrun swiftc LiboPlayer/Episode.swift LiboPlayer/StudioCredential.swift LiboPlayer/StudioPayload.swift LiboPlayer/StudioSession.swift Tests/StudioSessionChecks.swift -o build/studio-checks
./build/studio-checks
```

## Run the offline collection checks

These checks use a temporary directory to verify independent saves and downloads, account isolation, retry, and restoration after relaunch.

```sh
mkdir -p build
xcrun swiftc LiboPlayer/Episode.swift LiboPlayer/EpisodeCollection.swift Tests/EpisodeCollectionChecks.swift -o build/collection-checks
./build/collection-checks
```
