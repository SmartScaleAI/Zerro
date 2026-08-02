// =============================================================================
// Resend integration for the trial verification email (Phase F).
// =============================================================================
// The code is delivered via Resend's transactional email API. The RESEND_API_KEY
// is a Supabase SECRET (read in index.ts, never logged); the from-address is a
// verified getzerro.app sender (TRIAL_EMAIL_FROM). The sender is behind an
// interface so the handler tests inject a stub and never send real mail.
//
// Failures are surfaced as `EmailSendError` so the handler can return a clean
// "couldn't send code, try again" to the app rather than a 500.
// =============================================================================

export class EmailSendError extends Error {
  readonly status: number | null;
  constructor(message: string, status: number | null = null) {
    super(message);
    this.name = "EmailSendError";
    this.status = status;
  }
}

export interface EmailSender {
  /** Send the 6-digit `code` to `to`. Throws EmailSendError on failure. */
  sendCode(to: string, code: string): Promise<void>;
}

const RESEND_ENDPOINT = "https://api.resend.com/emails";

/** Real Resend transport. */
export class ResendEmailSender implements EmailSender {
  constructor(
    private readonly apiKey: string,
    private readonly from: string,
  ) {}

  async sendCode(to: string, code: string): Promise<void> {
    // Short, plain, transactional. No links (a code-only email is harder to
    // weaponize for phishing and renders cleanly everywhere).
    const subject = "Your Zerro verification code";
    const text = `Your Zerro verification code is ${code}\n\n` +
      `Enter it in Zerro to start your trial. It expires in 10 minutes.\n\n` +
      `If you didn't request this, you can ignore this email.`;

    let res: Response;
    try {
      res = await fetch(RESEND_ENDPOINT, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ from: this.from, to, subject, text }),
      });
    } catch (e) {
      throw new EmailSendError(`resend_transport_error: ${String(e)}`);
    }

    if (!res.ok) {
      // Drain the body for the log line only — never echo it to the client.
      let detail = "";
      try {
        detail = (await res.text()).slice(0, 200);
      } catch { /* ignore */ }
      console.error(
        JSON.stringify({
          fn: "trial-start",
          op: "resend",
          status: res.status,
          detail,
        }),
      );
      throw new EmailSendError(`resend_${res.status}`, res.status);
    }
  }
}
