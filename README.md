# ShipTok

ShipTok is TikTok for your team's pull requests. Every open or merged pull request in the repository you choose that carries a video, screenshot or GIF is a card, laid out like Instagram Reels, and a card opens on the pull request's ShipTok video when it has one.

Pick **Open**, **Merged**, **Weekly** or **Features** from the tabs at the top of the feed. ShipTok opens on Merged the first time and on the mode you last used after that. Merged starts at the newest merge and reaches further back through the repository's history as you scroll; Open shows open pull requests, drafts included, most recently updated first. **Videos only**, on unless you turn it off in Settings, keeps both to pull requests that lead with a video; with it off, ones with only screenshots or GIFs show too. While the feed is on screen, the mode you're in reads GitHub again when you open it, when you come back to the app and 10 seconds after each read finishes; the inbox and Settings pause it. The card you're on stays put: an update that would move it, hide it or take it away waits until you swipe on. A pull request whose media all fails to load for you leaves the feed the same way, except that when a mode opens on one, it skips straight to the next card; one where only media from someone you hid hasn't failed is just out of sight until you unhide them. ShipTok saves both feeds and the media it has shown on your phone, so a relaunch opens at once, and its first refresh reads in full what changed since, can read again pull requests from the few minutes before that if they still belong in their mode, and reads the card you're on and, when its media links need renewing, the next one.

Weekly shows one card per weekly edition, newest week first, each posted as a closed `shiptok-weekly` issue in the repository with the week's video, images or GIFs. Features shows one card per shipped feature, most recently shipped first, each posted as a closed `shiptok-feature` issue with the feature's video, images or GIFs and dated from when that issue closed. Like, react, comment and vibe on a week or a feature the same way as on a pull request, and open its deck to swipe through the pull requests behind it in the video's order; a chevron at the top, with the week's dates or "Features", leads back.

A feature's deck shows every open or merged pull request behind the feature, even one with no media of its own. With nothing to play, that card shows the pull request's state, its lines and files changed, labels and description instead, with a Details button, and you can still like, react, comment and vibe on it.

On an iPhone, and on an iPhone Duo folded, the video takes the whole screen with no bar at the bottom: the inbox (a tray) and Settings (a gear) sit at the top right, or at the top of the folded Duo's side strip, and each leads back to the feed with **‹ Feed**. On an unfolded Duo the card sits inset above a floating tab bar that holds the feed, the inbox and Settings.

Swipe up and down to move between cards, and right for good vibes or left for bad vibes (VoiceOver offers both as actions on the card), with optional typed or spoken feedback and a few seconds to undo. Tap a video to pause it, set every video's speed from the rail or hold one for 2x, drag its progress line to scrub, pinch a video or image to zoom in and pan it with one finger (double-tap or pinch back out to return), double-tap to like, react with any of GitHub's reactions, open every video and image on the pull request from the deck, or read and write its comments. Everything lands on GitHub as you: a like is a ❤️ reaction, a comment is a pull request comment, and a vibe is a comment the author sees. Developers find the vibes, comments and reactions on their open and merged pull requests in the inbox.

## How it fits together

