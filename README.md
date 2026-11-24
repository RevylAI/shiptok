# ShipTok

ShipTok is Revyl's iPhone app for watching what your team ships. Sign in with your Revyl account, choose one of the repositories your Revyl organization's GitHub App covers, and swipe through it one card at a time, each card led by its ShipTok video or other media:

- **Open** and **Merged** show the repository's open and merged pull requests that have a video, screenshot or GIF.
- **Weekly** shows one video per week of shipped work, and **Features** one video per shipped feature. Tap one to watch the pull requests behind it.

Swipe up for the next card and down for the previous one. Swipe right for good vibes or left for bad vibes, with feedback you type or dictate if you like. Double-tap to like, press and hold the like button for other reactions, and open the comments to comment or reply. Revyl finds the pull request's developer among your organization's members, by the GitHub username each person sets in Settings or else by email, and they get your feedback in their ShipTok inbox and as a notification.

## How it fits together

ShipTok talks only to Revyl's backend, which serves its ShipTok API. The backend reads the repository's pull requests and issues from GitHub through the organization's installation of Revyl's GitHub App, so nobody connects a GitHub account. It also keeps everything people give in ShipTok: likes, reactions, vibes, comments, replies, the inbox and each person's settings, which their iPhones and Revyl's web app share. While the organization allows it, Revyl's GitHub App keeps one comment on each pull request and issue with feedback, summing it up for people on GitHub.

`AGENTS.md` holds the rules for changing the app. `docs/shiptok-format.md` describes what Revyl's backend reads from GitHub: which pull requests are in the feed, what counts as media, the ShipTok video tag, the weekly and feature issues, and the feedback summary comment.

## ShipTok videos

A ShipTok video is a video in a pull request's description or in a comment on it, tagged with `#shiptok` (or the hidden `<!-- shiptok:video -->` marker) in that same description or comment. It plays first on the pull request's card, ahead of every screenshot, GIF and other video. Attach it on GitHub, or upload it to Revyl with `revyl shiptok upload <file> --pr <number>`, which has Revyl's GitHub App post it on the pull request in a tagged comment. ShipTok plays videos of up to 100 MiB, except WebM, which an iPhone can't play. Portrait 9:16 suits the card best: ShipTok crops a card's first media item to fill the card only when that loses at most an eighth of it, and shows any other shape whole over a dimmed, blurred copy of itself.

## Repository

Settings → Repository lists every repository your organization's Revyl GitHub App covers, and ShipTok remembers your choice on this iPhone. When the App covers exactly one, ShipTok chooses it for you. If the list is empty, ask an admin of your organization to install Revyl's GitHub App on the repositories ShipTok should show.

## GitHub username

Settings → GitHub username tells Revyl which GitHub account is yours, so you're the developer on the pull requests it opens, with their feedback in your inbox and notifications. Type the username, with or without its @, and Save. One person in your organization can set each GitHub account: if someone already did, ShipTok says who, and your organization's owners and admins can change or remove it. Until you set it, Revyl looks for you by email. It isn't a GitHub sign-in, and ShipTok never connects to your GitHub account.

## Report and hide

Every pull request, weekly or feature video, comment, reply and vibe in ShipTok can be reported, and the person who posted it hidden, except your own pull requests and videos. A pull request or video lives on GitHub, so Report opens GitHub's own report form. A comment, reply or vibe lives in Revyl, so Report emails your organization's owners and admins. Hiding a post's author takes their pull requests and videos out of ShipTok on this iPhone, and hiding a commenter takes their comments, replies and vibes out; they aren't told. Settings → Hidden people lists everyone you hid, with Unhide.

## Your data

