# Complete the manual App Store release

First run the complete automated release gate from the repository root:

```bash
python3 scripts/release_gate.py
```

It checks the app code, local privacy policy, metadata limits, tests, Release build, and static analysis. Complete the following tasks with your Apple developer account and physical devices.

## Publish support and privacy pages

1. Publish a support page at a stable HTTPS URL that you control.
2. Publish `PRIVACY_POLICY.txt` at a stable HTTPS URL that you control.
3. Replace the two URL instructions in `APP_STORE_METADATA.txt` with the published URLs.
4. Enter the same privacy policy URL in App Store Connect.

Do not submit placeholder or unreachable URLs. Keep the published privacy text aligned with the policy bundled in the app.

## Sign and validate the app

1. Set the distribution signing team and provisioning profile for `com.blockdeep.memorable`.
2. Run the Release build on a supported physical iPhone with an A14 chip or later.
3. Verify Photo Library permission recovery, indexing, search, explicit photo sharing, folder access, StoreKit purchase and restore, memory-pressure recovery, AirPlay, and Picture in Picture.
4. Upload the archive to App Store Connect.
5. Run TestFlight checks on at least one supported device with a large local media library.

## Submit the release

1. Copy the reviewed text from `APP_STORE_METADATA.txt` into App Store Connect.
2. Complete the App Privacy answers using `PRIVACY_POLICY.txt` and the App Review notes.
3. Add the final screenshots, select build 8 for version 1.0.2, and submit the app for review.
