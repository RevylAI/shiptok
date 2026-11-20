# The ShipTok format

This is what ShipTok reads from GitHub and writes there, for anyone posting a ShipTok video, vibe, weekly edition or feature and for Revyl's pull request review config. GitHub is the record: the app reads pull requests, issues and comments, and writes reactions and comments as the signed-in person.

## Which pull requests are in the feed

Open shows the open pull requests, drafts included, and Merged the merged ones, in the repository the person chose, when the description or a top-level conversation comment carries at least one media item (see below). No label, age or time window decides. A pull request closed without merging leaves Open, and if the viewer is on its card it stays until they move on; it never shows otherwise. With Videos only on, as it is unless the person turns it off, a pull request shows only when its first media item, once media from people the viewer hid is left out, is a video. A feature's deck is the one place a pull request shows with no media at all (Features).

## What counts as media

ShipTok reads media from GitHub's rendered HTML of the description and of each top-level conversation comment, a bot's included, and never from inline code-review comments. Only HTTPS links count.

- **Videos.** A video GitHub renders, such as an attached MP4 or MOV, taken from its `<video>` element or, when that gives no usable link, the first of its `<source>` elements that does; a link to an `.mp4`, `.mov` or `.m4v` file, where an image inside the link is its poster rather than another item; and a Revyl-hosted video link (below). A video iOS can't play, such as WebM, isn't media.
- **Images and GIFs.** Any image GitHub renders, from any host, a `.gif` counting as a GIF. Left out: emoji, an image whose HTML gives a `width` or `height` of 40 pixels or less (the size is read only from those attributes, never from the image), an SVG, a link whose path holds `/badge` or `favicon`, and images from badge, avatar, chart and bot-service hosts such as shields.io, badgen.net, codecov.io and avatars.githubusercontent.com. These are heuristics, so a badge from another host can still count.

The same media in several places is one item, and a copy tagged as a ShipTok video wins.

## ShipTok video

A ShipTok video is any video in a description or top-level comment that carries a ShipTok tag:

- `#shiptok`, in any case, with no letter, digit, `_` or `#` right before or after it; or
- the hidden marker `<!-- shiptok:video -->`, in any case, which may carry attributes after a space that the app ignores, so `<!-- shiptok:video source=revyl -->` matches too. It's read from the raw markdown, since GitHub's rendered HTML drops it.

People and bots can both post one, and neither the poster nor the host changes its priority. A comment carrying a tag stays out of the comment list, with or without a video.

```markdown
<!-- shiptok:video -->

**ShipTok** · <one-line hook for the change>

<the video>
```

A Revyl-hosted upload's canonical link is `/api/v1/shiptok/videos/{token}.mp4` or `/api/v1/shiptok/videos/{token}.mov` on the backend, under whatever path the backend is served from, where `{token}` is the upload's 43-character token of letters, digits, `-` and `_`. The link can stand bare in the markdown or behind a linked poster. On a private repository the video plays only for a viewer GitHub lets read the repository: a signed-in app presents the person's GitHub token when the link is on the Revyl backend its build names, and playback follows the link's redirect without forwarding GitHub authorization. Uploading again makes a new link and a new cache identity, and the bytes behind a link never change.

A video is at most 100 MB (104,857,600 bytes), the limit of a Revyl-hosted upload. The app plays videos from memory, so it stops downloading a larger one, tagged or not, and treats it as media that failed to load.

## Which media shows first

1. The newest tagged ShipTok video, by the last edit of its description or comment, else its creation.
2. Otherwise the first video in deck order: the description first, then comments from oldest to newest.
3. Otherwise the first image or GIF in the same order.

Tags only reorder, so every other media item stays in the deck, untagged media included. Hiding a person leaves out their media and applies the same order to what's left.

## Pull request descriptions

A pull request's description shows in its detail sheet, which every mode opens, and on the summary that takes the place of media for a pull request with no media in a feature's deck. Both read the raw markdown and leave out its HTML comments and the blocks bots append between markers of their own:

- `<!-- CURSOR_SUMMARY -->` to `<!-- /CURSOR_SUMMARY -->`: Cursor Bugbot's summary.
- `<!-- codesmith:footer -->` to `<!-- /codesmith:footer -->`: codesmith's footer.
- `<!-- capy-badge:start -->` to `<!-- capy-badge:end -->`: Capy's Open in Capy badge.

Everything from a start marker to the first end marker after it is left out, both markers included. A start marker with no end marker after it leaves the text in, and text outside such a pair is never taken for a bot's. Media still comes from the whole rendered description, these blocks included (What counts as media, above).

A blockquote whose first line is GitHub's alert syntax, `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]` in any case, shows as a note titled Note, Tip, Important, Warning or Caution, with the rest of the blockquote inside it. The note ends at the first line that doesn't start with `>`. Any other blockquote shows as plain text.

## Vibes

