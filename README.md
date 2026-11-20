# Libo Player

Libo Player is a native iPhone app for listening to [Libo/Libo podcasts](https://play.libolibo.me/). Browse shows, search for an episode by title, or sign in with Telegram to see the latest episodes from the shows you follow.

## Listening

- Filter episodes by played status and mark individual episodes as played or unplayed.
- Resume an episode from your saved position. When it ends, the player skips locked and completed episodes as it moves through the list.
- Listen in the background, control playback from the Lock Screen, and choose a speed from 0.75× to 2×.

The app streams audio from Libo/Libo and uses the studio’s web player for sign-in and catalog access. Subscription episodes require the corresponding access on your Libo/Libo account.

## Run on iPhone or Simulator

Use Xcode on macOS with an iOS SDK and an iPhone or simulator running iOS 17 or later. The project uses Apple frameworks and has no external package dependencies.

1. Open `LiboPlayer.xcodeproj` in Xcode.
2. Select the `LiboPlayer` scheme and an iPhone simulator. For a physical iPhone, select your device and set your development team under **Signing & Capabilities**. If needed, choose a bundle identifier available to your team.
3. Press **⌘R** to build and run. To follow shows, open the account button on the **Shows** tab and sign in with Telegram.

## Run the playback checks

From the repository root on macOS, run the following commands to check playback order, resume positions, listening history, and episode filters. These checks run without a simulator or a Libo/Libo account.

```sh
mkdir -p build
xcrun swiftc LiboPlayer/Episode.swift Tests/PlaybackOrderChecks.swift -o build/playback-checks
./build/playback-checks
```
