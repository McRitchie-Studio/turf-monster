# The agent chat on Turf

`/chat` is a chat with Turf (the `turf_monster` soul) with hold to talk, built on
the engine's primitive: studio-engine `docs/AGENT_CHAT.md`, `docs/VOICE_CAPTURE.md`,
`docs/VOICE_TRANSCRIPTION.md`. The hub holds every message; this app stores none.

**Admins only while it is tested.** `Studio.agent_chat_allowed` in
`config/initializers/studio.rb` is the gate. The engine's `/agent_chat` routes skip
sign-in, so the page and the footer link are not the gate. A player and a signed-out
visitor are refused before any hub call:

| Viewer | `/chat` | `/agent_chat/*` | `POST /voice/takes` | Footer link |
|--------|---------|-----------------|---------------------|-------------|
| Admin | the chat, with the microphone | answered | answered | Contact, Chat |
| Player | to the home page | 403 | 403 | none |
| Player with no username | to complete profile | 302 | 302 | none |
| Signed out | to sign in | 403 | 401 | none |

## Config

| Variable | Where | Note |
|----------|-------|------|
| `AGENT_CHAT_TOKEN` | production, QA | 1Password `agent-chat.turf-monster.applications`. The hub stores its digest. Set it on production only after the hub's `chat-caps-count-held-messages` is live. Without it the page says it can't reach Turf. |
| `STUDIO_VOICE_OPENAI_API_KEY` | production | This app's own key, never another app's. Without it a take answers the `not_configured` line. Set a budget alert on its OpenAI project. |
| `STUDIO_VOICE_TRANSCRIBER` | optional | QA is `mock` in code (`TurfVoiceConfig`), so QA needs no key. |
| `LOCAL_STUB_HUB=1` | a desk, `.env.development.local` | `/chat` answers from a stand-in hub in the process. |

The take limit is in [`RATE_LIMITING.md`](RATE_LIMITING.md#voice-takes). The hub lists
this app for the soul in its `config/agent_routes.yml` (`web: apps:`).

## Who gets an answer

The proxy sends the hub `current_user.email` only when `email_verified_at` is
present. Everyone else is an anonymous visitor.

- **`email_verified_at`.** A magic link stamps it, and so does a Google sign-in that
  creates or links the row. A wallet sign-in does not, and a seeded row reads
  unverified until its first email sign-in. Changing the address clears it.
  On a roster address, a magic link is refused when the row holds a wallet other than
  the roster's (`User#accept_mailbox_proof!`); `users:parked_role_audit` lists those.
- **The hub answers by role** (hub `config/agent_answerers.yml`). Today only the owner
  role is answered on Turf's soul, so a message from the owner's verified address is
  answered, and any other admin's message is stored as `held`, as is an anonymous one.
  The public-intake exception covers only the `alex` soul.
- **Every chat thread is answered as the public**, even for the owner (hub
  `MemoryBundle#audience_person`): no owner action and no internal context.

## Not on

`voice_profile` is off, so no voice is matched and every take says "Someone new".
Turning it on needs the CSP entries in studio-engine `docs/VOICE_PROFILE.md`.
