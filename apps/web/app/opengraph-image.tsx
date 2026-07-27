import { ImageResponse } from "next/og";

// Static social share card, 1200×630. Rendered once at build via ImageResponse.
// Uses the default sans font (no font fetch) to keep the route lightweight.
export const alt = "Zerro: Talk to your screen. Zerro does the work.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function OpengraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          backgroundColor: "#0a0a0a",
          padding: "80px",
          fontFamily: "sans-serif",
        }}
      >
        {/* Wordmark: the Zerro mark + name */}
        <div style={{ display: "flex", alignItems: "center", gap: "20px" }}>
          <svg
            width="72"
            height="72"
            viewBox="0 0 512 512"
            xmlns="http://www.w3.org/2000/svg"
          >
            <g fill="#fafafa">
              <path d="M150 362 V180 Q150 150 180 150 H288 Q300 150 300 162 V208 H208 V362 Z" />
              <path
                d="M150 362 V180 Q150 150 180 150 H288 Q300 150 300 162 V208 H208 V362 Z"
                transform="rotate(180 256 256)"
              />
            </g>
          </svg>
          <span
            style={{ color: "#fafafa", fontSize: 48, fontWeight: 600, letterSpacing: "-0.02em" }}
          >
            Zerro
          </span>
        </div>

        {/* Tagline */}
        <div style={{ display: "flex", flexDirection: "column", gap: "24px" }}>
          {/* Category eyebrow pill, mirroring the hero. Scaled up for the
              1200×630 card. Text is written pre-uppercased and the blur is
              dropped to a flat fill, since Satori supports neither
              text-transform nor backdrop-filter. alignSelf keeps the pill
              hugging its content instead of stretching the column. */}
          <div
            style={{
              display: "flex",
              alignSelf: "flex-start",
              alignItems: "center",
              gap: "14px",
              border: "1px solid rgba(255,255,255,0.14)",
              borderRadius: "999px",
              backgroundColor: "rgba(255,255,255,0.035)",
              padding: "9px 26px 9px 10px",
            }}
          >
            <div
              style={{
                display: "flex",
                borderRadius: "999px",
                backgroundColor: "rgba(255,255,255,0.1)",
                padding: "5px 14px",
                fontSize: 19,
                fontWeight: 700,
                letterSpacing: "0.06em",
                color: "#fafafa",
              }}
            >
              MAC APP
            </div>
            <div style={{ display: "flex", fontSize: 23, color: "#cfcfd6" }}>
              Lightweight, lives in your menu bar
            </div>
          </div>
          <div
            style={{
              display: "flex",
              flexDirection: "column",
              color: "#fafafa",
              fontSize: 84,
              fontWeight: 600,
              lineHeight: 1.05,
              letterSpacing: "-0.03em",
            }}
          >
            <span>Talk to your screen.</span>
            <span>Zerro does the work.</span>
          </div>
          <div style={{ color: "#a1a1a1", fontSize: 32, fontWeight: 400 }}>
            Record your screen, explain what you want, and get it done faster.
          </div>
        </div>
      </div>
    ),
    { ...size },
  );
}
