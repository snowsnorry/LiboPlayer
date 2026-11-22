# Libo Player

Libo Player is a native iPhone app for listening to [Libo/Libo podcasts](https://play.libolibo.me/). Browse shows, search for an episode by title, or sign in with Telegram to see the latest episodes from the shows you follow.

## Library

Library contains followed Shows, Categories, Saved, Downloaded and Latest Episodes. Recently Updated opens the same show pages as the catalog. In an episode list, swipe right to change its played status, or swipe left to save or download it. Either action can be undone independently.

Downloaded audio plays offline after restarting the app. Guest collections and each signed-in account have separate storage. Saved bookmarks can be changed offline and sync with the paired Apple Watch when available. Each device keeps its own downloads.

## Listening

- Filter episodes by played status and mark individual episodes as played or unplayed. Finishing an episode also marks it as played. For signed-in listeners, both devices send these changes directly to the studio and retry offline changes when the app is active with internet access.
- Resume an episode from your saved position. When it ends, the player skips locked and completed episodes as it moves through the list.
- Listen in the background, control playback from the Lock Screen, and choose a speed from 0.75× to 2×.

The sign-in screen shows the studio’s Telegram button. After you approve the login, the app checks your account, saves the session in the iPhone Keychain and closes the screen automatically. Once signed in, tap the profile button to see your name and Telegram username or sign out. Confirming Sign Out clears the member token and switches to the guest library immediately, including offline. The public catalog refreshes in the background. When upgrading from the web-based player, the app can restore an existing website login. The app loads the catalog, episodes, search results and subscriptions directly over HTTPS. The public home page supplies the shows as embedded JSON. If the studio rejects a signed-in session, open the account page to sign in again. Subscription episodes require the corresponding access on your Libo/Libo account.

## Session handling

The web player exchanges the Telegram widget result at `POST /webAuth` and stores the studio-issued token in its own origin. For a new sign-in, the native app accepts the token from a successful exchange on the studio’s main page. Requests to the studio API carry the bearer token and, for a linked account, the site's `webAuthed` header. Guest tokens come from `POST /authPlayer`.

On launch the native app checks the saved session by loading the profile it needs for the catalog. A rejected guest session is replaced once. A rejected member session requires confirming the account again. Timeouts and server errors preserve the saved credential. Requests with credentials do not follow redirects.

## Run on iPhone or Simulator

Use Xcode on macOS with the iOS 26.1 SDK or later and an iPhone or simulator running iOS 17 or later. On iOS 26 and later, scrolling down collapses the tab bar and moves the mini-player beside the current tab and Search. The project uses Apple frameworks and has no external package dependencies.

1. Open `LiboPlayer.xcodeproj` in Xcode.
2. Select the `LiboPlayer` scheme and an iPhone simulator. For a physical iPhone, select your device and set your development team under **Signing & Capabilities**. If needed, choose a bundle identifier available to your team.
3. Press **⌘R** to build and run. To follow shows, open the account button on the **All Shows** tab and sign in with Telegram.

## Apple Watch

Select the **LiboWatch** scheme in the same Xcode project and run it on Apple Watch (watchOS 10 or later). For physical devices, enable Developer Mode on both devices and select the same development team for both targets. If you change the iPhone bundle ID, update the watch bundle ID and its companion ID in WatchInfo.plist to match.

Sign in once in the iPhone app and open Libo Player on the paired watch. **Account & Sync** at the top of the watch’s main menu shows when the account is connected. Its credential stays in the watch’s Keychain. Guests can also browse directly on the watch. On a run, the watch loads shows, searches and streams directly from the studio using Wi-Fi or an active cellular plan. Pair headphones to the watch for wireless listening. If the studio expires a member session, sign in again on the phone.

Tap an episode to play and swipe left for **More**. **Save** syncs a bookmark. **Download** keeps audio on the device where you selected it. **Library → Downloaded → On Watch** identifies episodes ready to play without a network. The watch persists its download queue and can retry unfinished requests when the app runs again.

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
