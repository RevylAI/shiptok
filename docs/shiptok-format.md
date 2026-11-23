# The ShipTok format

This is what Revyl's backend reads from GitHub to build ShipTok's cards, for anyone posting a ShipTok video, a weekly edition or a feature: which pull requests and issues become cards, what counts as media and which plays first, how a ShipTok video is tagged, what a description shows, and the comment Revyl's GitHub App keeps with each post's feedback. The backend reads GitHub through the organization's installation of Revyl's GitHub App and serves the result to the ShipTok app, which calls no GitHub API itself (`AGENTS.md`, "Ownership And Boundaries").

## Which pull requests are in the feed

ShipTok offers every repository Revyl's GitHub App covers for the organization, and each person chooses one.

- **Open** holds the repository's open pull requests, drafts included, most recently updated first.
- **Merged** holds its merged pull requests, most recently merged first.
- A pull request is in either only while it has at least one media item (below). No label, age or time window decides.
- A pull request closed without merging is never in the feed or a deck.
- **Videos only**, a person's setting that's on by default, leaves out of Open and Merged every pull request whose first media item isn't a video. Weekly, Features and the pull requests they open always show.
- A pull request without media is in neither, and a feature's deck still shows it (Features).

Revyl keeps what it reads from GitHub for a minute for each organization, so a change on GitHub can take up to a minute to reach ShipTok.

## What counts as media

Media comes from the description of a pull request, weekly edition or feature and from every comment on its Conversation tab, in that order, a bot's comments included. Inline code-review comments and review summaries are never read, and neither is the feedback summary comment (below). Only HTTPS links count.

From the HTML GitHub renders for each description and comment:

- **Videos.** A `<video>` element, from its `src` or `data-canonical-src`, or else the first of its `<source>` elements with a usable link, with its `poster`. A link to a file ending in `.mp4`, `.mov` or `.m4v`, where an image inside the link is the video's poster rather than another item. An image whose file ends in one of those extensions.
- **Images and GIFs.** Any other image from any host, a `.gif` counting as a GIF. Left out: an image with the `emoji` class, one whose `width` or `height` attribute is 40 pixels or less, an SVG, one whose path holds `/badge` or `favicon`, and images from shields.io, badgen.net, blacksmith.sh, codecov.io, github.githubassets.com, avatars.githubusercontent.com, vercel.com, coderabbit.ai, graphite.dev, cursor.com and dummyimage.com.
- **WebM.** A WebM video doesn't play on an iPhone, so it isn't media.

From each description's and comment's raw markdown, a Revyl-hosted video link (`<Revyl backend>/api/v1/shiptok/videos/<token>.mp4` or `.mov`) is a video wherever it appears, a bare link included.

The same file in several places is one item. An item's id is the SHA-256 of its URL with the scheme and host lowercased and the query and fragment dropped, using `data-canonical-src` when GitHub gives one, so a link GitHub signs again keeps its id.

## ShipTok video

A ShipTok video is a video in a description or comment whose raw markdown carries a ShipTok tag:

- `#shiptok`, in any case, as a word of its own: not inside a longer word or hashtag, so `#ShipTok!` counts and `#shiptok_demo` doesn't.
- `<!-- shiptok:video -->`, which GitHub doesn't show. Attributes inside it, such as `<!-- shiptok:video by=release-bot -->`, change nothing.

The tag makes every video in that same description or comment a ShipTok video, whoever posted it and wherever it's hosted, and never an image or GIF.

There are two ways to post one:

- **Attach it on GitHub.** Attach the video to the pull request's description or a comment, and add `#shiptok` to the same description or comment. A video attached on GitHub plays in ShipTok from the link GitHub signs for it.
- **Upload it to Revyl.** `revyl shiptok upload <file>` stores an MP4 or MOV file with a video track for the repository of the checkout's `origin` remote, or the one `--repo OWNER/REPO` names, and prints a `#shiptok <link>` line to paste in the pull request's description or a comment. It needs the Revyl CLI signed in with the Member role or higher in the Revyl organization whose GitHub App covers that repository. With `--pr <number>`, Revyl's GitHub App posts the video on that pull request itself, in one comment that reads `<!-- shiptok:video -->` and the video's Revyl-hosted link, and edits that comment for a later upload. In ShipTok the video plays from a link Revyl signs for five minutes each time it serves the post, only for the organization that uploaded it. A browser that opens the Revyl-hosted link lands on Revyl's watch page, which plays it for a signed-in member of that organization.

