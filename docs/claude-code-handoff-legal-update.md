# Handoff prompt for Claude Code — implement legal-doc updates

Copy everything in the block below into Claude Code from the repo root.

---

You're working in the Zerro monorepo. An audit compared our Privacy Policy and Terms of Service against the actual product (desktop app v1.4.19, website, and Supabase backend) and found gaps.

**First, read the full review — it is your source of truth:** `docs/privacy-terms-review-2026-06-27.md`. It has the rationale, exact code citations, and suggested wording for every item below. Read it before editing.

**Files to edit:**
- `apps/web/app/privacy/page.tsx`
- `apps/web/app/terms/page.tsx`
- `apps/web/components/templates/axis/footer.tsx` (item #7 only)

**Keep the existing structure and style.** These pages render via the `LegalShell`, `LegalSection`, `P`, `UL`, `Strong` components in `apps/web/components/legal/legal-shell.tsx`. Match the existing JSX patterns, HTML-entity escaping (`&ldquo;`, `&rsquo;`, `&rarr;`, etc.), prose voice, and section ordering. Do not restructure the pages or swap components.

**Implement these changes (full wording/rationale in the review):**

1. (🔴 #1 — must fix) Privacy → "Information we collect → Account information": remove the "If you sign in with Apple or Google…" claim — the app has no Apple/Google sign-in. It only does email + 6-digit verification code (trials) and Lemon Squeezy license-key activation; auth/database via Supabase. Also review Terms → "Accounts" and adjust any language implying a password/credentials account model that doesn't exist.

2. (🔴 #2 — must fix) Disclose "Dev Mode" / the Claude Code agent:
   - **Privacy:** add a subsection describing Dev Mode — it spawns Claude Code (Anthropic's coding-agent CLI) locally inside the user's project directory, can read/edit files and run commands (sandboxed), and reads the browser's current localhost URL via Apple Events. Add **Anthropic (Claude Code)** to the Service providers list, distinguishing its dev-agent role from the model-API role.
   - **Terms:** add coverage that the agent acts at the user's direction, can modify files and run commands, the user is responsible for reviewing changes and using version control, and it's provided "as is." Fold into the existing Disclaimers / Limitation of liability sections.

3. (🟠 #3 — high) Privacy → Service providers: add **Slack** (internal feedback/support routing); note that feedback you submit may include your email if you're signed in.

4. (🟡 #5) Privacy: soften "processed in memory" → transient handling (held briefly on your device and in memory during generation, never written to our database). Locations: "The short version" and "Data retention."

5. (🟡 #6) Privacy: acknowledge that an anonymous analytics identifier may be associated with checkout/subscription events (affiliate `?aff` code + IP, and the PostHog `distinct_id` passed into checkout custom_data). Disclose affiliate attribution as a website data flow; use "pseudonymous" rather than "anonymous" where that linkage applies.

6. (🟢 #8) Where the AI provider is named "Google," use "Google (Gemini)" for precision (the app labels it Gemini).

7. (🟢 #9) Note that BYOK transcription always uses the user's OpenAI key (Whisper), even when the selected chat model is Anthropic or Gemini.

8. (🟢 #7) `footer.tsx`: align the support email to `support@getzerro.app` (it currently shows `support@smartaiscaling.com`). If you're unsure which address is canonical, ask me before changing.

9. (🟢 #10) Bump both `LAST_UPDATED` constants (privacy and terms) to today's date.

10. (🟢 #11) Privacy → Security: adjust wording so it doesn't over-imply that all identifiers are hashed (emails are stored in plaintext for billing/trials).

**Do NOT touch the legal substance of these — they're awaiting attorney review (item #4):** the `DRAFT — pending attorney review` sections for regulated data (HIPAA/PCI), Indemnification, Dispute resolution / arbitration + class-action waiver, and the professional-advice disclaimer. Leave those `DRAFT` comments in place; do not draft or rewrite their legal language. For the new Dev Mode liability text in #2, keep it conservative and add a `{/* DRAFT — pending attorney review */}` comment so counsel reviews it.

**When done:** run `cd apps/web && npm run lint && npm run build` (or the project's typecheck) to confirm the pages compile, then give me a short per-file summary of what changed. Don't commit unless I ask.
