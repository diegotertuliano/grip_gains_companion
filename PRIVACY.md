# Privacy Policy

**Grip Gains Unofficial Companion**

Last updated: September 2026

## Data Collection

This app does not collect, store, or share any personal data.

Training history is stored on your device. If you enable iCloud sync, history is also stored in your iCloud account. The embedded Grip Gains website connects to Grip Gains and is subject to its own privacy practices.

## Bluetooth

This app uses Bluetooth to communicate with supported force measurement devices. Force readings are processed locally and may be recorded in your training history.

## Frez Dyno

If you choose Frez Dyno support, your personal Frez access key is stored in iOS Keychain on this device. The app sends that key and the connected Dyno's serial number directly to `api.frez.app` over HTTPS to retrieve calibration each time you connect. Calibration requests do not include force samples or workout history. The key is not sent to Grip Gains, stored in app preferences, synced to iCloud, or written to app logs.

You can remove the key under Settings → Frez Dyno → Frez API Key while disconnected. Frez controls its API access and request retention; see the [Frez Developer Agreement](https://developers.frez.app/en/policy). Calibration coefficients are kept only for the current connection.

## Contact

If you have questions about this privacy policy, you can open an issue on the GitHub repository.
