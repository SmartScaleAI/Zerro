import type { FaqEntry } from "@/components/structured-data";

// Single source of truth for the FAQ. Both the on-page FAQ section and the
// FAQPage JSON-LD read from this array, so the structured data can never drift
// from what's actually shown. Questions are phrased the way someone would ask
// them in a chat — that's what AI assistants match against.
export const faqEntries: FaqEntry[] = [
  {
    question: "What is Zerro?",
    answer:
      "Zerro is a native macOS menu-bar app that records a region of your screen and your voice, then returns a clear, structured prompt you can paste into any AI tool — ChatGPT, Claude, a coding agent, or anything else that takes text.",
  },
  {
    question: "Which AI tools does Zerro work with?",
    answer:
      "Any of them. Zerro puts a structured prompt on your clipboard, so it works with ChatGPT, Claude, Gemini, Cursor, Perplexity, or any tool that takes a text prompt. It isn't tied to a single app.",
  },
  {
    question: "Do I need to be a developer to use Zerro?",
    answer:
      "No. If you can show your screen and say what you want, you can use Zerro. It's just as useful for getting help with a spreadsheet, explaining a problem to an AI assistant, or drafting something as it is for coding. Plenty of people never touch a coding agent at all — they use Explain mode to make sense of a confusing error, spreadsheet, or design in plain language, no code involved.",
  },
  {
    question: "Is there a free trial?",
    answer:
      "Yes — everyone starts with 40 free credits. No credit card, no API key, and no time limit, so there's no clock to race. The free credits run on the Managed pipeline, so you get the zero-setup experience before deciding on a plan. Credits cover your usage; how many a single generation costs depends on the model you pick.",
  },
  {
    question: "How much does Zerro cost?",
    answer:
      "Everyone starts free with 40 credits. After that you have two paths. Managed, where Zerro handles the AI with no keys or setup, is $15/month — or $12/month billed yearly — and gives you 300 credits a month across 6 models (Claude, GPT & Gemini), with top-ups available anytime if you need more. Credits cover your usage, and the cost per generation varies by model — premium models like Claude Opus use more credits per generation than a fast model like Gemini Flash. Or BYOK, a one-time $69 purchase where you bring your own OpenAI, Gemini & Anthropic keys and pay once — no subscription. BYOK includes 1 year of updates, and your installed version keeps working after that.",
  },
  {
    question: "Do I need my own API keys?",
    answer:
      "Only if you want to. On the Managed plan, Zerro handles the AI for you — no keys, no setup. On the BYOK plan, you add your own OpenAI, Gemini & Anthropic keys, stored securely in the macOS Keychain, and pay once with no subscription.",
  },
  {
    question: "Is my data private?",
    answer:
      "Audio isolation and frame downsampling always run locally on your Mac before anything leaves it. On the Managed plan, your recording is sent to Zerro's server to generate the prompt. On the BYOK plan, Zerro uses your own keys and your recordings never leave your Mac — there are no Zerro servers handling them.",
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
