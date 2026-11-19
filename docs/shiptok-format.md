# The ShipTok format

What ShipTok parses, and what anyone posting a ShipTok video, vibe or weekly edition writes to. GitHub is the record: the app reads pull requests, issues and comments, and writes reactions and comments as the signed-in person.

## Which pull requests are in the feed

Open and merged pull requests in the repository the person chose, drafts included, and never one closed without merging. A pull request is in the feed only when its description or a top-level conversation comment carries uploaded media: a video, image or GIF, such as a GitHub attachment or a Revyl proof screenshot or recording. Badges, shields, avatars, emoji and CI or coverage charts are never media, and inline code-review comments are never read.

Open holds the open pull requests and Merged the merged ones, whatever their age; no label or time window decides. With Videos only on, as it is unless the person turns it off, a pull request shows only when its first media item (see below) is a video.

## ShipTok video

A video in the description or a top-level conversation comment, tagged with `#shiptok` in any case or with `<!-- shiptok:video -->`. Anything after `shiptok:video` in the marker is ignored, so `<!-- shiptok:video source=revyl -->` matches too. Anyone can post one, people and bots alike, and neither the author nor the host changes its priority.

```markdown
<!-- shiptok:video -->

**ShipTok** · <one-line hook for the change>

<the video>
```

The video is a GitHub attachment or a Revyl-hosted upload link, bare or behind a linked poster. A hosted upload's immutable canonical link is `/api/v1/shiptok/videos/{token}.mp4` or `/api/v1/shiptok/videos/{token}.mov` on the backend, under whatever path it is served from, where `{token}` is the upload's 43-character token of letters, digits, `-` and `_`. On a private repository it plays only for a viewer GitHub lets read the repository: a signed-in app presents the person's GitHub token when the link is on the Revyl backend its build names, and playback follows the link's redirect without forwarding GitHub authorization. Uploading again makes a new canonical link and cache identity; the bytes behind an existing link never change. Comments carrying a ShipTok tag stay out of the discussion list, with or without a video.

A video is at most 100 MB (104,857,600 bytes), the limit of a Revyl-hosted upload. The app plays videos from memory, so it stops downloading a larger one, tagged or not, and treats it as media that failed to load.

## Which media shows first

1. The newest tagged ShipTok video, by its description's or comment's `lastEditedAt ?? createdAt`.
2. The first other video: the description first, then comments from oldest to newest.
3. The first image or GIF, in the same order.

Tags only reorder: every other media item stays in the deck, untagged media included.

## Vibes

A swipe posts a top-level comment as the person who swiped:

```markdown
<!-- shiptok:vibe good -->
**Good vibes** via ShipTok

<optional feedback, typed or transcribed>
```

Bad vibes use `<!-- shiptok:vibe bad -->` and `**Bad vibes**`. The marker is what the app counts, and undoing a vibe deletes its comment.

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

The marker is the first line, and its date is a Monday. The `## ` line is the title and the next non-empty line the hook. Each `<n>. #<number>` line names a pull request in the week's deck, in the video's order, 1 to 30 of them; open and merged ones show, and one closed without merging is skipped. The media can be in the description or any top-level comment. The newest tagged video comes first by the same timestamp rule as on a pull request, but no tag is needed: untagged videos, images and GIFs all count. Only closed issues are read, so closing the issue publishes the week. Vibes, reactions and comments on a week go on its issue in the same formats as on a pull request.
