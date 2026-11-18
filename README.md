# ShipTok

ShipTok is TikTok for what the team merged. Every pull request merged into your chosen repository in the last two weeks that carries a video, screenshot or GIF shows as one card, laid out like Instagram Reels, opening on its ShipTok video when it has one, and every pull request labeled `shiptok` with a ShipTok video stays in the feed however old it gets. Pull requests with ShipTok videos come first, then other videos, then screenshots and GIFs, each group newest first. The app saves the feed and the media it has shown on the phone, so a relaunch opens at once and downloads only what's new.

Swipe up and down to move between pull requests, and right for good vibes or left for bad vibes (or use the rail's vibes button), with optional typed or spoken feedback and a few seconds to undo. Tap a video to pause it, set every video's speed from the rail or hold one for 2x, drag its progress line to scrub, double-tap to like, react with any of GitHub's reactions, open every video and image on the pull request from the deck, or read and write its comments. Everything lands on GitHub as you: a like is a ❤️ reaction, a comment is a pull request comment, and a vibe is a comment the author sees. Developers see the vibes, comments and reactions on their merged pull requests in the inbox, one tab over from the feed.

Switch between **PRs** and **Weekly** at the top left. Weekly shows one video per week, newest first, each posted as a closed `shiptok-weekly` issue in the repository. Like, react, comment and vibe on a week the same way as on a pull request, and open its deck to swipe through that week's pull requests in the video's order.

## How it fits together

- **App** (`ShipTok/`): SwiftUI, iOS 17+, no third-party dependencies. Sign in with Revyl, which uses your GitHub account through Revyl's GitHub App; the app then reads and writes GitHub's API directly with that sign-in, so the feed is always live. It renews the sign-in on its own, so you sign in once. **Look around first** opens a read-only demo of one public repository without an account; see `AGENTS.md`, Demo Mode.
- **Backend** (Revyl's ShipTok API, `/api/v1/shiptok/`, outside this repository): redeems and refreshes the GitHub sign-in, which needs the GitHub App's secret, keeps each person's feedback-prompt settings in Postgres under their GitHub user ID, and serves the demo's one public repository with the App's own token. It stores no GitHub token and never relays a person's GitHub reads or writes, and before a video it hosts from a private repository plays, it asks GitHub whether the viewer's token can read that repository. Builds use Revyl's production backend; the `SHIPTOK_REVYL_BACKEND_URL` build setting points one at another Revyl backend.

## ShipTok videos

A pull request's newest ShipTok video plays first. Make a video with your own tools, attach it to the PR description or a top-level conversation comment, and include `#shiptok` (case-insensitive) or `<!-- shiptok:video -->`. Attributes in the hidden marker are ignored, so existing markers with `source=revyl` still work. People and bots can post tagged videos; neither the author nor the hosting provider changes their priority. Tagged comments stay out of the discussion list, with or without a video. Contributor rules, including the format contract, live in [`AGENTS.md`](AGENTS.md).

Use a GitHub video attachment or a Revyl-hosted upload link. A hosted video can be a bare MP4 or MOV link, matching its container, or a poster linked to that video. Signed in, the app opens that canonical link with the person's GitHub token when the link is on the build's own Revyl backend, so a private repository's video plays for anyone GitHub lets read the repository; it follows the redirect to the file without the token and caches the video bytes under a hashed identity. A demo visit opens it without a token, so only public repositories' hosted videos play there. It doesn't save the tokened link, signed redirect, or raw comment body in its feed cache. A closed `shiptok-weekly` issue with a valid weekly description accepts the same media in its description or comments, tagged or untagged. Tags only put the newest tagged video first; other media stays available. Revyl-owned generation is not required.

## Repository

Choose the repository under **Settings → Repository**. The list is every repository where an organization installed Revyl's GitHub App and you have access. ShipTok remembers your choice. The first time, it opens [RevylAI/shiptok-demo](https://github.com/RevylAI/shiptok-demo), the demo's public repository, when you can reach it and otherwise asks. The feed, weekly videos and inbox all follow the choice, and feed caches and inbox read positions stay separate per repository and person.

## Report and hide

The rail's **More** button reports a pull request, weekly video or comment the card shows through GitHub's own report form, or hides the person who posted it; pressing and holding someone's comment offers the same. A hidden person's pull requests, weeks, comments, vibes and media disappear from your feed, decks, comments and inbox on that phone, and **Settings → Hidden people** unhides them. They aren't told, and nothing changes on GitHub.

## Your data

ShipTok keeps your feedback-prompt settings on Revyl under your GitHub user ID, and your sign-in, the people you hid, saved feeds and media on your phone. **Settings → Delete my ShipTok data** deletes the settings, ends ShipTok's access to your GitHub account and clears the phone; your comments, reactions and vibes stay on GitHub. Settings also links Revyl's privacy policy and support. What the app collects is declared in `ShipTok/PrivacyInfo.xcprivacy`.

## Analytics

The native app sends typed semantic events to Revyl's PostHog project. Debug events have `environment=development`; Release events have `environment=production`. These are separate analysis environments in one project, not separate PostHog projects. The numeric GitHub user ID saved with the sign-in is the identity; no login or guessed Revyl organization mapping is sent.

Watch events measure visible playback, not prefetching: pauses, buffering, scrubbing and comment-sheet time don't add watch time. Comment sheets leave the player's behavior unchanged; only analytics pauses. Expected first URL expiry is not a terminal playback failure. Likes, reactions, comments and vibes distinguish intent from a GitHub-confirmed write. Speed and feed-mode events come from their controls. Delivery is best effort and never blocks playback or a GitHub action. Sign-in attempts, their failures by reason, sign-ins and sign-outs are counted, so you can see whether people get in and stay signed in. Reports and hides are counted without who was reported or hidden. Events ask PostHog not to derive a location. No repository names, titles, feedback, comments, media URLs, media IDs or credentials enter analytics. The typed events in `ShipTok/Analytics/` are the event contract.

## Build

ShipTok needs Xcode 27.1 or newer: the feed reads the system's reserved screen regions, new in the iOS 27.1 SDK.

```bash
bash scripts/revyl/remote-build.sh setup     # checks the Xcode version
bash scripts/revyl/remote-build.sh compile   # Debug simulator build
bash scripts/revyl/remote-build.sh zip       # build/ShipTok.app.zip
```

Builds talk to Revyl's production backend. To try a change against another Revyl backend, set `SHIPTOK_REVYL_BACKEND_URL` when compiling; its GitHub App needs `shiptok://github-sign-in-callback` as a callback URL.

App Store Connect builds go through the same script: `upload-to-testflight` archives a Release build and uploads it to ShipTok's App Store Connect record on Revyl's Apple team, Revyl, Inc (`9MQ4RWNL3N`), under the bundle id `ai.revyl.shiptok`, where the same build can go to TestFlight testers or App Review. It takes the build number in `APP_BUILD_NUMBER` and an App Store Connect API key of the team in `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID` and `APP_STORE_CONNECT_API_PRIVATE_KEY`.

### CI and releases

GitHub Actions runs `.github/workflows/ci.yml` on every pull request and every push to `main`: a gitleaks scan for secrets with `.gitleaks.toml`, then a build on GitHub's Xcode 27 runner with Xcode 27.2 that compiles the Debug simulator app through the script above and uploads it to Revyl. A fork's pull request builds without uploading, since GitHub gives forks none of the repository's secrets. On `main`, it then runs the ShipTok journeys on that exact build and explores it with Atlas (see Built with Revyl). CI takes the Revyl app and workflow from `.revyl/config.yaml`, so GitHub holds only secrets.

`.github/workflows/release.yml` ships to App Store Connect. Run it by hand from the Actions tab with the next build number; it archives the Release build and uploads it through `upload-to-testflight`, with the team's App Store Connect API key from the repository's secrets.

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