ShipTok keeps your sign-in in this iPhone's Keychain and caches feeds and media on the iPhone. Everything you do in ShipTok lives in your Revyl account. Sign out, in Settings, signs this iPhone out and stops its ShipTok notifications. Delete my Revyl account deletes your Revyl account with your GitHub username and the comments, replies, reactions, vibes and settings you made in ShipTok, and then everything ShipTok kept on the iPhone. An owner of an organization can't delete their Revyl account from ShipTok. The [ShipTok section of Revyl's privacy policy](https://revyl.com/privacy/#shiptok) describes the data ShipTok uses.

## Analytics

ShipTok sends product analytics to PostHog: which cards people watch and for how long, the gestures and controls they use, and how their likes, reactions, comments and vibes turn out. An event names a card by its kind, id and number and a person by their Revyl user id. Events carry no video link, title, comment, feedback text or repository name, and PostHog builds no person profile and derives no location from them. `AGENTS.md` ("Product Analytics") has the rules.

## Build

ShipTok builds with Xcode 27.1 or newer and runs on iOS 17 and later. `scripts/revyl/remote-build.sh` is its one build pipeline:

```bash
bash scripts/revyl/remote-build.sh setup     # checks the Xcode version
bash scripts/revyl/remote-build.sh compile   # builds the Debug simulator app
bash scripts/revyl/remote-build.sh zip       # zips it to build/ShipTok.app.zip
```

Every build talks to Revyl's production backend. To point a build at another Revyl backend, set `SHIPTOK_REVYL_BACKEND_URL` for `compile`. Without a Mac, `revyl build --build-profile development --platform ios` builds the same app on Revyl's cloud builder.

### CI and releases

On every pull request and every push to `main`, `.github/workflows/ci.yml` scans the repository for secrets, builds the app and uploads the build to Revyl. On `main` it also runs the ShipTok journeys on that build and explores it with Atlas. `.github/workflows/release.yml`, run by hand with a build number, archives a Release build and uploads it to App Store Connect.

## Built with Revyl

ShipTok is built and tested with [Revyl](https://revyl.com), and git is the source of truth for both its Revyl configuration and its tests.

- **Configuration in git.** `.revyl/config.yaml` is the Revyl project's whole configuration: its session profile, its build recipe, its pull request automation and its proof of changes. Revyl takes it from `main`, a pull request's runs use the pull request's own copy, and Revyl refuses edits made anywhere else.
- **Tests in git.** `.revyl/tests/` holds one plain-language test per journey through the app, and every run reads them from git: a pull request's runs read the pull request's files, and `main`'s runs read `main`'s. The tests sign in as Revyl's test account and read RevylAI/kyle-expo, and a test that likes, reacts, comments or casts a vibe undoes it before it ends.
- **One workflow for the journeys.** The ShipTok journeys workflow in Revyl holds the journey tests. CI runs it on each `main` build, and Revyl runs it on each pull request's build, drafts included.
- **Builds from CI.** CI uploads each build with `revyl build upload`, which reads the repository, the head commit, the branch and the pull request from GitHub Actions, and that's how Revyl's proof of changes finds the build for a pull request. The `development` profile builds the same app on Revyl's cloud builder: `revyl build --build-profile development --platform ios` for a build, or `revyl dev --remote --build-profile development --platform ios` for a live cloud iPhone that rebuilds as you change the code.
- **Signed-in sessions.** The project's default session profile, `signed-in`, starts each session you open with `revyl device start` or `revyl dev`, each proof of changes and each Open preview already signed in on RevylAI/kyle-expo. It hands the app the test account's ShipTok key and the repository through launch arguments, from the organization's launch variables, and the tests take the same launch variables themselves. `AGENTS.md` ("Revyl") describes the key and how to save a new one.
- **Proof of changes.** On every pull request from a branch of this repository, drafts included, Revyl's agent reads the change, drives the pull request's build on a cloud iPhone, and comments with what it verified, screenshots and a recording. A fork's pull request gets none, since CI can't upload its build.
- **Atlas.** Each `main` build is explored signed out, from the first screen, and Atlas never completes a Revyl sign-in.
- **Agent skills.** `.agents/skills/` holds Revyl's skills for coding agents (the device dev loop, writing tests, reading Atlas), linked for Claude Code from `.claude/skills/`, and `AGENTS.md` asks agents to verify every change on a Revyl device.

## License

[Apache License 2.0](LICENSE).
