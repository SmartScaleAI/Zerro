import type { Metadata } from "next";
import { ThemeProvider } from "@/components/theme-provider";
import { Inter } from "next/font/google";
import { Analytics } from "@vercel/analytics/next";
import {
  OrganizationJsonLd,
  WebSiteJsonLd,
} from "@/components/structured-data";
import "./globals.css";

const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
  weight: ["300", "400", "500", "600", "700"],
});

const sansFont = "var(--font-inter), ui-sans-serif, system-ui, sans-serif";

export const metadata: Metadata = {
  title: {
    default: "Zerro — Give your agent eyes and ears",
    template: "%s — Zerro",
  },
  description:
    "Record your screen, dictate what you want, and Zerro hands you a structured prompt — ready to paste into your AI agent. Like voice dictation for your codebase. Record it. Paste it. Zerro in between.",
  applicationName: "Zerro",
  metadataBase: new URL("https://getzerro.app"),
  alternates: {
    canonical: "/",
  },
  keywords: [
    "voice dictation for coding",
    "AI prompt generator",
    "macOS menu bar app",
    "Cursor prompt",
    "Windsurf prompt",
    "screen recording to prompt",
    "AI coding agent",
  ],
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-image-preview": "large",
      "max-snippet": -1,
      "max-video-preview": -1,
    },
  },
  // Paste the Google Search Console verification token here once available:
  // verification: { google: "your-token" },
  icons: {
    icon: [
      { url: "/favicon.ico", sizes: "any" },
      { url: "/favicon-16x16.png", type: "image/png", sizes: "16x16" },
      { url: "/favicon-32x32.png", type: "image/png", sizes: "32x32" },
    ],
    apple: [{ url: "/apple-touch-icon.png", sizes: "180x180" }],
  },
  openGraph: {
    title: "Zerro — Give your agent eyes and ears",
    description:
      "Record your screen, dictate what you want, and Zerro hands you a structured prompt — like voice dictation for your codebase. Record it. Paste it. Zerro in between.",
    url: "https://getzerro.app",
    siteName: "Zerro",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Zerro — Give your agent eyes and ears",
    description:
      "Record your screen, dictate what you want, and get a structured prompt for your AI agent — voice dictation built for coding.",
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className={`${inter.variable} bg-background font-light w-full text-foreground antialiased`}
        style={{ fontFamily: sansFont }}
      >
        <OrganizationJsonLd />
        <WebSiteJsonLd />
        <div
          className={`${inter.variable} min-h-screen w-full bg-background font-light text-foreground`}
          style={{ fontFamily: sansFont }}
        >
          <ThemeProvider
            attribute="class"
            defaultTheme="dark"
            enableSystem
            disableTransitionOnChange
          >
            {children}
          </ThemeProvider>
        </div>
        <Analytics />
      </body>
    </html>
  );
}
