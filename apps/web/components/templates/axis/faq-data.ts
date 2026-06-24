import type { FaqEntry } from "@/components/structured-data";

// Single source of truth for the FAQ. Both the on-page FAQ section and the
// FAQPage JSON-LD read from this array, so the structured data can never drift
// from what's actually shown. Questions are phrased the way someone would ask
// them in a chat — that's what AI assistants match against.
export const faqEntries: FaqEntry[] = [
  {
    question: "What is Zerro?",
    answer:
      "Zerro is a native macOS menu-bar app that records a region of your screen and your voice, then returns exactly what you need — an agent prompt, a ready-to-send message, a code snippet, a written-up document, or simply a clear answer when you just want to understand something. Paste it into any AI tool, or send it to a person.",
  },
  {
    question: "What can Zerro create?",
    answer:
      "From a single recording, Zerro returns the artifact that fits what you asked for: an agent prompt to hand your AI coding agent, a ready-to-send message, an exact code or spreadsheet snippet, or a written-up document. It picks the right type from what you say, so you copy something that's ready to use — not raw transcribed text. And when you just want to understand something rather than produce an artifact, Zerro answers your question in plain language instead.",
  },
  {
    question: "Can Zerro just explain something or answer a question?",
    answer:
      "Yes. You don't have to be making an artifact. Point Zerro at a confusing screen, an error, a chart, or a contract clause, ask your question out loud, and it answers in plain language — no prompt, message, or document required. It's just as happy explaining what you're looking at as it is producing something to paste.",
  },
  {
    question: "Which AI tools does Zerro work with?",
    answer:
      "Any of them. Zerro puts ready-to-use text on your clipboard, so it works with ChatGPT, Claude, Gemini, Cursor, Perplexity, or any tool that takes text — and when the artifact is a message or document, it's just as ready to send to a person. It isn't tied to a single app.",
  },
  {
    question: "Do I need to be a developer to use Zerro?",
    answer:
      "No. If you can show your screen and say what you want, you can use Zerro. It's just as useful for drafting a message, grabbing a spreadsheet formula, or writing up notes as it is for coding. Plenty of people never touch a coding agent at all — they have Zerro turn a confusing screen into a plain-language document, draft a message, or pull out the exact snippet they need, no code involved.",
  },
  {
    question: "Is there a free trial?",
    answer:
      "Yes — everyone starts with 30 free credits. No credit card, no API key, and no time limit, so there's no clock to race. The free credits run on the Managed pipeline, so you get the zero-setup experience before deciding on a plan. Credits cover your usage; how many a single generation costs depends on the model you pick.",
  },
  {
    question: "How much does Zerro cost?",
    answer:
      "Everyone starts free with 30 credits. After that you have two paths. Managed, where Zerro handles the AI with no keys or setup, is $15/month — or $12/month billed yearly — and gives you 300 credits a month across 6 models (Claude, GPT & Gemini), with top-ups available anytime if you need more. Credits cover your usage, and the cost per generation varies by model — premium models like Claude Opus use more credits per generation than a fast model like Gemini Flash. Or BYOK, a one-time $69 purchase where you bring your own OpenAI, Gemini & Anthropic keys and pay once — no subscription. BYOK includes 1 year of updates, and your installed version keeps working after that.",
  },
  {
    question: "Do I need my own API keys?",
    answer:
      "Only if you want to. On the Managed plan, Zerro handles the AI for you — no keys, no setup. On the BYOK plan, you add your own OpenAI, Gemini & Anthropic keys, stored securely in the macOS Keychain, and pay once with no subscription.",
  },
  {
    question: "Is my data private?",
    answer:
      "Audio isolation, frame downsampling, and best-effort secret redaction always run on your Mac first, before anything leaves it. On the Managed and Trial plans, the prepped frames and your spoken narration are then sent to a third-party AI provider (OpenAI, Google, or Anthropic) to generate your result. On the BYOK plan they go straight to that provider on your own key, with no Zerro servers in between. Redaction is best-effort and never covers your spoken audio.",
  },
  {
    question: "Does Zerro need an account?",
    answer:
      "The BYOK plan requires no account and no subscription — you bring your own OpenAI, Gemini & Anthropic keys and pay once. The Managed plan is a subscription, so it involves an account and a monthly or yearly bill.",
  },
  {
    question: "How long can a recording be?",
    answer:
      "Each recording is capped at 3 minutes. The hard cap keeps every request fast, cheap, and predictable.",
  },
];
