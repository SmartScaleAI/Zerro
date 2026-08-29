import type { Metadata } from "next"
import {
  LegalShell,
  LegalSection,
  P,
  UL,
  Strong,
} from "@/components/legal/legal-shell"
import { LICENSE_MAC_COUNT, TRIAL_DAYS } from "@/lib/product-facts"

// LEGAL REVIEW: owner/legal should confirm the final wording before
// publishing, in particular the Lemon Squeezy data description, the
// analytics anonymous-vs-pseudonymous explanation, and the retention list.

export const metadata: Metadata = {
  title: "Privacy Policy",
  description:
    "How Zerro collects, uses, and protects your data, including what happens to your screen recordings and audio.",
  alternates: { canonical: "/privacy" },
}

const LAST_UPDATED = "August 24, 2026"

export default function PrivacyPage() {
  return (
    <LegalShell title="Privacy Policy" lastUpdated={LAST_UPDATED}>
      <LegalSection title="Who we are">
        <P>
          Zerro is operated by <Strong>SmartScale Solutions LLC</Strong>{" "}
          (&ldquo;SmartScale&rdquo;, &ldquo;we&rdquo;, &ldquo;us&rdquo;). Zerro
          is an open-source, bring-your-own-key macOS menu-bar app that lets
          you record a region of your screen, dictate what you want, and
          receive exactly what you need: an agent prompt, a message, a
          snippet, a document, or a clear answer to your question. This policy
          explains what data we collect through the Zerro app and the
          getzerro.app website, how we use it, and the choices you have.
          Questions? Email us at{" "}
          <a
            href="mailto:support@getzerro.app"
            className="text-foreground underline underline-offset-4"
          >
            support@getzerro.app
          </a>
          .
        </P>
      </LegalSection>

      <LegalSection title="The short version">
        <UL>
          <li>
            <Strong>We never receive your recordings.</Strong> Screen frames,
            audio, transcripts, prompts, and results never reach a server we
            operate. Your Mac prepares the recording and talks directly to
            the AI provider you chose, using your own API key.
          </li>
          <li>
            <Strong>Processing starts on your Mac.</Strong> Your recording is
            prepared locally, and best-effort secret redaction runs on your
            Mac before anything leaves it. Redaction covers detected on-screen
            text only, not what you say.
          </li>
          <li>
            <Strong>Your keys stay in your macOS Keychain.</Strong> Provider
            API keys are stored by the app in the Keychain on your Mac and are
            sent only to the provider they belong to.
          </li>
          <li>
            <Strong>No account.</Strong> Zerro has no user accounts. The free
            trial is a {TRIAL_DAYS}-day clock stored on your Mac and needs no
            email; a purchased license is activated with a license key.
          </li>
          <li>
            <Strong>We do not sell your personal information</Strong> or share
            it for cross-context behavioral advertising.
          </li>
          <li>
            <Strong>Anonymous analytics are optional.</Strong> The app collects
            anonymous usage and crash diagnostics (metadata only, never your
            recordings, transcripts, or prompts) to improve reliability, and
            you can turn it off any time in Settings.
          </li>
        </UL>
      </LegalSection>

      <LegalSection title="Information we collect">
        <P>
          <Strong>Recordings and generation.</Strong> When you start a
          recording, the app captures the screen region you select and your
          voice. Everything that follows begins on your Mac: the app prepares
          the recording, transcribes your narration (see Transcription below),
          and masks detected secrets. This masking is best-effort: it scans
          on-screen text for common structured secrets (such as API keys and
          tokens), so it can miss things, and it does not apply to what you
          say. To generate your result, the app sends the prepared screen
          frames together with the transcript and generation prompt directly
          from your Mac to the third-party AI provider you selected (OpenAI,
          Google (Gemini), or Anthropic), using your own API key, and the
          result comes straight back to your Mac. Your audio is not sent to
          the generation provider. Zerro does not receive, relay, cache, or
          store your recordings, frames, audio, transcripts, prompts, or
          results on any server we operate.
        </P>
        <P>
          <Strong>Transcription.</Strong> By default, your narration is
          transcribed on your Mac by a local speech model that the app
          downloads once; with local transcription your audio stays on your
          Mac. If you choose OpenAI transcription in Settings, your audio is
          sent directly from your Mac to OpenAI using your own OpenAI API key,
          and OpenAI returns the transcript to your Mac.
        </P>
        <P>
          You must not submit data subject to special legal protection, such as
          HIPAA-covered health information or PCI-regulated payment card data;
          see the Acceptable use section of our{" "}
          <a
            href="/terms"
            className="text-foreground underline underline-offset-4"
          >
            Terms of Service
          </a>
          .
        </P>
        <P>
          <Strong>Provider API keys.</Strong> The OpenAI, Google (Gemini), and
          Anthropic keys you add are stored locally in your macOS Keychain and
          are transmitted only to the provider each key belongs to. We never
          receive them. Your use of each provider, including how it processes
          your content and what it charges you, is governed by your own
          agreement with that provider.
        </P>
        <P>
          <Strong>Free trial.</Strong> The first time an official build runs
          on a Mac it begins a {TRIAL_DAYS}-day free trial, recorded in that
          Mac&rsquo;s Keychain; reinstalling the app does not reset it. The
          trial requires no email, no account, and no contact with our
          servers, and nothing about it is sent to us.
        </P>
        <P>
          <Strong>License and billing.</Strong> Purchases are processed by
          Lemon Squeezy, our merchant of record. We never see or store your
          full card number. Lemon Squeezy shares with us the order details
          needed to support you, such as the email address you used at
          checkout, the license key it issued, and the purchase and refund
          history. When you activate a license, the app contacts Lemon
          Squeezy&rsquo;s License API directly from your Mac to activate,
          validate, and deactivate the key on up to {LICENSE_MAC_COUNT} Macs;
          that exchange carries the license key, a per-Mac activation
          identifier, and a device name. Your license key and the local
          activation credentials are stored in your Mac&rsquo;s Keychain,
          while Lemon Squeezy retains the activation records for the key. Zerro
          operates no license server of its own.
        </P>
        <P>
          <Strong>Dev Mode (optional).</Strong> If you turn on Dev Mode, Zerro
          launches the coding-agent CLI you select (Claude Code, Codex, or
          Cursor) locally on your Mac, inside the project folder you choose.
          Acting at your direction, the agent can read and modify files in
          that folder and run commands there. Zerro applies sandboxing and
          permission controls where the selected agent supports them; the
          controls differ by agent and do not guarantee that every agent is
          confined to the folder you select. To match your recording to the
          right project, Zerro can read the address of your active browser
          tab via Apple Events, but it only ever uses a local (localhost)
          address to detect the development-server port; any non-local
          address is discarded the instant it is seen, and is never stored,
          logged, or transmitted. Your project files stay on your Mac and are
          not sent to SmartScale; when the selected agent runs, it
          communicates with its own provider under the terms of the account
          you hold with that provider (Anthropic for Claude Code, OpenAI for
          Codex, or Cursor).
        </P>
        <P>
          <Strong>App analytics and crash reports.</Strong> The Zerro desktop
          app uses PostHog to collect anonymous product-usage events (such as
          completing onboarding, starting a recording, or copying a result) and
          diagnostic crash and error reports. These contain only metadata
          (event names, timings, app version, model identifiers, and error
          types) and never your recordings, transcripts, generated prompts,
          file paths, API keys, or license key. They are keyed to a random
          analytics identifier generated on your Mac, not to your name or
          email, so they are anonymous unless that identifier is later
          connected with a checkout as described below. You can turn analytics
          off at any time in the app under Settings &rarr; &ldquo;Send
          Anonymous Usage Data &amp; Crash Reports.&rdquo;
        </P>
        <P>
          <Strong>Website analytics.</Strong> The getzerro.app website uses
          PostHog to collect anonymous product-usage metadata (page views,
          referrer and campaign source, device and browser type, and
          interaction events such as clicking a download button or expanding an
          FAQ), along with aggregated heatmaps of where visitors click and
          scroll. This is metadata only and is not tied to your name or email.
          We do not record your browsing session, and the site is cookieless:
          PostHog sets no cross-site tracking cookies and keeps no identifier
          between visits.
        </P>
        <P>
          <Strong>Checkout.</Strong> Checkout opens from the Mac app. If
          analytics is enabled, the app passes its analytics identifier into
          the Lemon Squeezy checkout so that a completed purchase can be
          matched back to the app&rsquo;s usage events. From that point the
          identifier, and the app analytics keyed to it, can be linked to
          your order, so they are pseudonymous rather than anonymous, though
          they are still not keyed to your name or email. The license key that
          Lemon Squeezy hands back to the app after checkout is kept out of
          our website analytics.
        </P>
        <P>
          <Strong>Downloads and updates.</Strong> When you download the app or
          it checks for an update, the request reaches our hosting providers
          like any web request. Their standard server logs record the IP
          address, time, and file requested, and are used only to serve the
          file and for ordinary operational logging and abuse prevention.
        </P>
        <P>
          <Strong>Support communications.</Strong> If you email us, we keep
          the correspondence, including your email address and whatever you
          choose to include, so we can respond and keep a record of the
          request.
        </P>
      </LegalSection>

      <LegalSection title="How we use your information">
        <UL>
          <li>To provide the official app: distributing it, delivering updates, and supporting your license.</li>
          <li>To process payments and prevent fraud and abuse, including license enforcement in official builds.</li>
          <li>To respond to support requests.</li>
          <li>To understand aggregate usage of our website and improve the product.</li>
          <li>To diagnose crashes and errors and improve the app&rsquo;s reliability.</li>
          <li>To comply with legal obligations.</li>
        </UL>
        <P>
          We never receive your recordings, transcripts, or generated prompts,
          so we cannot and do not use them for anything, including training AI
          models.
        </P>
      </LegalSection>

      <LegalSection title="Service providers">
        <P>
          We share data with a small set of providers, each only to the extent
          needed to run Zerro: <Strong>Lemon Squeezy</Strong> (payments as
          merchant of record, and license activation and validation),{" "}
          <Strong>PostHog</Strong> (app and website analytics and crash
          reporting), <Strong>Vercel</Strong> (website hosting), and{" "}
          <Strong>GitHub</Strong> (hosting for the source code, the app
          download, and the update feed). We do not sell your personal
          information to anyone.
        </P>
        <P>
          <Strong>OpenAI</Strong>, <Strong>Google (Gemini)</Strong>, and{" "}
          <Strong>Anthropic</Strong> receive the prepared frames, transcripts,
          and prompts directly from your Mac under your own API key and your
          own agreement with them, and OpenAI also receives your audio if you
          choose OpenAI transcription; we are not a party to that processing.
          Whether a provider uses your inputs to train its models, and what it
          charges, is determined by the provider and the API terms you
          accepted. The same applies to the coding agent you select for Dev
          Mode (Claude Code, Codex, or Cursor), which runs locally and
          communicates with its own provider under the account you hold with
          it.
        </P>
      </LegalSection>

      <LegalSection title="Data retention">
        <UL>
          <li>
            <Strong>Screen frames, audio, transcripts, prompts, results:</Strong>{" "}
            never held by us. They exist on your Mac and with the AI provider
            you sent them to, under that provider&rsquo;s retention terms.
          </li>
          <li>
            <Strong>Provider API keys, trial state, license key, and activation credentials:</Strong>{" "}
            stored only in your Mac&rsquo;s Keychain; removed when you delete
            them or remove the app&rsquo;s Keychain items.
          </li>
          <li>
            <Strong>Order, license, and activation records:</Strong> kept by
            Lemon Squeezy, and the order details shared with us kept by us,
            for as long as needed to support your license and as required for
            accounting and legal purposes.
          </li>
          <li>
            <Strong>Support correspondence:</Strong> kept for as long as needed
            to handle the request and keep a record of it.
          </li>
          <li>
            <Strong>Hosting logs</Strong> for the website, download, and update
            feed: kept by our hosting providers under their standard log
            retention.
          </li>
          <li>
            <Strong>App and website analytics and crash diagnostics:</Strong>{" "}
            retained by PostHog under our configured retention period, keyed
            to the analytics identifier described above.
          </li>
        </UL>
        <P>
          You can request deletion of the personal data we hold about you, such
          as order records or support correspondence, at any time by emailing{" "}
          <a
            href="mailto:support@getzerro.app"
            className="text-foreground underline underline-offset-4"
          >
            support@getzerro.app
          </a>
          .
        </P>
      </LegalSection>

      <LegalSection title="Security">
        <P>
          We use industry-standard safeguards: data is encrypted in transit
          (TLS), your API keys, trial state, license key, and activation
          credentials live in your macOS Keychain rather than on any server,
          and your recordings never pass through infrastructure we operate.
          The server-side data that can be tied to you is limited to the
          order and license records described above, hosting logs, support
          correspondence, and analytics keyed to the app&rsquo;s analytics
          identifier. No system is perfectly secure, but we design so that the
          most sensitive data (your screen and voice) is never held by us at
          all.
        </P>
      </LegalSection>

      <LegalSection title="International transfers">
        <P>
          We are based in the United States and our service providers process
          data primarily in the United States. If you use Zerro from outside
          the US, the limited data described above will be transferred to and
          processed in the US. Where required, we rely on appropriate
          safeguards such as standard contractual clauses offered by our
          providers.
        </P>
      </LegalSection>

      <LegalSection title="Your rights (EEA, UK, and similar jurisdictions)">
        <P>
          If you are in the European Economic Area, the United Kingdom, or a
          jurisdiction with similar laws, you have the right to access,
          correct, delete, or receive a copy of your personal data, to object
          to or restrict certain processing, and to withdraw consent where
          processing is based on consent. Our legal bases are performance of a
          contract (providing the official app and supporting your license),
          legitimate interests (security, abuse prevention, product
          improvement), and consent where required. You may also lodge a
          complaint with your local supervisory authority. To exercise any
          right, email{" "}
          <a
            href="mailto:support@getzerro.app"
            className="text-foreground underline underline-offset-4"
          >
            support@getzerro.app
          </a>
          .
        </P>
      </LegalSection>

      <LegalSection title="Your rights (California)">
        <P>
          If you are a California resident, you have the right to know what
          personal information we collect, to access and delete it, to correct
          inaccurate information, and to not be discriminated against for
          exercising these rights. We do not sell personal information or
          share it for cross-context behavioral advertising, so there is
          nothing to opt out of. To exercise these rights, email{" "}
          <a
            href="mailto:support@getzerro.app"
            className="text-foreground underline underline-offset-4"
          >
            support@getzerro.app
          </a>
          .
        </P>
      </LegalSection>

      <LegalSection title="Children">
        <P>
          Zerro is not directed to children under 13 (or the minimum age in
          your jurisdiction), and we do not knowingly collect personal
          information from them. If you believe a child has provided us
          personal information, contact us and we will delete it.
        </P>
      </LegalSection>

      <LegalSection title="Changes to this policy">
        <P>
          We may update this policy from time to time. We will post the
          updated version on this page and revise the &ldquo;Last
          updated&rdquo; date. For material changes, we will provide more
          prominent notice, such as a note in the app or on this site.
        </P>
      </LegalSection>

      <LegalSection title="Contact us">
        <P>
          SmartScale Solutions LLC ·{" "}
          <a
            href="mailto:support@getzerro.app"
            className="text-foreground underline underline-offset-4"
          >
            support@getzerro.app
          </a>
        </P>
      </LegalSection>
    </LegalShell>
  )
}
