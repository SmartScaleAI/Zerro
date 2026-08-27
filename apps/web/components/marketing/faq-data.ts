import type { FaqEntry } from "@/components/structured-data";
import { MODEL_VENDORS, SELECTABLE_MODEL_COUNT } from "@/lib/model-registry";
import {
  LICENSED_RELEASES,
  LICENSE_MAC_COUNT,
  LICENSE_PRICE,
  NEXT_MAJOR,
  SOURCE_LICENSE,
  TRIAL_DAYS,
} from "@/lib/product-facts";

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
    answer: `Yes. The first time an official build runs on a Mac it begins a ${TRIAL_DAYS}-day free trial, and reinstalling doesn't reset it. No card and no Zerro account are needed; you add your own OpenAI, Gemini, or Anthropic API key and use everything Zerro does, and your provider bills you for the usage as it always does.`,
  },
  {
    question: "How much does Zerro cost?",
    answer: `After the ${TRIAL_DAYS}-day free trial, a Zerro license is ${LICENSE_PRICE} one time. It activates on up to ${LICENSE_MAC_COUNT} Macs at once and includes every Zerro ${LICENSED_RELEASES} update; a future ${NEXT_MAJOR} major release may be sold separately. There is no subscription, no credit balance, and no Zerro account. You bring your own API keys and pay your AI provider directly for usage.`,
  },
  {
    question: "Do I need my own API keys?",
    answer: `Yes. Zerro is bring-your-own-key: add one, two, or all three OpenAI, Gemini, and Anthropic keys, stored securely in the macOS Keychain, and choose from ${SELECTABLE_MODEL_COUNT} models (${MODEL_VENDORS}). Local transcription needs no extra key; optional OpenAI transcription uses your OpenAI key.`,
  },
  {
    question: "Is Zerro open source?",
    answer: `Yes. Zerro is free software under ${SOURCE_LICENSE}, official builds included, so you can read it, change it, build it yourself, and redistribute it under that license, and a build you make yourself needs no Zerro license. The ${LICENSE_PRICE} pays for SmartScale's official signed and notarized distribution, its ${LICENSED_RELEASES} update service, and support; it doesn't buy or limit any GPL right. The Zerro name and logo are trademarks covered by a separate trademark policy.`,
  },
  {
    question: "Is my data private?",
    answer:
      "Processing starts on your Mac: the recording is prepared, your narration is transcribed, and best-effort secret redaction runs before anything leaves. Your Mac then sends the prepared screen frames and the transcript straight to the AI provider you chose (OpenAI, Google, or Anthropic) on your own key; your audio stays on your Mac with local transcription, or goes directly to OpenAI on your OpenAI key if you choose OpenAI transcription. Zerro has no server in that path and never receives your recordings, frames, audio, transcripts, prompts, or results. Redaction is best-effort and covers detected on-screen text, not what you say.",
  },
  {
    question: "Does Zerro need an account?",
    answer:
      "No. Zerro doesn't require a Zerro account. The trial, your API keys, your license key, and the local activation credentials are stored on your Mac. Lemon Squeezy processes the purchase and keeps the purchase, activation, and device records it needs to run your license.",
  },
  {
    question: "How long can a recording be?",
    answer:
      "Each recording is capped at 3 minutes. The hard cap keeps every request fast, cheap, and predictable.",
  },
];
