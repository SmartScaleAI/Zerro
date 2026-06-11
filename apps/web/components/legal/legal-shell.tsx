import Link from "next/link"
import Image from "next/image"
import Footer from "@/components/templates/axis/footer"

/**
 * Shared shell for legal pages (/privacy, /terms). Server component — no
 * motion, no client JS. A slim header (wordmark + back link) replaces the
 * marketing navbar, followed by a readable prose column and the site footer.
 */
export function LegalShell({
  title,
  lastUpdated,
  children,
}: {
  title: string
  lastUpdated: string
  children: React.ReactNode
}) {
  return (
    <div className="relative flex min-h-screen flex-col">
      <header className="mx-auto w-full max-w-3xl px-6 pt-8">
        <Link href="/" className="inline-flex items-center">
          <Image
            src="/logo/zerro-mark.svg"
            alt="Zerro"
            width={36}
            height={36}
            className="-ml-1 h-9 w-9 text-foreground dark:invert"
          />
          <span className="text-xl font-medium tracking-tight text-foreground">
            Zerro
          </span>
        </Link>
      </header>

      <main className="mx-auto w-full max-w-3xl flex-1 px-6 pt-14 pb-24">
        <h1 className="text-3xl font-medium tracking-tight text-foreground sm:text-4xl">
          {title}
        </h1>
        <p className="mt-3 text-sm text-muted-foreground">
          Last updated: {lastUpdated}
        </p>
        <div className="mt-10 flex flex-col gap-10">{children}</div>
      </main>

      <div className="pb-12">
        <Footer />
      </div>
    </div>
  )
}

export function LegalSection({
  title,
  children,
}: {
  title: string
  children: React.ReactNode
}) {
  return (
    <section className="flex flex-col gap-4">
      <h2 className="text-xl font-medium tracking-tight text-foreground">
        {title}
      </h2>
      {children}
    </section>
  )
}

export function P({ children }: { children: React.ReactNode }) {
  return (
    <p className="text-[15px] leading-relaxed text-muted-foreground">
      {children}
    </p>
  )
}

export function UL({ children }: { children: React.ReactNode }) {
  return (
    <ul className="flex list-disc flex-col gap-2 pl-5 text-[15px] leading-relaxed text-muted-foreground marker:text-muted-foreground/50">
      {children}
    </ul>
  )
}

export function Strong({ children }: { children: React.ReactNode }) {
  return <span className="font-medium text-foreground">{children}</span>
}