ShipTok downloads at most 100 MiB (104,857,600 bytes) of a video, wherever it's hosted, and a larger one fails like broken media; Revyl refuses to store a larger upload. Portrait 9:16 suits the card best: ShipTok crops a card's first media item to fill the card only when that loses at most an eighth of it, and shows any other shape whole over a dimmed, blurred copy of itself.

## Which media shows first

A card's first item, its hero, is:

1. the newest ShipTok video, by when its description or comment was last edited, or posted when it never was;
2. else the first video;
3. else the first item.

The other items follow in the order they appear, the description first and then the comments oldest first. When the same file appears in several places, it keeps its first place, and a copy tagged as a ShipTok video wins over an untagged one.

## Pull request descriptions

ShipTok shows a pull request's description in its detail sheet, and on the card of a pull request without media. Revyl serves the raw markdown without:

- HTML comments, ShipTok's own markers included;
- the blocks bots add between `<!-- CURSOR_SUMMARY -->` and `<!-- /CURSOR_SUMMARY -->`, `<!-- codesmith:footer -->` and `<!-- /codesmith:footer -->`, and `<!-- capy-badge:start -->` and `<!-- capy-badge:end -->`;
- every credential media link: a Revyl-hosted video link, and an image, GitHub upload or link to a media file whose URL carries a query string, as signed links do. An image or a bare link goes, and a linked label stays.

Titles, the hook of a weekly edition or feature, and pull request labels lose the same credential media links.

The app shows headings, paragraphs, bullet and numbered lists, tables row by row, code blocks and inline formatting, and the five alerts GitHub renders from a quote whose first line is `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]`. Images, HTML tags, lines that start with one, and horizontal rules don't show, and an empty description reads "No description."

## Weekly editions

Weekly shows one card per weekly edition, newest week first. A weekly edition is a GitHub issue in the repository that:

- is closed and labeled `shiptok-weekly`;
- has a description in the format below;
- holds at least one media item, in its description or its comments, read the way a pull request's is.

```markdown
<!-- shiptok:weekly week_start=2026-11-16 -->

## <the week's title>

<the hook: one line>

### Pull requests in this video

1. #6712
2. #6730
```

- The first line with text is exactly the marker, and `week_start` is a Monday written `YYYY-MM-DD`.
- The first line that starts with `## ` is the title.
- The next line with text after the title is the hook, and it doesn't start with `#`.
- Every line that's exactly `<n>. #<pull request number>` names a pull request, in the order the video covers them. There are 1 to 30 such lines, and a number listed twice counts once.

An issue that breaks any of these isn't a weekly edition. The card shows a "ShipTok weekly" chip with the week's dates, the title, the hook and its hero. Its deck holds the listed pull requests in order, less any closed without merging and any without media.

## Features

Features shows one card per shipped feature, most recently closed first. A feature is a GitHub issue in the repository that:

- is closed and labeled `shiptok-feature`;
- has a description in the weekly format, with `<!-- shiptok:feature -->` as its first line with text and no week;
- holds at least one media item, in its description or its comments.

```markdown
<!-- shiptok:feature -->

## <the feature's title>

<the hook: one line>

### Pull requests in this video

1. #6801
2. #6814
```

The card shows a "ShipTok feature" chip with when the issue closed ("shipped 3 days ago"), the title, the hook and its hero. Its deck holds the listed pull requests in order, less any closed without merging, and shows a pull request without media as a card with its state, stats, labels and description.

## Feedback summary comment

While an organization's "Feedback summary on GitHub" setting is on, as it is by default, Revyl's GitHub App keeps one comment on each pull request, weekly edition and feature that has feedback in ShipTok, so people on GitHub see it too:

```markdown
<!-- shiptok:feedback-summary -->
**🎬 ShipTok feedback**

👍 2 good vibes · ❤️ 1 like · 🚀 1

- 💬 **<name>:** <comment>
  - ↳ **<name>:** <reply>
- 👍 **<name>:** <good vibe feedback>

[Watch and reply in ShipTok →](<Revyl's watch page for the post>)
```

- The counts line lists good vibes, bad vibes and likes, then the other reactions by count, leaving out any that are zero.
- Each comment shows with its replies under it, and each vibe with feedback text, oldest first, by the person's name. Mentions and HTML in what people wrote are neutralized, so the comment pings nobody.
- Past 60,000 characters, the oldest items give way to "…and N more in ShipTok".
- The App edits the comment as feedback changes and deletes it once no feedback remains. Turning the setting off deletes every such comment, and turning it on posts them again.
- The comment is never read as media.
