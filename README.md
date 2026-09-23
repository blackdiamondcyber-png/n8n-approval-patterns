# Tokenized Multi-Stage Approval Workflows

[![tests](https://github.com/blackdiamondcyber-png/n8n-approval-patterns/actions/workflows/ci.yml/badge.svg)](https://github.com/blackdiamondcyber-png/n8n-approval-patterns/actions/workflows/ci.yml)

An n8n pattern for approvals that move through several people who will not log
into anything. The approver gets an email, clicks one link, and it is done. No
account, no portal, no password reset at 9pm.

I built this for an internal events system where a proposal had to clear a
manager and then a regional lead before anything shipped. Chasing approvals
over email threads was the bottleneck. This removed it.

## The problem with the obvious approach

The naive version puts a decision in the URL: `/approve?id=42&decision=yes`.
Three things go wrong immediately.

**Anyone can guess it.** Sequential ids mean approving request 43 is one
keystroke away.

**Email scanners click links.** Corporate mail security and Outlook link
preview both fetch URLs before a human sees them. A GET request that changes
state will fire on its own, and you will approve things nobody read.

**Nothing expires.** A link sitting in an inbox for eight months still works.

## The pattern

One single-use token per stage per approver, stored server-side.

```
proposal created
   -> stage 1 token minted, emailed to approver A
   -> A clicks -> lands on a confirmation page (GET, no state change)
   -> A confirms -> POST consumes the token
   -> stage 2 token minted, emailed to approver B
   -> ...
   -> final stage consumes -> proposal moves to approved
```

Design decisions that matter:

| Decision                                      | Why                                             |
| --------------------------------------------- | ----------------------------------------------- |
| Token is a random 32-byte value, not an id    | Not guessable, not enumerable                   |
| Token stored hashed                           | A database read does not hand out working links |
| GET renders a confirmation page; POST commits | Link scanners cannot approve anything           |
| Single use, consumed on commit                | Forwarded emails stop working                   |
| Expiry, default 14 days                       | Stale approvals do not linger                   |
| One token per stage                           | Approver B's link cannot skip stage 1           |
| Every decision written to an audit row        | You can answer "who approved this and when"     |

## What is here

| Path                           | Contents                                          |
| ------------------------------ | ------------------------------------------------- |
| `workflow/approval-chain.json` | n8n workflow, importable, 12 nodes                |
| `sql/approvals.sql`            | Tables, token minting, and consumption            |
| `sql/audit.sql`                | Append-only decision log. Run approvals.sql first |
| `tests/approvals-tests.sql`    | Assertions against the token lifecycle and audit  |

Run `approvals.sql` before `audit.sql`: the audit trigger attaches to a table
`approvals.sql` creates.

## Importing the workflow

n8n -> Workflows -> Import from File -> `workflow/approval-chain.json`.

Set these credentials and variables after import:

- `SMTP` credential for the mail node
- `POSTGRES` credential for the database nodes
- `APP_BASE_URL` environment variable, used to build approval links

## Notes from running it

**Mint the next token only after the previous stage commits.** Minting the
whole chain up front means approver B can act before approver A, which defeats
the point of a chain.

**Put nothing sensitive in the link.** The token is a lookup key. Everything
the approver needs to see gets fetched server-side and rendered on the
confirmation page. Query strings leak through referrer headers and browser
history.

**Rejections need a reason field.** Without one you get a rejected item and no
idea why, and the requester emails you anyway. The whole point was removing
that email.

**Send a digest, not a nag.** In my deployment, one reminder at 72 hours moved
more approvals than daily emails had, and people stopped filtering the sender.
That is what I saw with one team, not a measured result.

## License

MIT.

More of my work: [erik-pearson-portfolio.vercel.app](https://erik-pearson-portfolio.vercel.app). Contact: [LinkedIn](https://www.linkedin.com/in/erikpearson2).
