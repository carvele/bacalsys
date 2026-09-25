/**
 * BaCalSys design tokens — dark-mode first.
 * Semantic names (surface, ink, brand, …) are what components use; raw hex values
 * live only here so the palette can be re-tuned without touching screens.
 * @type {import('tailwindcss').Config}
 */
module.exports = {
  content: ['./src/**/*.{js,jsx,ts,tsx}'],
  presets: [require('nativewind/preset')],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        surface: {
          DEFAULT: '#0B0F14', // app background
          raised: '#131A22', // cards, sheets
          sunken: '#070A0E', // inputs
          border: '#233040',
        },
        ink: {
          DEFAULT: '#E8EDF2', // primary text
          muted: '#9AA8B6', // secondary text
          faint: '#5E6C7A', // placeholders, disabled
        },
        brand: {
          DEFAULT: '#F97316', // Bataan ember orange — primary actions
          pressed: '#EA580C',
          soft: '#3A1E0B', // tinted backgrounds
        },
        success: { DEFAULT: '#22C55E', soft: '#0F2A1A' },
        warning: { DEFAULT: '#EAB308', soft: '#2A230A' },
        danger: { DEFAULT: '#EF4444', soft: '#2E1111' },
      },
      borderRadius: {
        card: '14px',
        control: '10px',
      },
      fontSize: {
        display: ['30px', { lineHeight: '36px', fontWeight: '700' }],
        title: ['20px', { lineHeight: '26px', fontWeight: '600' }],
      },
    },
  },
  plugins: [],
};
