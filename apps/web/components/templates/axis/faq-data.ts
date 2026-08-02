import type { FaqEntry } from "@/components/structured-data";
import { MODEL_VENDORS, SELECTABLE_MODEL_COUNT } from "@/lib/model-registry";

// Single source of truth for the FAQ. Both the on-page FAQ section and the
// FAQPage JSON-LD read from this array, so the structured data can never drift
// from what's actually shown. Questions are phrased the way someone would ask
// them in a chat — that's what AI assistants match against.
export const faqEntries: FaqEntry[] = [
  {
    question: "What is Zerro?",
    answer:
      "Zerro is a native macOS menu-bar app that records a region of your screen and your voice, then returns exactly what you need: an agent prompt, a ready-to-send message, a code snippet, a written-up document, or simply a clear answer when you just want to understand something. Paste it into any AI tool, or send it to a person.",
  },
  {
    question: "What can Zerro create?",
    answer:
      "From a single recording, Zerro returns the artifact that fits what you asked for: an agent prompt to hand your AI coding agent, a ready-to-send message, an exact code or spreadsheet snippet, or a written-up document. It picks the right type from what you say, so you copy something that's ready to use, not raw transcribed text. And when you just want to understand something rather than produce an artifact, Zerro answers your question in plain language instead.",
  },
  {
    question: "Can Zerro just explain something or answer a question?",
    answer:
      "Yes. You don't have to be making an artifact. Point Zerro at a confusing screen, an error, a chart, or a contract clause, ask your question out loud, and it answers in plain language: no prompt, message, or document required. It's just as happy explaining what you're looking at as it is producing something to paste.",
  },
  {
    question: "Which AI tools does Zerro work with?",
    answer:
      "Any of them. Zerro puts ready-to-use text on your clipboard, so it works with ChatGPT, Claude, Gemini, Cursor, Perplexity, or any tool that takes text. And when the artifact is a message or document, it's just as ready to send to a person. It isn't tied to a single app.",
  },
  {
    question: "Do I need to be a developer to use Zerro?",
    answer:
      "No. If you can show your screen and say what you want, you can use Zerro. It's just as useful for drafting a message, grabbing a spreadsheet formula, or writing up notes as it is for coding. Plenty of people never touch a coding agent at all. They have Zerro turn a confusing screen into a plain-language document, draft a message, or pull out the exact snippet they need, no code involved.",
  },
  {
    question: "Is there a free trial?",
    answer:
      "Yes. Choose 30 Zerro Cloud Trial credits with email verification and no API key, or try 10 successful BYOK generations with your own OpenAI, Gemini, or Anthropic keys and no email. Neither option needs a credit card or has a time limit, and failed BYOK generations don't count.",
  },
  {
    question: "How much does Zerro cost?",
    answer: `Start free with either 30 Zerro Cloud Trial credits or 10 successful BYOK generations. After that you have two paths. Zerro Cloud, where Zerro handles model access with no keys or setup, is $15/month ($12/month billed yearly) and gives you 300 credits a month across ${SELECTABLE_MODEL_COUNT} models (${MODEL_VENDORS}), with top-ups available anytime if you need more. Credits cover your usage, and the cost per generation varies by model. Or BYOK, a one-time $69 purchase where you bring any combination of OpenAI, Gemini, and Anthropic keys and pay once, with no subscription. BYOK includes 1 year of updates, and your installed version keeps working after that.`,
  },
  {
    question: "Do I need my own API keys?",
    answer:
      "Only if you choose the BYOK trial or plan. You can add one, two, or all three OpenAI, Gemini, and Anthropic keys, stored securely in the macOS Keychain. Zerro Cloud needs no keys or setup. On BYOK, local transcription needs no extra key; optional cloud transcription requires an OpenAI key.",
  },
  {
    question: "Is my data private?",
    answer:
      "Processing, including best-effort secret redaction, always runs on your Mac first, before anything leaves it. On Zerro Cloud and the Zerro Cloud Trial, the prepped recording and your spoken narration are then sent to a third-party AI provider (OpenAI, Google, or Anthropic) to generate your result. On the BYOK plan they go straight to that provider on your own key, with no Zerro servers in between. Redaction is best-effort and never covers your spoken audio.",
  },
  {
    question: "Does Zerro need an account?",
    answer:
      "The BYOK trial and paid BYOK plan require no account or email. You bring any combination of OpenAI, Gemini, and Anthropic keys. The Zerro Cloud Trial uses email verification, and Zerro Cloud is a monthly or yearly subscription.",
  },
  {
    question: "How long can a recording be?",
    answer:
      "Each recording is capped at 3 minutes. The hard cap keeps every request fast, cheap, and predictable.",
  },
];
