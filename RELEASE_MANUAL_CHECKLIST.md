# Complete the manual App Store release

First run the complete automated release gate from the repository root:

```bash
python3 scripts/release_gate.py
```

It checks the app code, local privacy policy, metadata limits, tests, Release build, and static analysis. Complete the following tasks with your Apple developer account and physical devices.

If Xcode reports `has no member` for a symbol that plainly exists in the source,
the build database may be stale. The automated gate cleans before testing. If the
error persists in a manual Xcode run, delete only the stale build databases and
run the gate again:

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/Memorable-*/Build/Intermediates.noindex/XCBuildData
python3 scripts/release_gate.py
```

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

## Verify background indexing on physical devices

Simulator testing does not prove that `BGTaskScheduler` accepts or launches the
registered requests. Perform this section with a development-signed Release
build on physical devices before submission.

1. On an iOS 17 or iOS 18 device, start initial indexing, background the app,
   and confirm the home-screen indexing card changes to the background state.
   Confirm indexing either continues under the system assertion or pauses
   cleanly and resumes after foregrounding without losing progress.
2. In an Xcode-attached debug run, pause the app after scheduling recovery and
   simulate delivery of the processing task in LLDB:

   ```lldb
   expr -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.blockdeep.memorable.indexing.processing"]
   ```

   Confirm the console records task launch and completion and that the same
   persisted indexing run resumes instead of starting a second run.
3. Simulate expiration while that processing task is active:

   ```lldb
   expr -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"com.blockdeep.memorable.indexing.processing"]
   ```

   Confirm work cancels promptly, the task completes unsuccessfully, recovery
   is rescheduled once, and foregrounding resumes from persisted progress.
4. On an iOS 26 device, begin initial indexing by tapping the app's indexing
   action while the app is active. Confirm the wildcard continued-processing
   handler registers, the continued request is submitted, and progress appears
   in the system UI. Automatic launch, thermal, and foreground recovery must not
   submit a new continued-processing request; they may submit only processing
   recovery.
5. Repeat completion and expiration with the phone locked and with Low Power
   Mode enabled. Confirm there is no duplicate indexing run, crash, frozen UI,
   or lost progress.

The underscore-prefixed LLDB selectors above are development diagnostics only.
They must not be called by application code or used as App Store runtime APIs.

## Submit the release

1. Copy the reviewed text from `APP_STORE_METADATA.txt` into App Store Connect.
2. Complete the App Privacy answers using `PRIVACY_POLICY.txt` and the App Review notes.
3. Add the final screenshots, select build 8 for version 1.0.2, and submit the app for review.