- **App** (`ShipTok/`): SwiftUI, iOS 17+, no third-party dependencies. You sign in with your Revyl account, then connect your GitHub account through Revyl's GitHub App, and the app reads and writes GitHub's API directly with that GitHub sign-in. It renews the GitHub sign-in on its own, so you connect once. When GitHub throttles your account, the app waits as long as GitHub asks before asking again.
- **Backend** (Revyl's ShipTok API, `/api/v1/shiptok/`, outside this repository): signs you in to Revyl and issues the app its Revyl key, keeps which GitHub account your Revyl account connected, redeems and refreshes the GitHub sign-in, which needs the GitHub App's secret, keeps each person's settings in Postgres under their GitHub user ID and takes requests to join an organization. It stores no GitHub token and never relays your GitHub reads or writes; before a video it hosts from a private repository plays, it asks GitHub whether your connected GitHub account can read that repository. Builds use Revyl's production backend, and the `SHIPTOK_REVYL_BACKEND_URL` build setting points one at another Revyl backend.

## Signing in

ShipTok is for teams that use Revyl, and nothing in it shows until you sign in. The first screen offers two things. **Sign in to Revyl** opens Revyl's own sign-in page in a private browser sheet; it has no sign-up. **Join existing organization** explains how to join your team's Revyl: accept an invite from your organization's owner or an admin, or type your work email and Revyl emails your organization's owners and admins asking them to invite you. Its answer is the same whether or not an organization matched.

Signed in to Revyl, **Connect GitHub** links your GitHub account to your Revyl account and opens your own feed; until then ShipTok shows only Connect GitHub. ShipTok checks with Revyl each time it opens or comes back to the foreground, so a Revyl sign-in that ended, an account that left its organization or a GitHub connection that moved to another account takes effect right away. **Sign out** signs the iPhone out of Revyl and GitHub. Contributor rules are in `AGENTS.md`, Revyl Sign-In.


## ShipTok videos

A pull request's newest ShipTok video plays first. Make the video with any tool, attach it to the description or a top-level conversation comment, and tag it with `#shiptok`, in any case, or with `<!-- shiptok:video -->`, which can carry attributes such as `source=revyl` that the app ignores. People and bots can both post tagged videos, and neither who posts one nor where it's hosted changes its priority. A comment with a tag stays out of the comment list, with or without a video. The tag only puts the newest tagged video first; every other video, screenshot and GIF stays in the deck.

ShipTok reads media from GitHub's rendered description and comments: videos GitHub shows, links to MP4, MOV and M4V files, Revyl-hosted video links, and images and GIFs from any HTTPS host, leaving out emoji, icons, SVGs and common badge, avatar and chart services. In your own feed, the app sends your Revyl key with a Revyl-hosted link only when the link is on the build's own Revyl backend, so a private repository's video plays for anyone in a Revyl organization whose connected GitHub account can read the repository. It follows the redirect to the file without the key and caches the video under a hashed identity. Pull request titles and labels are shown and saved without hosted video links, and the saved feeds never hold a tokened link, a signed redirect, a description or a comment. The full format, weekly editions and features included, is in [`docs/shiptok-format.md`](docs/shiptok-format.md), and contributor rules are in [`AGENTS.md`](AGENTS.md).

## Repository

Choose the repository under **Settings → Repository**, from every repository where an organization installed Revyl's GitHub App and you have access. ShipTok remembers your choice. The first time, it opens [RevylAI/shiptok-demo](https://github.com/RevylAI/shiptok-demo), Revyl's public example repository, when you can reach it, and otherwise asks. The feeds, weekly and feature videos and inbox follow your choice, and saved feeds and inbox read positions are kept apart for each repository and person.

## Report and hide

The rail's **More** button reports the pull request, weekly or feature video, or comment on the card through GitHub's own report form, or hides the person who posted it, and pressing and holding someone's comment offers the same. A hidden person's pull requests, weeks, features, comments, vibes and media disappear from your feeds, decks, comments and inbox on that phone, and **Settings → Hidden people** brings them back. They aren't told, and nothing changes on GitHub.

## Your data

ShipTok keeps your Revyl key and GitHub sign-in in the iPhone's Keychain, and the people you hid, your saved feeds and media on the iPhone. Revyl keeps your Revyl account, the GitHub account it connected, and your ShipTok settings under your GitHub user ID. Saved media is kept apart for each person whose feed the iPhone shows, and signing out removes theirs. **Settings → Delete my ShipTok data** deletes your ShipTok settings, ends ShipTok's access to your GitHub account and clears the iPhone, which signs it out of Revyl; your Revyl account and its GitHub connection stay. **Delete my Revyl account**, in Settings and in the Account sheet of Connect GitHub, deletes your Revyl account, its GitHub connection and your ShipTok settings, ends ShipTok's access to your GitHub account and clears the iPhone; Revyl refuses it for an organization's owner, who transfers or deletes the organization on Revyl's web app first. Your comments, reactions and vibes stay on GitHub either way. Settings also links Revyl's privacy policy and support, and `ShipTok/PrivacyInfo.xcprivacy` declares what the app collects, the email address a join request sends included.

## Analytics

The app sends typed product events to Revyl's PostHog project: Debug builds with `environment=development` and Release builds with `environment=production`, two analysis environments in one project. In your own feed the identity is the numeric GitHub user ID saved with your GitHub sign-in. The app never learns who signs in to Revyl, so a showing of the first screen, a showing of Connect GitHub and a GitHub sign-in attempt each use an ID of their own, and no login, email address or guessed Revyl organization is sent.

Watch events measure visible playback, not prefetching: pauses, buffering, scrubbing and time behind the comment sheet add no watch time, and the comment sheet pauses only the measurement, never the player. A URL expiring the first time isn't counted as a playback failure. Likes, reactions, comments and vibes record the tap and, separately, GitHub confirming the write. Speed, mode and Videos only changes are recorded from their controls, a pinch that zooms a video or image in is recorded with which card and media it zoomed, and each older page a mode loads is recorded with how many cards it added and how many of them show. The first screen, Revyl sign-in attempts and their failures by reason, Join existing organization and its failed requests, Connect GitHub and the GitHub sign-in attempts started there, every end of a sign-in by reason, and Delete my Revyl account requests and failures are counted, so you can see whether people get in, connect GitHub and stay; Revyl's backend records the sign-ins, GitHub connections and account deletions it completes. Reports and hides are counted without who was reported or hidden. Events ask PostHog not to derive a location, and no repository name, title, feedback, comment, email address, media URL, media ID or credential is sent. Delivery is best effort and never holds up playback or a GitHub action. The typed events in `ShipTok/Analytics/` are the event contract.

## Build

ShipTok needs Xcode 27.1 or newer, since the feed reads the system's reserved screen regions, which arrived in the iOS 27.1 SDK.

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
- **Tests in git.** `.revyl/tests/` holds one plain-language test per journey through the app, and `.revyl/modules/` the steps they share. Every run reads these files from git: a pull request's runs read the pull request's files, and `main`'s runs read `main`'s.
- **Test accounts.** Two journeys check the first screen signed out. Every other journey signs in to Revyl with a Revyl test account, connects revyl-shiptok-tests, a GitHub account that exists only for the tests, and reads RevylAI/kyle-expo, one at a time; a test that likes, reacts, comments or casts a vibe undoes it before it ends. Their credentials are secret global variables in Revyl, never in this repository, and nothing that signs in with them signs out or deletes anything.
- **One workflow for the journeys.** The ShipTok journeys workflow in Revyl holds the journey tests. CI runs it on each `main` build, and Revyl runs it on each pull request build CI uploads, drafts included.
- **Builds from CI.** CI uploads each build with its repository, commit, branch and pull request, which is how Revyl finds the build for a pull request. The `development` profile builds the same app on Revyl's cloud builder: `revyl build --profile development --platform ios` for a build, or `revyl dev --remote --profile development --platform ios` for a live cloud iPhone that rebuilds as you change the code.
- **Signed-in sessions.** The project's default session profile, `signed-in`, opens each session you start with `revyl device start` or `revyl dev`, and each proof of changes and Open preview session, already signed in to Revyl as the test account with revyl-shiptok-tests connected, on RevylAI/kyle-expo; `--session-profile none` starts on the first screen. It hands the app the test account's Revyl key and a GitHub token through launch arguments, from secrets kept in Revyl's variables, and the journeys still sign in themselves, since tests run no profile. `AGENTS.md` describes the grant and how to save a new one.
- **Proof of changes.** On every pull request from a branch of this repository, drafts included, Revyl's agent reads the change, drives the pull request's build on a cloud iPhone, and comments with what it verified, screenshots and a recording. A fork's pull request gets none, since CI can't upload its build.
- **Atlas.** Each `main` build is explored signed out, so Atlas maps the first screen and Join existing organization and never signs in or submits a join request.
- **Agent skills.** `.agents/skills/` holds Revyl's skills for coding agents (the device dev loop, writing tests, reading Atlas), linked for Claude Code from `.claude/skills/`, and `AGENTS.md` asks agents to verify every change on a Revyl device.

## License

[Apache License 2.0](LICENSE).
