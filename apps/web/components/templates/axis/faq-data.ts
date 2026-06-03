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
      "Yes — everyone starts with 15 free generations. No credit card, no API key, and no time limit, so there's no clock to race. The free generations run on the Managed pipeline, so you get the zero-setup experience before deciding on a plan.",
  },
  {
    question: "How much does Zerro cost?",
    answer:
      "Everyone starts free with 15 generations. After that you have two paths. Managed, where Zerro handles the AI with no keys or setup, comes in two tiers: Starter at $12/month (or $120/year) for about 100 recordings a month, and Pro at $29/month (or $290/year) for about 300 recordings a month. Or BYOK, a one-time $39 purchase where you bring your own OpenAI key and pay once — no subscription.",
  },
  {
    question: "Do I need my own API keys?",
    answer:
      "Only if you want to. On the Managed plans (Starter and Pro), Zerro handles the AI for you — no keys, no setup. On the BYOK plan, you add your own OpenAI key, stored securely in the macOS Keychain, and pay once with no subscription.",
  },
  {
    question: "Is my data private?",
    answer:
      "Audio isolation and frame downsampling always run locally on your Mac before anything leaves it. On the Managed plans (Starter and Pro), your recording is sent to Zerro's server to generate the prompt. On the BYOK plan, Zerro uses your own key and your recordings never leave your Mac — there are no Zerro servers handling them.",
  },
  {
    question: "Does Zerro need an account?",
    answer:
      "The BYOK plan requires no account and no subscription — you bring your own OpenAI key and pay once. The Managed plans (Starter and Pro) are subscriptions, so they involve an account and a monthly or yearly bill.",
  },
  {
    question: "How long can a recording be?",
    answer:
      "Each recording is capped at 3 minutes. The hard cap keeps every request fast, cheap, and predictable.",
  },
];
