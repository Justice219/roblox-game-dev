#!/usr/bin/env python3
"""
studio-lock.py — owner-aware mutex for Roblox Studio playtests shared by several agents.

Only one playtest (StudioTestService run/play mode) can run at a time in the open Studio place,
and several Claude agents share it. This lock guarantees mutual exclusion AND that an agent can
only release a lock it actually holds (a plain `mkdir`/`rmdir` lock let an agent that FAILED to
acquire it delete someone else's lock).

Usage:
    python3 scripts/studio-lock.py acquire <owner-name> [timeout-seconds]   # blocks; exit 0 when held
    python3 scripts/studio-lock.py release <owner-name>                     # no-op unless you hold it
    python3 scripts/studio-lock.py refresh <owner-name>                     # extend a lock you hold
    python3 scripts/studio-lock.py status                                   # holder + waiting queue
    python3 scripts/studio-lock.py grant <owner-name> <seconds>             # LEAD ONLY: one longer turn
    python3 scripts/studio-lock.py prioritize <owner-name> [wait-seconds]   # LEAD ONLY: owner goes next

Fairness: waiters queue first-come-first-served. `acquire` drops a ticket in the queue directory
and only takes the lock when its ticket is the oldest live one, so no agent can be starved by
others that happen to poll at the right moment. A waiting `acquire` touches its ticket every poll;
tickets not touched for TICKET_STALE_SECONDS (the waiter died) are dropped, and a timed-out or
interrupted acquire removes its own ticket.

A lock older than STALE_SECONDS is considered abandoned (its holder crashed) and may be taken
over; so may a lock whose holder has had it MAX_TURN_SECONDS (10 min) while others wait —
`refresh` does not extend a turn. Never release a lock you did not acquire. Release it as soon as your playtest batch is
done; if one batch can run longer than ~15 minutes, `refresh` it while you wait (otherwise
another agent may take it over mid-run and both playtests fail).

Grants (lead only): `grant <owner> <seconds>` records ONE longer turn (at most MAX_GRANT_SECONDS)
for <owner>'s next acquire, e.g. a trailer capture block that cannot be split into 10-minute
turns. It does not change queue order. When <owner> acquires, the lock records `turnUntil` and its
turn is not over until then (`refresh` keeps it, so a long block must still refresh at least every
STALE_SECONDS). Unused grants expire after GRANT_TTL_SECONDS. Waiters started by an older copy of
this script ignore `turnUntil`, so restart any acquire that was already waiting behind the granted
owner when the grant was made.

Priority (lead only): `prioritize <owner> [wait-seconds]` puts <owner> at the FRONT of the queue
(e.g. a recording block while the owner is at the desk). It creates the queue ticket
PRIORITY_TICKET_STAMP-<owner>, which sorts before every real arrival time, and keeps it alive
(touch only, never re-create) until <owner>'s own `acquire` adopts it — `ticket_path` reuses an
existing ticket with the owner's name — and takes the lock, or the ticket disappears, or
wait-seconds (default 300) pass without that, in which case the ticket is withdrawn. Start it
BEFORE <owner> starts its acquire. Works with every waiter already queued, because they only
compare ticket names. It never interrupts the current holder's turn.
"""

import json
import os
import sys
import time

# SellNukes: a stable per-user path so every session/agent on this machine shares one Studio lock.
LOCK_DIR = os.path.join(os.path.expanduser("~"), ".cache", "sellnukes", "studio.lock")
os.makedirs(os.path.dirname(LOCK_DIR), exist_ok=True)
OWNER_FILE = os.path.join(LOCK_DIR, "owner.json")
QUEUE_DIR = LOCK_DIR + ".queue"
STALE_SECONDS = 1200  # 20 min without a refresh = the holder crashed
MAX_TURN_SECONDS = 600  # 10 min per turn while others wait (refreshing does not extend a turn)
TICKET_STALE_SECONDS = 30  # a waiter that has not polled for this long is gone
POLL_SECONDS = 2
GRANT_FILE = LOCK_DIR + ".grant.json"  # outside LOCK_DIR so release's rmdir never sees it
MAX_GRANT_SECONDS = 1800  # 30 min: the longest single turn the lead may grant
GRANT_TTL_SECONDS = 7200  # an unused grant lapses after 2 h
PRIORITY_TICKET_STAMP = f"{0:017.6f}"  # sorts before every real time.time() stamp


