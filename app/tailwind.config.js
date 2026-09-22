/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        ink: {
          950: "#070809",
          900: "#0c0e11",
          800: "#13161b",
          700: "#1b1f26",
          600: "#262b34",
          500: "#3a414d",
          400: "#5a6270",
          300: "#8a93a3",
          200: "#c0c6d1",
          100: "#e7eaef",
        },
        flame: {
          500: "#ff5b3c",
          400: "#ff8364",
          600: "#e0431e",
        },
      },
      fontFamily: {
        sans: ["Inter", "ui-sans-serif", "system-ui", "sans-serif"],
        mono: ["JetBrains Mono", "ui-monospace", "monospace"],
      },
      boxShadow: {
        glow: "0 0 0 1px rgba(255,91,60,0.4), 0 8px 24px -8px rgba(255,91,60,0.45)",
      },
    },
  },
  plugins: [],
};
