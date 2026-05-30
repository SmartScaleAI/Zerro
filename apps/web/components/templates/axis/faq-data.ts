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
      "No. If you can show your screen and say what you want, you can use Zerro. It's just as useful for getting help with a spreadsheet, explaining a problem to an AI assistant, or drafting something as it is for coding.",
  },
  {
    question: "How much does Zerro cost?",
    answer:
      "Zerro is a one-time purchase of $39 for the BYOK plan, which includes all features and future updates. A Managed plan at $12/month — where Zerro handles token usage and no API keys are required — is coming soon.",
  },
  {
    question: "Do I need my own API keys?",
    answer:
      "On the BYOK plan, yes — you add your own OpenAI and Gemini keys, stored securely in the macOS Keychain, and pay only for what you use. If you'd rather skip the setup, the upcoming Managed plan handles tokens for you with no keys required.",
  },
  {
    question: "Is my data private?",
    answer:
      "Yes. Audio isolation and frame downsampling run locally on your Mac before anything leaves it. On the BYOK plan, Zerro uses your own keys, so there are no Zerro servers handling your recordings.",
  },
  {
    question: "Does Zerro need an account?",
    answer:
      "No. The BYOK plan requires no account and no subscription. You bring your own API keys and pay once.",
  },
  {
    question: "How long can a recording be?",
    answer:
      "Each recording is capped at 3 minutes. The hard cap keeps every request fast, cheap, and predictable.",
  },
];
