# The ShipTok format

The contract ShipTok parses, and that anyone posting a ShipTok video, vibe or weekly edition writes to. GitHub is the record: the app reads pull requests, issues and comments, and writes reactions and comments as the signed-in person.

## Which pull requests are in the feed

Merged pull requests in the repository the person chose, never a draft, an open one or one closed without merging, and only when the description or a top-level conversation comment carries uploaded media: a video, image or GIF, for example GitHub attachments and Revyl proof screenshots and recordings. Of those, the feed holds the ones merged in the last 14 days, plus every one labeled `shiptok` whose first media is a ShipTok video, whenever it merged. Badges, shields, avatars, emoji and CI or coverage charts are never media. Inline code-review comments are never read.

## ShipTok video

A video in the description or a top-level conversation comment tagged with case-insensitive `#shiptok` or `<!-- shiptok:video -->`. Attributes after `shiptok:video` are ignored, so markers like `<!-- shiptok:video source=revyl -->` still match. Any author can post one, people and bots alike; the author and host do not change priority.

```markdown
<!-- shiptok:video -->

**ShipTok** · <one-line hook for the change>

<the video>
```

The video is a GitHub attachment or a Revyl-hosted upload link, either bare or behind a linked poster. For hosted uploads, `/api/v1/shiptok/videos/{token}.mp4` or `/api/v1/shiptok/videos/{token}.mov` is the immutable canonical link for that upload; playback follows its redirect without forwarding GitHub authorization. Re-uploading produces another canonical link and cache identity, rather than changing bytes behind an existing link. Comments carrying a ShipTok tag stay out of the discussion list, with or without a video.

## Which media shows first

1. The newest tagged ShipTok video, comparing its description or comment's `lastEditedAt ?? createdAt`.
2. The first other video: the description first, then comments from oldest to newest.
3. The first image or GIF, in the same order.

Tags only reorder: every other media item stays in the deck, and untagged media remains eligible.

## Vibes

A swipe posts a top-level comment as the person who swiped:

```markdown
<!-- shiptok:vibe good -->

**Good vibes** via ShipTok

<optional feedback, typed or transcribed>
```

Bad vibes use `<!-- shiptok:vibe bad -->` and `**Bad vibes**`. The marker is the record the app counts, and undoing a vibe deletes its comment.

## Weekly editions

One closed issue per week, Monday to Sunday in Pacific time, in the chosen repository, labeled `shiptok-weekly` and titled like `ShipTok weekly · Nov 9–15`. Its description:

```markdown
<!-- shiptok:weekly week_start=2026-11-09 -->

## <the week's title>

<a one-line hook>

### Pull requests in this video

1. #12
2. #15
```

The marker is the first line, and its date is a Monday. The `## ` line is the title, and the next non-empty line is the hook. Every `<n>. #<number>` line is a pull request in the week's deck, in the video's order, 1 to 30 of them. The media can be in the description or any top-level comment. The newest tagged video is prioritized by the same timestamp rule as a pull request, but a tag is not required: untagged videos, images and GIFs remain eligible. Only closed issues are read, so closing the issue publishes the week. Vibes, reactions and comments on a week go on its issue in the same formats as on a pull request.

## Label

The `shiptok` label retains a merged pull request beyond the two-week window when its first media is a tagged ShipTok video. The label alone does not tag media.
