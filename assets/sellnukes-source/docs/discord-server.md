# Sell Nukes Discord community

Configured in Chrome on 2026-10-30 for the owner. The shared architecture guide remains
`SELLNUKES_CLAUDE_DOCUMENTATION.md`; no runtime code, schema, or game version changed.

## Live links

- Server: https://discord.com/channels/1565864865673912420
- Permanent invite: https://discord.gg/5Kmvjvme4X
- Welcome/rules: https://discord.com/channels/1565864865673912420/1565865712063348787
- Codes: https://discord.com/channels/1565864865673912420/1565873947860533268
- Game: https://www.roblox.com/games/132667741281890/Sell-Nukes
- Roblox social-link settings: https://create.roblox.com/dashboard/creations/experiences/10773845696/social-links

The invite lands in welcome-and-rules, expires Never, has no use limit, grants no roles, and
does not use temporary membership. Server Settings > Invites showed its infinity expiry.
Roblox's Discord social link is titled **Sell Nukes Discord** and persisted after reload.
The separate automatically generated 30-day invite was not published.

## Profile, channels, and roles

Name: **Sell Nukes**. Community enabled. Description:
“Official Sell Nukes community on Roblox. Share your factory, find friends, suggest updates,
and get help from the team.” Traits: Roblox, Tycoon, Pets, Factory Building, Community.
The revised `assets/marketing/2026-10-30-forgegui/final/icon.png` is the server icon.

| Category | Channels | Access |
|---|---|---|
| START HERE | welcome-and-rules, announcements, updates, codes | Public read-only; Developer and Moderator can post. Codes is an Announcement channel. |
| COMMUNITY | general, tips-and-help, factory-showcase, looking-for-players, bot-commands | Public player chat |
| Voice Channels | General | Public voice; no voice session joined during setup |
| FEEDBACK | bug-reports, suggestions | Bug template; Suggestions bot feed with discussion threads |
| SUPPORT | open-a-ticket | Public read-only support panel; Ticket Tool can post |
| STAFF | staff-chat, mod-alerts, ticket-transcripts, bot-logs | Private; Developer/Moderator. Support + Ticket Tool additionally see transcripts; Suggestions Bot additionally sees bot-logs. |
| TICKETS | Individual bot-created tickets | Private to the ticket owner, Developer, Moderator, Support, and Ticket Tool |

START HERE is first in the channel list. Codes includes free-code/redemption guidance without
inventing an active game code. Welcome/rules includes the official game link and navigation.
Gameplay-help, showcase, group-finding, bug-report, and private-support instructions are posted.

Roles: Developer, Moderator, Support, Playtester, Update Pings, Event Pings, Ticket Tool,
Suggestions Bot. Developer has one member (the owner); Moderator and Support have no assigned
members yet. Assign trusted humans through Server Settings > Members when recruiting staff.
Optional ping roles grant no staff powers.

Moderator has message/thread moderation, audit-log, nickname, kick/ban/timeout, mute/move voice
powers. Developer has message/thread, audit-log, and event-management permissions. Neither role
was given Administrator, Manage Server, or Manage Roles. Support has ticket access without
global moderation powers. @everyone cannot mass-mention, create private threads, use external
apps, create expressions, or create events. Discord reported zero risky @everyone permissions.

## Onboarding and moderation

Onboarding and Server Guide are enabled. Ten default channels: welcome-and-rules,
announcements, updates, general, tips-and-help, factory-showcase, looking-for-players,
bug-reports, suggestions, open-a-ticket. The five regular discussion/help channels remain
chattable after the two bot entry feeds became read-only. New public channels, including codes,
remain available in the server channel list.

The optional “Which notifications would you like?” question allows multiple answers:
Game updates assigns Update Pings; Events and announcements assigns Event Pings.
A welcome sign and introductory task lead members into general. Rules are posted and the
guide includes Read the Rules; this document does not claim a separate rules-acceptance gate.

Community rules channel is welcome-and-rules. Community updates and safety notifications go
to mod-alerts. Verified email and all-member sensitive-image filtering are enabled.
Default notifications are mentions only.

Native AutoMod is active:
- Mention spam: blocks messages.
- Suspected spam: blocks messages and alerts mod-alerts.
- Commonly flagged words: severe profanity, insults/slurs, sexual content; blocks and alerts mod-alerts.
- Raid/CAPTCHA protections: UI showed 3/3 enabled.
- DM/spam protections: UI showed 5/5 enabled.

No additional paid moderation bot was needed. No paid subscriptions or unsolicited invitations.

## Ticket Tool

Verified app `557628352828014614`, official site https://tickettool.xyz/.
The owner completed Discord's installation CAPTCHA. Bot setup was then completed with /setup.

Panel **Sell Nukes Support** is posted in open-a-ticket. Support roles are Developer, Moderator,
Support. Tickets are created in private TICKETS. Transcript destination is ticket-transcripts.
The public entry channel denies member messages and thread creation, while explicitly allowing
Ticket Tool to post. Tickets themselves allow the requester to communicate privately.

Verified an owner setup ticket, closed it through the recoverable Close workflow, and used
Transcript. The bot confirmed delivery; ticket-transcripts contains the five-message HTML file.
The clearly labeled setup ticket remains archived as closed-0001, ID `1565873572805611741`.
It was not permanently deleted. Staff can reopen it from the Open control.

## Suggestions

The owner installed verified **Suggestions** (integration role **Suggestions Bot**), official
site https://suggestions.gg/. Configured /setup and /configure guild:
- Destination and Create Suggestion button: suggestions.
- Discussion threads enabled; archive on resolution.
- Outcomes remain on the original suggestion message.
- Private log/update destination: bot-logs (`1565874353848057886`).
- Ordinary members cannot post directly, add reactions, or create arbitrary threads in the feed;
  they can submit through the button and discuss in the bot-created threads.
- Suggestions Bot explicitly can send, add reactions, create/send/manage threads.
- Developer/Moderator may post and have command overrides for /resolve, /approve, /reject,
  /queue, /note, and Resolve Suggestion. Server-management commands retain their defaults.

A clearly labeled setup suggestion about the already-created codes channel was submitted:
sID `9g1vz-s13qy`. The bot created vote controls and a discussion thread; owner marked it
Implemented. No fabricated community votes were added.

Command permission guidance:
https://docs.suggestions.gg/docs/managing-suggestions/
Channel setup guidance: https://docs.suggestions.gg/docs/intro/

## Roblox icon and evidence

Re-uploaded the revised 512px `icon.png` to the start-place icon page and saved. Roblox first
showed a moderation placeholder; a later reload showed the actual revised icon with Save Changes
disabled. `icon-1024.png` remains the high-resolution source; no image files were modified.

Evidence is in `docs/verification/discord/`. The Playtester role preview confirmed public codes
was read-only and STAFF, transcripts, bot logs, TICKETS, and closed-0001 were absent. Role preview
was disabled afterward. The earlier unpublished ten-creative Ads Manager tab was preserved.

## Repository verification

`./scripts/check.sh` was run and stopped on unrelated shared-tree StyLua differences in
LaunchCamMath.luau, LaunchCountdown/CountdownOverlay.luau, and Attack/LaunchCam.luau.
Separate `./scripts/typecheck.sh` reported in-progress WhatsNew/init.luau errors for missing
Note.Icon / Section.Header and optional icon/tag values. Those runtime changes belong to other
ongoing work and were not modified. The mandatory passing check gate blocks committing these
documentation changes. Re-run the project checks after that shared work settles, then commit
only this task's documentation/evidence hunks.
