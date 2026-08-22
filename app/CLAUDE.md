# Cukur — Flutter App

Flutter client for the Cukur home-barber app. Package name `cukur`, org `com.cukur`. See the parent `../CLAUDE.md` for product context and the design source.

## Status

Freshly scaffolded via `flutter create` — still the default counter-app boilerplate in `lib/main.dart`. No dependencies beyond the Flutter SDK have been added yet (no `supabase_flutter`, no router, no state management package). Pick those deliberately when the first real feature lands rather than pre-installing them speculatively.

## Commands

```
flutter pub get
flutter run
flutter test
flutter analyze
```

## Design system — Modernist

Match the Claude Design canvas tokens (see parent `CLAUDE.md` for the project id), not generic Material defaults:

- Background `#f3f2f2`, text `#201e1d`, accent `#ec3013` (hover `#dd2b0f`, active `#ae1800`)
- Type: Archivo (weights 400/600/800), headings at 800, tight letter-spacing on large type
- Zero border-radius everywhere, heavy 2px borders instead of shadows/elevation for structure
- Full accent/neutral tonal ramps (100–900) are defined in the design system's `styles.css` — pull exact values from there via the `DesignSync` MCP tool rather than re-deriving them, and mirror them into a Flutter `ThemeData`/`ColorScheme` once theming starts.

## Structure

Organize by feature, not by layer, as the app grows (`lib/features/booking/`, `lib/features/onboarding/`, etc.) rather than dumping everything in flat `screens/`/`widgets/` folders. Two clear top-level areas will emerge: the customer-facing flow and the *penata* (barber) app — keep their screens and state separate since they're distinct experiences sharing only auth/design system.
