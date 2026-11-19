# The ShipTok format

What ShipTok reads from GitHub and what it writes there, for anyone posting a ShipTok video, vibe or weekly edition and for Revyl's pull request review config. GitHub is the record: the app reads pull requests, issues and comments, and writes reactions and comments as the signed-in person.

## Which pull requests are in the feed

Open and merged pull requests in the repository the person chose, drafts included, whose description or a top-level conversation comment carries at least one media item (see below). A pull request closed without merging never shows, and no label, age or time window decides. Open holds the open ones and Merged the merged ones. With Videos only on, as it is unless the person turns it off, a pull request shows only when its first media item, once media from people the viewer hid is left out, is a video.

## What counts as media

ShipTok reads media from GitHub's rendered HTML of the description and of each top-level conversation comment, a bot's included; inline code-review comments are never read. Only HTTPS links count.

- **Videos.** A video GitHub renders, such as an attached MP4 or MOV, from its `<video>` element or that element's first `<source>`; a link to an `.mp4`, `.mov` or `.m4v` file, where an image inside the link is its poster rather than another item; and a Revyl-hosted video link (below). A video iOS can't play, such as WebM, is not media.
- **Images and GIFs.** Any image GitHub renders, from any host, a `.gif` counting as a GIF. Left out: emoji, an image 40 pixels or smaller in width or height, an SVG, a link whose path holds `/badge` or `favicon`, and images from badge, avatar, chart and bot-service hosts such as shields.io, badgen.net, codecov.io and avatars.githubusercontent.com. These are heuristics, so a badge from another host can still count.

The same media in several places is one item, and a copy that's tagged as a ShipTok video wins.

## ShipTok video

Every video in a description or top-level comment that carries a ShipTok tag:

- `#shiptok`, in any case, with no letter, digit, `_` or `#` right before or after it; or
- the hidden marker `<!-- shiptok:video -->`, in any case, which may carry attributes after a space that the app ignores, so `<!-- shiptok:video source=revyl -->` matches too. Read it from the raw markdown, since GitHub's rendered HTML drops it.

Anyone can post one, people and bots alike, and neither the poster nor the host changes its priority. Comments carrying a tag stay out of the discussion list, with or without a video.

```markdown
<!-- shiptok:video -->

**ShipTok** · <one-line hook for the change>

<the video>
```

A Revyl-hosted upload's immutable canonical link is `/api/v1/shiptok/videos/{token}.mp4` or `/api/v1/shiptok/videos/{token}.mov` on the backend, under whatever path it is served from, where `{token}` is the upload's 43-character token of letters, digits, `-` and `_`. It can stand bare in the markdown or behind a linked poster. On a private repository it plays only for a viewer GitHub lets read the repository: a signed-in app presents the person's GitHub token when the link is on the Revyl backend its build names, and playback follows the link's redirect without forwarding GitHub authorization. Uploading again makes a new canonical link and cache identity; the bytes behind an existing link never change.

A video is at most 100 MB (104,857,600 bytes), the limit of a Revyl-hosted upload. The app plays videos from memory, so it stops downloading a larger one, tagged or not, and treats it as media that failed to load.

## Which media shows first

1. The newest tagged ShipTok video, by its description's or comment's last edit, else its creation.
2. Otherwise the first video in deck order: the description first, then comments from oldest to newest.
3. Otherwise the first image or GIF in the same order.

Tags only reorder: every other media item stays in the deck, untagged media included. Hiding a person leaves out their media and applies the same order to what's left.

## Vibes

A swipe posts a top-level comment as the person who swiped:

```markdown
<!-- shiptok:vibe good -->
**Good vibes** via ShipTok

<optional feedback, typed or transcribed>
```

Bad vibes use `<!-- shiptok:vibe bad -->` and `**Bad vibes**`. A comment is a vibe when its first line is exactly the marker. The app counts each person's newest vibe comment on a pull request or week, never a bot's, a new vibe replaces the person's earlier vibe comments there, and undoing a vibe deletes its comment.

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
- Every line reading `<n>. #<number>` names a pull request for the week's deck, in the video's order, and there are 1 to 30 of them. A pull request named twice shows once.
- The issue's own title isn't read; a title like `ShipTok weekly · Nov 9–15` is a convention.
- The media can be in the description or any top-level comment, and no tag is needed: videos, images and GIFs all count, and the card shows them in the same order as a pull request's. An edition with no media doesn't show.

Only closed issues are read, so closing the issue publishes the week, and it shows on the app's next read. Each such issue is a card of its own, so a second issue for the same week is a second card. In the deck, open and merged pull requests with media show; one closed without merging, or with no media, is left out. Vibes, reactions and comments on a week go on its issue in the same formats as on a pull request.
