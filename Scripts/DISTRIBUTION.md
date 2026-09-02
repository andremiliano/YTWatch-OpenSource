# Distributing YTWatch via TestFlight

App Store is not possible (YouTube content policy). TestFlight internal testing
lets you share with up to 100 devices — no App Store review, just a link.

---

## One-time setup in App Store Connect

1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
2. **Apps → +** → New App
   - Platform: iOS
   - Name: YTWatch
   - Bundle ID: `com.andre.ytwatch.app` (must match Xcode)
   - SKU: `ytwatch` (anything unique)
3. Click **Create**

---

## Archive & upload from Xcode

1. In Xcode — select scheme **YTWatch**, destination **Any iOS Device (arm64)**
2. **Product → Archive** (takes ~2 min)
3. Organizer opens automatically → click **Distribute App**
4. Choose **TestFlight & App Store** → Next
5. Keep defaults → **Upload**
6. Wait ~5 min for Apple to process the build

---

## Create a TestFlight group & invite

1. In App Store Connect → your app → **TestFlight** tab
2. **Internal Testing → +** → create group (e.g. "Friends")
3. Add testers by Apple ID email
4. Select your uploaded build → enable it for the group
5. Testers get an email with a TestFlight install link

**That's it.** They install TestFlight from the App Store, tap the link, done.
No Mac needed on their end. App installs like any normal app.

---

## Updating the app

Just Archive + Upload again from Xcode. TestFlight shows the new build
automatically. Testers get a notification to update.

---

## Quick notes

- Internal TestFlight = no review, instant availability
- External TestFlight (public link) = requires Apple review (~1-2 days) — skip this
- Builds expire after 90 days — re-upload to extend
- Watch app is bundled inside the iPhone app — installs automatically on paired watch