def ticket_path(owner):
    # One ticket per owner; the file name carries the arrival time so `sorted` is FIFO order.
    for name in os.listdir(QUEUE_DIR):
        if name.split("-", 1)[1:] == [owner]:
            return os.path.join(QUEUE_DIR, name)
    return os.path.join(QUEUE_DIR, f"{time.time():017.6f}-{owner}")


def live_tickets():
    """Queue entries (oldest first) whose waiter is still polling; prunes dead ones."""
    now = time.time()
    tickets = []
    for name in sorted(os.listdir(QUEUE_DIR)):
        path = os.path.join(QUEUE_DIR, name)
        try:
            if now - os.path.getmtime(path) > TICKET_STALE_SECONDS:
                os.remove(path)
                continue
        except OSError:
            continue
        tickets.append(path)
    return tickets


def read_owner():
    try:
        with open(OWNER_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def turn_over(info, now):
    """True once a holder has used up its turn (MAX_TURN_SECONDS since it ACQUIRED the lock, or
    its granted `turnUntil`, whichever is later). Locks written by an older script have no
    `acquired`: their turn is measured from `since` (the moment they were taken), so a fresh
    holder is never cut off mid-run."""
    acquired = info.get("acquired", info.get("since", now))
    turn_until = info.get("turnUntil")
    if isinstance(turn_until, (int, float)) and now < turn_until:
        return False
    return now - acquired > MAX_TURN_SECONDS


def take_grant(owner, now):
    """`turnUntil` for `owner` if the lead granted it a longer turn (the grant is consumed)."""
    try:
        with open(GRANT_FILE) as f:
            grant = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(grant, dict) or grant.get("owner") != owner:
        return None
    seconds, granted = grant.get("seconds"), grant.get("granted")
    try:
        os.remove(GRANT_FILE)
    except OSError:
        return None  # someone else consumed or withdrew it
    if not isinstance(seconds, (int, float)) or not isinstance(granted, (int, float)):
        return None
    if now - granted > GRANT_TTL_SECONDS:
        return None
    return now + min(float(seconds), MAX_GRANT_SECONDS)


def try_acquire(owner):
    """Called only by the waiter at the FRONT of the queue (so someone is always waiting)."""
    try:
        os.mkdir(LOCK_DIR)
    except FileExistsError:
        info = read_owner()
        # Taken over when the holder crashed (no refresh for STALE_SECONDS) or its turn is over
        # (MAX_TURN_SECONDS since acquiring, while we wait). Ownerless lock dirs (old protocol) are
        # respected until stale.
        try:
            age = time.time() - os.path.getmtime(LOCK_DIR)
        except OSError:
            return False
        now = time.time()
        since = info.get("since", 0) if info is not None else now - age
        expired = now - since > STALE_SECONDS or (info is not None and turn_over(info, now))
        if expired:
            try:
                if os.path.exists(OWNER_FILE):
                    os.remove(OWNER_FILE)
                os.rmdir(LOCK_DIR)
            except OSError:
                return False
            return try_acquire(owner)
        return False
    now = time.time()
    record = {"owner": owner, "since": now, "acquired": now}
    turn_until = take_grant(owner, now)
    if turn_until is not None:
        record["turnUntil"] = turn_until
    with open(OWNER_FILE, "w") as f:
        json.dump(record, f)
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    command = sys.argv[1]
    if command == "status":
        info = read_owner()
        print(json.dumps(info) if info else "free")
        try:
            with open(GRANT_FILE) as f:
                print("grant: " + f.read().strip())
        except OSError:
            pass
        if os.path.isdir(QUEUE_DIR):
            waiting = [os.path.basename(p).split("-", 1)[1] for p in live_tickets()]
            if waiting:
                print("queue: " + ", ".join(waiting))
        return
    if len(sys.argv) < 3:
        sys.exit("owner name required")
    owner = sys.argv[2]
    if command == "acquire":
        timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 900
        start = time.time()
        os.makedirs(QUEUE_DIR, exist_ok=True)
        ticket = ticket_path(owner)
        try:
            while True:
                # Keep our place in the queue alive (dead waiters stop touching theirs). Another
                # waiter may prune our ticket between the create and the touch (e.g. after the Mac
                # slept and every ticket looked stale): recreate it on the next poll instead of
                # crashing. The ticket keeps its original name, so our FIFO position is unchanged.
                try:
                    with open(ticket, "a"):
                        pass
                    os.utime(ticket)
                except FileNotFoundError:
                    time.sleep(POLL_SECONDS)
                    continue
                tickets = live_tickets()
                if tickets and tickets[0] == ticket and try_acquire(owner):
                    break
                if time.time() - start > timeout:
                    info = read_owner()
                    sys.exit(
                        f"lock timeout (held by {info.get('owner') if info else 'unknown'}) — do NOT release it"
                    )
                time.sleep(POLL_SECONDS)
        finally:
            try:
                os.remove(ticket)
            except OSError:
                pass
        print(f"locked by {owner}")
    elif command == "refresh":
        info = read_owner()
        if info is None or info.get("owner") != owner:
            sys.exit(f"not held by {owner}; nothing refreshed")
        now = time.time()
        waiting = live_tickets() if os.path.isdir(QUEUE_DIR) else []
        if waiting and turn_over(info, now):
            sys.exit(
                f"turn over ({len(waiting)} waiting): finish the run in progress, release and re-queue"
            )
        record = {"owner": owner, "since": now, "acquired": info.get("acquired", now)}
        if "turnUntil" in info:
            record["turnUntil"] = info["turnUntil"]  # a granted long turn survives refreshes
        with open(OWNER_FILE, "w") as f:
            json.dump(record, f)
        os.utime(LOCK_DIR)
        print(f"refreshed by {owner}")
    elif command == "grant":
        if len(sys.argv) < 4:
            sys.exit("usage: grant <owner-name> <seconds>")
        try:
            seconds = float(sys.argv[3])
        except ValueError:
            sys.exit("seconds must be a number")
        if not (0 < seconds <= MAX_GRANT_SECONDS):
            sys.exit(f"seconds must be in (0, {MAX_GRANT_SECONDS}]")
        with open(GRANT_FILE, "w") as f:
            json.dump({"owner": owner, "seconds": seconds, "granted": time.time()}, f)
        print(f"granted {owner} one {seconds:.0f} s turn (applies at its next acquire)")
    elif command == "prioritize":
        try:
            wait = float(sys.argv[3]) if len(sys.argv) > 3 else 300.0
        except ValueError:
            sys.exit("wait-seconds must be a number")
        os.makedirs(QUEUE_DIR, exist_ok=True)
        for name in os.listdir(QUEUE_DIR):
            if name.split("-", 1)[1:] == [owner]:
                sys.exit(f"{owner} is already queued ({name}); prioritize before it starts its acquire")
        ticket = os.path.join(QUEUE_DIR, f"{PRIORITY_TICKET_STAMP}-{owner}")
        with open(ticket, "w"):
            pass
        print(f"{owner} is first in the queue; waiting up to {wait:.0f} s for its acquire")
        sys.stdout.flush()
        deadline = time.time() + wait
        while True:
            info = read_owner()
            if info is not None and info.get("owner") == owner:
                print(f"{owner} holds the lock")
                return
            try:
                os.utime(ticket)  # touch only: once the owner's acquire removes it, it stays gone
            except FileNotFoundError:
                print(f"{owner}'s priority ticket was consumed or pruned")
                return
            if time.time() > deadline:
                try:
                    os.remove(ticket)
                except OSError:
                    pass
                sys.exit(f"{owner} never took its priority turn; ticket withdrawn")
            time.sleep(POLL_SECONDS)
    elif command == "release":
        info = read_owner()
        if info is None or info.get("owner") != owner:
            print(f"not held by {owner}; nothing released")
            return
        os.remove(OWNER_FILE)
        os.rmdir(LOCK_DIR)
        print(f"released by {owner}")
    else:
        sys.exit(f"unknown command {command}")


if __name__ == "__main__":
    main()