A vibe is a top-level comment on a pull request, or on a week's or a feature's issue, posted as the person who cast it with a swipe or the rail's vibes button. Its body reads:

```markdown
<!-- shiptok:vibe good -->
**Good vibes** via ShipTok

<optional feedback, typed or transcribed>
```

Bad vibes use `<!-- shiptok:vibe bad -->` and `**Bad vibes** via ShipTok`. With no feedback, the body ends after the second line.

- A comment is a vibe when its first line, with spaces and tabs at either end trimmed, is exactly one of the two markers, whoever posted it. Its feedback is the rest of the body, less blank lines before it and a first line starting with `**`.
- On each pull request, week or feature, the app counts each person's newest vibe comment, by when it was created, and never a bot's.
- A new vibe the app posts replaces the person's earlier vibe comments there by deleting them once it has posted, and undoing a vibe deletes its comment.
- The comments sheet shows a vibe comment with the person's vibe and its feedback, and its header counts vibes apart from comments; the comment count on the rail leaves vibes out.

## Weekly editions

A weekly edition is a closed issue in the chosen repository labeled `shiptok-weekly`, whose description reads:

```markdown
<!-- shiptok:weekly week_start=2026-11-09 -->

## <the week's title>

<a one-line hook>

### Pull requests in this video

1. #12
2. #15
```

- The first non-empty line is the marker, exactly as shown apart from spaces around it, and its date is a Monday: the start of a week that runs Monday to Sunday in Pacific time.
- The first line starting with `## ` is the title, and the next non-empty line, which can't start with `#`, is the hook.
- Every line that is exactly `<n>. #<number>`, apart from spaces around it, names a pull request for the week's deck, in the video's order: the item number, a dot, one space, then `#` and the pull request's number, with nothing else on the line. An edition needs 1 to 30 of these lines to show, and a pull request named twice shows once.
- The issue's own title isn't read; a title like `ShipTok weekly · Nov 9–15` is a convention.
- The media can be in the description or any top-level comment, and needs no tag: videos, images and GIFs all count, and the card shows them in the same order as a pull request's. An edition with no media doesn't show.

Only closed issues are read, so closing the issue publishes the week, and it shows on the app's next read. The app reads the labeled closed issues newest-created first and sorts the editions it finds by week, and each issue is a card of its own, so a second issue for the same week is a second card. The demo holds the 25 most recently created. In the deck, open and merged pull requests with media show; one closed without merging, one with no media and one whose media all failed for the viewer are left out, though the card the viewer is on when it closes or loses its media stays until they move on. Vibes, reactions and comments on a week go on its issue in the same formats as on a pull request.

## Features

A feature is a closed issue in the chosen repository labeled `shiptok-feature`: one per shipped feature, with one video, however many pull requests shipped it. Its description reads:

```markdown
<!-- shiptok:feature -->

## <the feature's title>

<a one-line hook>

### Pull requests in this video

1. #12
2. #15
```

- The first non-empty line is the marker, exactly as shown apart from spaces around it. It carries no date, since a feature dates from when its issue closed.
- The first line starting with `## ` is the title, at most 70 characters with no trailing period. The next non-empty line, which can't start with `#`, is the hook, on one line of at most 120 characters. The app checks neither length nor the period, and the card shows at most two lines of each.
- Every line that is exactly `<n>. #<number>`, apart from spaces around it, names a pull request for the feature's deck, in the video's order: the item number, a dot, one space, then `#` and the pull request's number, with nothing else on the line. A line in another form, such as `1.#12`, `1. #12 (API)` or `- #12`, names none. A feature needs 1 to 30 of these lines to show, and a pull request named twice shows once.
- The issue's own title isn't read, so name it for people browsing GitHub, usually after the feature. Other labels can stay on the issue.
- The media can be in the description or any top-level comment, and needs no tag: videos, images and GIFs all count, and the card shows them in the same order as a pull request's. A feature with no media doesn't show.

To publish a feature:

1. Create the `shiptok-feature` label in the repository if it's missing.
2. Open an issue with the label and the description above, and attach the video to the description or a top-level comment, or paste a Revyl-hosted video link there (ShipTok video, above).
3. Close the issue as completed.

Only closed issues are read, so closing the issue publishes the feature, and it shows on the app's next read, dated from that close ("shipped 3 days ago"). To change a feature, edit its description or post a newer tagged video with the issue left closed; reopening it takes the card away at the app's next read, and closing it again dates it from the new close. The app reads the labeled closed issues newest-created first and sorts the features it finds by when they closed, newest first, then by the higher issue number, and each issue is a card of its own. The demo holds the 25 most recently created.

In the deck, every open or merged pull request the list names shows, with or without media of its own. One with no media shows its state, additions, deletions and changed files, labels and description in place of media, with a Details button. One closed without merging and one whose media all failed for the viewer are left out, though the card the viewer is on when it closes without merging stays until they move on. Vibes, reactions and comments on a feature go on its issue in the same formats as on a pull request.
