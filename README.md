# ShipTok

ShipTok is TikTok for your team's pull requests. Every open or merged pull request in your chosen repository that carries a video, screenshot or GIF is one card, laid out like Instagram Reels and opening on its ShipTok video when it has one.

Switch between **Open**, **Merged** and **Weekly** at the top left. Merged, where the app opens, starts at the newest merge and keeps reaching further back through the repository's history as you scroll. Open shows open pull requests, drafts included, most recently updated first. **Videos only**, on by default in Settings, keeps both to pull requests that lead with a video; turn it off to see the ones with only screenshots or GIFs too. Whatever mode you're in refreshes as soon as you open it and every few seconds after, and the app saves both feeds and the media it has shown on the phone, so a relaunch opens at once and downloads only what changed.

Weekly shows one video per week, newest first, each posted as a closed `shiptok-weekly` issue in the repository. Like, react, comment and vibe on a week the same way as on a pull request, and open its deck to swipe through that week's pull requests in the video's order.

Swipe up and down to move between cards, and right for good vibes or left for bad vibes (or use the rail's vibes button), with optional typed or spoken feedback and a few seconds to undo. Tap a video to pause it, set every video's speed from the rail or hold one for 2x, drag its progress line to scrub, double-tap to like, react with any of GitHub's reactions, open every video and image on the pull request from the deck, or read and write its comments. Everything lands on GitHub as you: a like is a ❤️ reaction, a comment is a pull request comment, and a vibe is a comment the author sees. Developers find the vibes, comments and reactions on their open and merged pull requests in the inbox, one tab over from the feed.

## How it fits together

- **App** (`ShipTok/`): SwiftUI, iOS 17+, no third-party dependencies. You sign in with Revyl, which uses your GitHub account through Revyl's GitHub App, and the app then reads and writes GitHub's API directly with that sign-in. It renews the sign-in on its own, so you sign in once. **Look around first** opens a read-only demo of one public repository without an account; see `AGENTS.md`, Demo Mode.
- **Backend** (Revyl's ShipTok API, `/api/v1/shiptok/`, outside this repository): redeems and refreshes the GitHub sign-in, which needs the GitHub App's secret, keeps each person's settings in Postgres under their GitHub user ID, and serves the demo's public repository with the App's own token. It stores no GitHub token and never relays a person's GitHub reads or writes; before a video it hosts from a private repository plays, it asks GitHub whether the viewer's token can read that repository. Builds use Revyl's production backend, and the `SHIPTOK_REVYL_BACKEND_URL` build setting points one at another Revyl backend.

## ShipTok videos

A pull request's newest ShipTok video plays first. Make the video with any tool, attach it to the description or a top-level conversation comment, and include `#shiptok` (in any case) or `<!-- shiptok:video -->`. Anything else in the hidden marker is ignored, so markers with `source=revyl` still work. People and bots can both post tagged videos, and neither the author nor the host changes their priority. Tagged comments stay out of the comment list, with or without a video. The full format, weekly editions included, is in [`docs/shiptok-format.md`](docs/shiptok-format.md), and contributor rules are in [`AGENTS.md`](AGENTS.md).

A video is a GitHub attachment or a Revyl-hosted upload link: a bare MP4 or MOV link matching its container, or a poster linked to the video. Signed in, the app opens a hosted link with your GitHub token when the link is on the build's own Revyl backend, so a private repository's video plays for anyone GitHub lets read the repository; it follows the redirect to the file without the token and caches the video under a hashed identity. A demo visit sends no token, so only public repositories' hosted videos play there. The saved feeds never hold the tokened link, the signed redirect or a raw comment body. Tags only put the newest tagged video first; every other video, screenshot and GIF stays in the deck.

## Repository

Choose the repository under **Settings → Repository**, from every repository where an organization installed Revyl's GitHub App and you have access. ShipTok remembers your choice. The first time, it opens [RevylAI/shiptok-demo](https://github.com/RevylAI/shiptok-demo), the demo's public repository, when you can reach it, and otherwise asks. The feeds, weekly videos and inbox follow the choice, and saved feeds and inbox read positions are kept apart per repository and person.

## Report and hide

The rail's **More** button reports a pull request, weekly video or comment on the card through GitHub's own report form, or hides the person who posted it, and pressing and holding someone's comment offers the same. A hidden person's pull requests, weeks, comments, vibes and media disappear from your feeds, decks, comments and inbox on that phone, and **Settings → Hidden people** brings them back. They aren't told, and nothing changes on GitHub.

## Your data

ShipTok keeps your settings on Revyl under your GitHub user ID, and your sign-in, the people you hid, your saved feeds and media on your phone. Saved media is kept apart for each person who signs in on the phone, and signing out removes theirs. **Settings → Delete my ShipTok data** deletes the settings, ends ShipTok's access to your GitHub account and clears the phone; your comments, reactions and vibes stay on GitHub. Settings also links Revyl's privacy policy and support, and `ShipTok/PrivacyInfo.xcprivacy` declares what the app collects.

## Analytics

The app sends typed product events to Revyl's PostHog project: Debug builds with `environment=development` and Release builds with `environment=production`, two analysis environments in one project. The identity is the numeric GitHub user ID saved with the sign-in; no login or guessed Revyl organization is sent.

Watch events measure visible playback, not prefetching: pauses, buffering, scrubbing and time behind the comment sheet add no watch time, and the comment sheet pauses only the measurement, never the player. A URL expiring the first time isn't counted as a playback failure. Likes, reactions, comments and vibes record the tap and, separately, GitHub confirming the write. Speed, mode and Videos only changes are recorded from their controls, and each older page a mode loads is recorded with how many cards it added and how many of them show. Sign-in attempts, their failures by reason, sign-ins and sign-outs are counted, so you can see whether people get in and stay in. Reports and hides are counted without who was reported or hidden. Events ask PostHog not to derive a location, and no repository name, title, feedback, comment, media URL, media ID or credential is sent. Delivery is best effort and never holds up playback or a GitHub action. The typed events in `ShipTok/Analytics/` are the event contract.

## Build

ShipTok needs Xcode 27.1 or newer, since the feed reads the system's reserved screen regions, new in the iOS 27.1 SDK.

```bash
bash scripts/revyl/remote-build.sh setup     # checks the Xcode version
bash scripts/revyl/remote-build.sh compile   # Debug simulator build
bash scripts/revyl/remote-build.sh zip       # build/ShipTok.app.zip
```

Builds talk to Revyl's production backend. To try a change against another Revyl backend, set `SHIPTOK_REVYL_BACKEND_URL` when compiling; that backend's GitHub App needs `shiptok://github-sign-in-callback` as a callback URL.

App Store Connect builds go through the same script: `upload-to-testflight` archives a Release build and uploads it to ShipTok's App Store Connect record on Revyl's Apple team, Revyl, Inc (`9MQ4RWNL3N`), under the bundle id `ai.revyl.shiptok`, where the same build can go to TestFlight testers or App Review. It takes the build number in `APP_BUILD_NUMBER` and an App Store Connect API key of the team in `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID` and `APP_STORE_CONNECT_API_PRIVATE_KEY`.

### CI and releases

GitHub Actions runs `.github/workflows/ci.yml` on every pull request and every push to `main`: a gitleaks scan for secrets with `.gitleaks.toml`, then a build on GitHub's Xcode 27 runner with Xcode 27.2 that compiles the Debug simulator app through the script above and uploads it to Revyl. A fork's pull request builds without uploading, since GitHub gives forks none of the repository's secrets. On `main`, CI then runs the ShipTok journeys on that exact build and explores it with Atlas (see Built with Revyl). CI takes the Revyl app and workflow from `.revyl/config.yaml`, so GitHub holds only secrets.

`.github/workflows/release.yml` ships to App Store Connect. Run it by hand from the Actions tab with the next build number; it archives the Release build and uploads it through `upload-to-testflight` with the team's App Store Connect API key from the repository's secrets.

## Built with Revyl

ShipTok is built and tested with [Revyl](https://revyl.com), and git is the source of truth for both its Revyl configuration and its tests.

- **Configuration in git.** `.revyl/config.yaml` is the Revyl project's whole configuration: its build recipe, pull request automation and proof of changes. Revyl's GitHub App applies the file from `main` on every push, and Revyl refuses edits made anywhere else.
- **Tests in git.** `.revyl/tests/` holds one plain-language test per journey through the app, and `.revyl/modules/` the steps they share. Every run reads these files from git: a pull request's runs read the pull request's files, and `main`'s runs read `main`'s. The tests go in signed out, through **Look around first**, so none needs a GitHub account.
- **One workflow for every journey.** The ShipTok journeys workflow in Revyl holds every test. CI runs it on each `main` build, and Revyl runs it on each pull request build CI uploads, drafts included.
- **Builds from CI.** CI uploads each build with its repository, commit, branch and pull request, which is how Revyl finds the build for a pull request. The `development` profile builds the same app on Revyl's cloud builder: `revyl build --profile development --platform ios` for a build, or `revyl dev --remote --profile development --platform ios` for a live cloud iPhone that rebuilds as you change the code.
- **Proof of changes.** On every pull request from a branch of this repository, drafts included, Revyl's agent reads the change, drives the pull request's build on a cloud iPhone, and comments with what it verified, screenshots and a recording. A fork's pull request gets none, since CI can't upload its build.
- **Atlas.** Each `main` build is explored, and Atlas keeps a map of its screens and flows.
- **Agent skills.** `.agents/skills/` holds Revyl's skills for coding agents (the device dev loop, writing tests, reading Atlas, test-only sign-in), linked for Claude Code from `.claude/skills/`, and `AGENTS.md` asks agents to verify every change on a Revyl device.

## License

[Apache License 2.0](LICENSE).
