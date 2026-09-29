# TestFlight setup

This repository uses **automatic signing with Apple cloud-managed distribution certificates** for TestFlight. GitHub Actions authenticates `xcodebuild` with an App Store Connect API key, so no local Apple Distribution `.p12` or manually downloaded provisioning profile is required.

The app bundle identifier is:

```text
jp.localai.iphone-server
```

Do not commit App Store Connect API keys or other credentials.

## Apple-side prerequisites

### 1. App ID

The explicit App ID must exist in Apple Developer:

```text
Description: iPhone Local AI
Bundle ID: jp.localai.iphone-server
```

No additional App ID capabilities are required for the current v0.1 scope.

### 2. App Store Connect app record

Create an iOS app in App Store Connect with:

```text
Name: iPhone Local AI
Bundle ID: jp.localai.iphone-server
SKU: iphone-local-ai-001
```

### 3. App Store Connect API key

In App Store Connect, open **Users and Access -> Integrations -> App Store Connect API** and create a Team API key that can distribute builds.

Record:

- Issuer ID
- Key ID
- the downloaded `AuthKey_<KEY_ID>.p8` private key

The private key is only downloadable once. Store it securely and never commit it.

The workflow passes this key to `xcodebuild` with `-authenticationKeyPath`, `-authenticationKeyID`, `-authenticationKeyIssuerID`, and `-allowProvisioningUpdates`. This allows Xcode to communicate with Apple and use automatic/cloud-managed signing.

## GitHub repository secrets

Open:

**GitHub repository -> Settings -> Secrets and variables -> Actions -> New repository secret**

Create these four secrets:

| Secret | Value |
| --- | --- |
| `APPSTORE_ISSUER_ID` | App Store Connect API Issuer ID |
| `APPSTORE_API_KEY_ID` | App Store Connect API Key ID |
| `APPSTORE_API_PRIVATE_KEY` | Entire contents of `AuthKey_<KEY_ID>.p8` |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

For `APPSTORE_API_PRIVATE_KEY`, paste the PEM text itself, including:

```text
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
```

Do **not** base64-encode the `.p8` for this workflow.

The previous manual-signing secrets are no longer used:

```text
IOS_DISTRIBUTION_CERTIFICATE_P12
IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
IOS_PROVISIONING_PROFILE_BASE64
KEYCHAIN_PASSWORD
```

They may be deleted from GitHub Secrets if they were created.

## How signing works

The Xcode project uses automatic signing. During the GitHub Actions run:

1. the App Store Connect API key is written to the temporary runner;
2. `xcodebuild archive` authenticates to Apple with that key and allows provisioning updates;
3. `xcodebuild -exportArchive` uses `signingStyle=automatic` and `destination=upload`;
4. Xcode uses Apple's cloud-managed distribution signing infrastructure to sign the distribution build and upload it to App Store Connect.

No distribution private key is stored in the repository or GitHub Secrets.

## Run the TestFlight workflow

1. Open **Actions** in GitHub.
2. Select **TestFlight**.
3. Choose **Run workflow**.
4. Select branch **iphone**.
5. Start the run.

The workflow will:

1. resolve Swift packages;
2. run simulator unit tests;
3. archive the Release build with automatic signing;
4. export and cloud-sign the distribution build;
5. upload it directly to App Store Connect.

The build number is set from `GITHUB_RUN_NUMBER`, so repeated workflow runs receive different build numbers.

## After upload

In App Store Connect:

1. Open **Apps -> iPhone Local AI -> TestFlight**.
2. Wait for Apple processing to complete.
3. Answer any export-compliance questions Apple presents for the build.
4. Create or use an Internal Testing group.
5. Add the App Store Connect user that will test the app.
6. Add the processed build to the group.
7. Install Apple's TestFlight app on the iPhone and install **iPhone Local AI**.

Internal TestFlight distribution does not publish the app on the public App Store.

## Common failure checks

### Authentication or cloud-signing authorization failure

Verify all three App Store Connect API values and the exact private-key contents. For GitHub Actions cloud signing, use a Team API key with the **Admin** role. The previous App Manager key is sufficient for many App Store Connect operations, but Xcode cloud signing can fail with `Cloud signing permission error` because API keys do not receive the per-user cloud-managed distribution certificate grant. If this error occurs, create a new Admin Team API key and replace `APPSTORE_API_KEY_ID` and `APPSTORE_API_PRIVATE_KEY` (the Issuer ID stays the same).

### Automatic provisioning failure

Verify that:

- `APPLE_TEAM_ID` is the team that owns the App ID;
- the explicit App ID `jp.localai.iphone-server` exists;
- the App Store Connect app record uses the same Bundle ID;
- the API key belongs to that App Store Connect team.

### Bundle ID mismatch

The following must all match:

- Apple Developer App ID
- App Store Connect app record
- `PRODUCT_BUNDLE_IDENTIFIER` in `iPhoneLocalAI.xcodeproj`

Current expected value:

```text
jp.localai.iphone-server
```

## Security notes

- Never paste the App Store Connect private key into an issue, pull request, commit, or public log.
- Repository secrets are the intended CI storage location for the API credentials.
- Rotate the App Store Connect API key if it is exposed.
- Cloud-managed distribution private keys remain in Apple's cloud signing infrastructure rather than being exported as local `.p12` files.
