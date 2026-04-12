# Memorable Website Spec

Single-page marketing + legal site for the Memorable iOS app.
Built with Next.js, hosted on Vercel.

## Important Notes

- The app icon is at `Memorable/Assets.xcassets/AppIcon.appiconset/icon_1024.png`. Copy it into the Next.js public folder.
- Use the exact hex colors from this spec. Do not approximate or substitute similar colors.

## Purpose

This page serves three roles:
1. **Marketing URL** for the App Store listing
2. **Privacy Policy** (anchor: `#privacy`) for App Store Connect
3. **Support contact** (anchor: `#support`) for App Store Connect

## Design System: Celestial Theme

All colors match the iOS app exactly.

### Colors
| Token | Hex | Usage |
|---|---|---|
| background | `#070f17` | Page background |
| surface | `#0e1520` | Card/section backgrounds |
| surfaceContainer | `#111a24` | Elevated cards |
| surfaceContainerHigh | `#16202b` | Input fields, chips |
| primary | `#6fb1ff` | Links, CTA buttons, highlights |
| primaryDim | `#43a1ff` | Secondary links |
| primaryContainer | `#4ca4ff` | Button fills |
| onPrimaryContainer | `#002443` | Button text |
| onSurface | `#eaf1fd` | Primary text |
| onSurfaceVariant | `#a4acb7` | Secondary text |
| outline | `#6e7680` | Borders, dividers |
| outlineVariant | `#414952` | Subtle borders |
| amber | `#FFB74D` | Accent highlights, badges |
| emerald | `#34D399` | Success indicators |
| error | `#ff716c` | Error states |

### Typography
- Font: system sans-serif stack (`-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif`)
- Headings: semibold, rounded feel (use `font-variation-settings` or weight 600)
- Body: regular weight, `#eaf1fd` color
- Secondary text: `#a4acb7`

### Effects
- Glass panels: `backdrop-filter: blur(20px)` with `rgba(17, 26, 36, 0.6)` background
- Cards: `border: 1px solid rgba(65, 73, 82, 0.3)` (outlineVariant at 30%)
- Rounded corners: 16px for cards, 12px for smaller elements
- No harsh shadows. Use subtle border glow: `box-shadow: 0 0 40px rgba(111, 177, 255, 0.05)`

## Page Structure

All sections are on a single scrollable page. Smooth scroll between anchor links.

### Section 1: Hero

- App icon (use the 1024px icon, displayed at ~120px with rounded corners)
- App name: "Memorable" (large, semibold)
- Tagline: "Every memory, one search away."
- Subtitle: "On-device AI photo search for iOS. Describe what you remember. Find the exact photo."
- App Store download badge (use Apple's official badge asset, link to the App Store listing)
- Background: subtle radial gradient from `#0e1520` center to `#070f17` edges

### Section 2: Features

Four feature cards in a 2x2 grid (stacks to single column on mobile).

| Icon | Title | Description |
|---|---|---|
| Magnifying glass with sparkle | Natural Language Search | Type what you remember. "Birthday cake with candles", "sunset at the beach", "my dog playing". |
| Lock shield | 100% Private | All AI processing happens on your device. No cloud. No accounts. No tracking. Your photos never leave your phone. |
| Brain/chip | On-Device AI | Powered by MobileCLIP, a state-of-the-art vision model that understands both images and text. |
| Clock/calendar | Smart Filters | Search by time ("last summer"), location ("photos in Berlin"), or combine them ("lunch in Paris last week"). |

Cards use the glass panel effect with surfaceContainer background.

### Section 3: Screenshots

- Horizontal scroll on mobile, grid on desktop
- Space for 4-6 iPhone screenshots
- Use placeholder containers with `surfaceContainerHigh` background and "Screenshot" label until real screenshots are added
- Each screenshot in a phone frame mockup (optional, can be plain images with rounded corners)

### Section 4: How It Works

Three steps, horizontal on desktop, vertical on mobile.

1. **Index** - Memorable scans your photo library once to build a search index. Takes a few minutes.
2. **Search** - Type what you are looking for in natural language. The AI matches your words to your photos.
3. **Find** - Results ranked by relevance. Filter by photos, videos, or screenshots. Sort by relevance or date.

### Section 5: Privacy Policy (id="privacy")

Full privacy policy text. Keep the heading as "Privacy Policy" so it reads as a standalone section when linked directly.

```
Privacy Policy

Last updated: [current date]

Memorable ("the app") is developed by Proferent.

Data Collection
Memorable does not collect, transmit, or store any personal data on external servers. All processing happens entirely on your device.

Photo Library Access
The app accesses your photo library solely to build a local search index. Photos are processed on-device using machine learning models. No photos, thumbnails, or metadata are uploaded anywhere.

Location Data
The app uses Apple's geocoding services to resolve GPS coordinates into place names (city, state, country) for location-based search. These requests go through Apple's servers as part of standard iOS APIs. No location data is sent to Proferent or any third party.

Analytics and Tracking
The app contains no analytics SDKs, no crash reporting services, no advertising frameworks, and no tracking of any kind. NSPrivacyTracking is set to false.

In-App Purchases
The app offers a one-time in-app purchase processed entirely through Apple's App Store. Proferent does not have access to your payment information.

Data Storage
All data (search index, embeddings, preferences) is stored locally on your device in the app's sandboxed container. Deleting the app removes all data.

Children's Privacy
The app does not knowingly collect information from children under 13.

Changes to This Policy
Updates will be posted on this page with a revised date.

Contact
For questions about this policy, contact: [your email]
```

### Section 6: Support (id="support")

- Heading: "Support"
- Text: "Need help? Have feedback?"
- Email: mailto link to support email
- Optional: link to GitHub Issues if the repo is public
- AI disclaimer: "Memorable's search uses on-device AI and can make mistakes."

### Section 7: Footer

- "Built by Proferent"
- Links: Privacy Policy (#privacy) | Support (#support)
- Copyright: current year

## Responsive Behavior

- **Desktop** (>768px): max-width 1100px centered, 2-column feature grid, horizontal screenshots
- **Mobile** (<768px): single column, full-width cards, horizontal scroll for screenshots
- Navigation: fixed/sticky minimal top bar with "Memorable" text logo + anchor links (Features, Privacy, Support)

## Meta Tags

```html
<title>Memorable - AI Photo Search for iOS</title>
<meta name="description" content="Search your photos by describing what you remember. On-device AI, 100% private. No cloud, no tracking.">
<meta property="og:title" content="Memorable - Every memory, one search away">
<meta property="og:description" content="On-device AI photo search for iOS. Describe what you remember, find the exact photo.">
<meta property="og:image" content="/og-image.png">
<meta name="theme-color" content="#070f17">
```

## Assets Needed

1. `icon_1024.png` - app icon (already exists at `Memorable/Assets.xcassets/AppIcon.appiconset/icon_1024.png`)
2. App Store badge - download from Apple's official marketing resources
3. Screenshots - 4-6 iPhone screenshots of the app (search results, detail view, filters, onboarding)
4. `og-image.png` - 1200x630 Open Graph image for social sharing (app icon + tagline on dark background)

## URLs for App Store Connect

After deploying to Vercel:
- **Marketing URL**: `https://your-domain.vercel.app`
- **Privacy Policy URL**: `https://your-domain.vercel.app#privacy`
- **Support URL**: `https://your-domain.vercel.app#support`
