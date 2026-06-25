import type { Metadata } from "next"
import {
  LegalShell,
  LegalSection,
  P,
  UL,
  Strong,
} from "@/components/legal/legal-shell"

export const metadata: Metadata = {
  title: "Privacy Policy",
  description:
    "How Zerro collects, uses, and protects your data — including what happens to your screen recordings and audio.",
  alternates: { canonical: "/privacy" },
}

const LAST_UPDATED = "June 15, 2026"

export default function PrivacyPage() {
  return (
    <LegalShell title="Privacy Policy" lastUpdated={LAST_UPDATED}>
      <LegalSection title="Who we are">
        <P>
          Zerro is operated by <Strong>SmartScale Solutions LLC</Strong>{" "}
          (&ldquo;SmartScale&rdquo;, &ldquo;we&rdquo;, &ldquo;us&rdquo;). Zerro
          is a macOS menu-bar app that lets you record a region of your screen,
          dictate what you want, and receive exactly what you need — an agent
          prompt, a message, a snippet, a document, or a clear answer to your
          question. This policy explains what data we collect through the
          Zerro app and the getzerro.app website, how we use it, and the
          choices you have. Questions? Email us at{" "}
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
            <Strong>We do not store your recordings.</Strong> Screen frames,
            audio, and transcripts are processed in memory to generate your
            prompt and are never written to our database. Our generation log
            has no content columns by design — it records only token counts,
            model, estimated cost, and success.
          </li>
          <li>
            <Strong>Processing starts on your Mac.</Strong> Your recording is
            prepared locally, and best-effort secret redaction runs on your Mac
            before anything is uploaded. Redaction covers detected on-screen
            text only — your spoken audio is uploaded as recorded.
          </li>
          <li>
            <Strong>On the BYOK plan, recordings never touch our servers.</Strong>{" "}
            Generations go directly from your Mac to your AI provider using
            your own API keys, which are stored in your macOS Keychain.
          </li>
          <li>
            <Strong>We do not sell your personal information</Strong> or share
            it for cross-context behavioral advertising.
          </li>
          <li>
            <Strong>Anonymous analytics are optional.</Strong> The app collects
            anonymous usage and crash diagnostics (metadata only — never your
            recordings, transcripts, or prompts) to improve reliability, and
            you can turn it off any time in Settings.
          </li>
        </UL>
      </LegalSection>

      <LegalSection title="Information we collect">
        <P>
          <Strong>Account information.</Strong> When you create an account we
          collect your email address. If you sign in with Apple or Google, we
          receive the email address (and, for Google, basic profile
          information) those providers share with us. Authentication is
          handled by Supabase.
        </P>
        <P>
          <Strong>Billing information.</Strong> Payments are processed by Lemon
          Squeezy, our merchant of record. We never see or store your full
          card number. We receive and store your subscription status, plan,
          and billing events needed to operate your account.
        </P>
        <P>
          <Strong>Recordings (Managed and Trial plans).</Strong> When you start
          a recording, the app captures the screen region you select and your
          voice. Your Mac first prepares the recording locally and masks
          detected secrets before upload. This masking is best-effort: it scans
          on-screen text for common structured secrets (such as API keys and
          tokens), so it can miss things, and it does not apply to your spoken
          audio — your narration is uploaded and transcribed as recorded. The
          frames and audio are then sent to our generation service, where the
          audio is transcribed and the content is sent to the third-party AI
          model you selected (OpenAI, Google, or Anthropic) to produce your
          prompt.
          This data is processed transiently: frames, audio, transcripts, and
          prompts are not stored in our database. The generated output is held
          in a short-lived cache for up to 15 minutes solely so that a dropped
          connection can be retried without charging you twice, then becomes
          unreadable and is purged.
        </P>
        {/* DRAFT — placeholder language pending attorney review */}
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
          <Strong>Recordings (BYOK plan).</Strong> If you bring your own API
          keys, generations are sent directly from your Mac to the relevant
          provider (OpenAI, Google, or Anthropic). Your recordings and keys
          never pass through our servers; keys are stored locally in your
          macOS Keychain.
        </P>
        <P>
          <Strong>Usage data.</Strong> We record per-generation metadata —
          token counts, estimated cost, model, provider, and success — to
          operate credits and billing. We also process IP addresses and
          session identifiers for rate limiting and abuse prevention.
        </P>
        <P>
          <Strong>Trial verification.</Strong> Starting a free trial requires
          verifying your email with a one-time code sent via Resend. We store
          only a hashed version of the code, never the raw code. To prevent
          trial abuse, we also collect a one-way hash of a hardware identifier
          to limit free trials to one per device. The underlying identifier
          never leaves your Mac — only the hash is sent — and it is used solely
          for fraud prevention, never for tracking or advertising.
        </P>
        <P>
          <Strong>App analytics and crash reports.</Strong> The Zerro desktop
          app uses PostHog to collect anonymous product-usage events (such as
          completing onboarding, starting a recording, or copying a result) and
          diagnostic crash and error reports. These contain only metadata —
          event names, timings, app version, model identifiers, and error types
          — and never your recordings, transcripts, generated prompts, file
          paths, or API keys. This data is associated with an anonymous device
          identifier, not your name or email. You can turn it off at any time in
          the app under Settings &rarr; &ldquo;Send Anonymous Usage Data &amp;
          Crash Reports.&rdquo;
        </P>
        <P>
          <Strong>Website analytics.</Strong> The getzerro.app website uses
          PostHog to collect anonymous product-usage metadata — page views,
          referrer and campaign source, device and browser type, and
          interaction events such as clicking a download button or expanding an
          FAQ — along with aggregated heatmaps of where visitors click and
          scroll. This is metadata only and is not tied to your name or email.
          We do not record your browsing session, and the site is cookieless:
          PostHog sets no cross-site tracking cookies and keeps no identifier
          between visits.
        </P>
      </LegalSection>

      <LegalSection title="How we use your information">
        <UL>
          <li>To provide the service: generating prompts from your recordings, managing your account, credits, and subscription.</li>
          <li>To process payments and prevent fraud and abuse, including rate limiting and trial-abuse prevention.</li>
          <li>To communicate with you about your account, such as trial verification codes and support responses.</li>
          <li>To understand aggregate usage of our website and improve the product.</li>
          <li>To diagnose crashes and errors and improve the app&rsquo;s reliability.</li>
          <li>To comply with legal obligations.</li>
        </UL>
        <P>
          We do not use your recordings, transcripts, or generated prompts to
          train AI models.
        </P>
      </LegalSection>

      <LegalSection title="Service providers">
        <P>
          We share data with a small set of providers, each only to the extent
          needed to run Zerro: <Strong>Supabase</Strong> (authentication,
          database, and generation service), <Strong>OpenAI</Strong>,{" "}
          <Strong>Google</Strong>, and <Strong>Anthropic</Strong> (AI model
          processing of recordings on Managed/Trial plans, and audio
          transcription via OpenAI Whisper), <Strong>Lemon Squeezy</Strong>{" "}
          (payments, as merchant of record), <Strong>Resend</Strong>{" "}
          (transactional email), <Strong>PostHog</Strong> (anonymous app and
          website analytics and crash reporting), and <Strong>Vercel</Strong>{" "}
          (website hosting). AI providers process your content under their API
          terms; we use API offerings under which inputs are not used to train
          their models. We do not sell your personal information to anyone.
        </P>
      </LegalSection>

      <LegalSection title="Data retention">
        <UL>
          <li>
            <Strong>Screen frames, audio, transcripts, prompts:</Strong> not
            stored; processed in memory during generation only.
          </li>
          <li>
            <Strong>Generated output:</Strong> cached up to 15 minutes for
            retry safety, then purged.
          </li>
          <li>
            <Strong>Account, subscription, and generation metadata:</Strong>{" "}
            kept while your account is active and as required for accounting
            and legal purposes.
          </li>
          <li>
            <Strong>Trial verification codes:</Strong> stored hashed and
            expire within minutes.
          </li>
          <li>
            <Strong>Anonymous app analytics and crash diagnostics:</Strong>{" "}
            retained by PostHog under our configured retention period and tied
            only to an anonymous device identifier.
          </li>
        </UL>
        <P>
          You can request deletion of your account and associated data at any
          time by emailing{" "}
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
          (TLS), API keys on the BYOK plan live in your macOS Keychain rather
          than on our servers, verification codes are stored only as hashes,
          and our backend enforces authentication, rate limits, and
          least-privilege access. No system is perfectly secure, but we design
          so that the most sensitive data — your screen and voice — is held by
          us for the shortest possible time, or not at all.
        </P>
      </LegalSection>

      <LegalSection title="International transfers">
        <P>
          We are based in the United States and our service providers process
          data primarily in the United States. If you use Zerro from outside
          the US, your data will be transferred to and processed in the US.
          Where required, we rely on appropriate safeguards such as standard
          contractual clauses offered by our providers.
        </P>
      </LegalSection>

      <LegalSection title="Your rights (EEA, UK, and similar jurisdictions)">
        <P>
          If you are in the European Economic Area, the United Kingdom, or a
          jurisdiction with similar laws, you have the right to access,
          correct, delete, or receive a copy of your personal data, to object
          to or restrict certain processing, and to withdraw consent where
          processing is based on consent. Our legal bases are performance of a
          contract (providing the service), legitimate interests (security,
          abuse prevention, product improvement), and consent where required.
          You may also lodge a complaint with your local supervisory
          authority. To exercise any right, email{" "}
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
          prominent notice, such as email.
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
