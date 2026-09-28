# TestFlight setup

This repository already contains a manual GitHub Actions workflow at `.github/workflows/testflight.yml` that builds, signs, exports, and uploads `iPhoneLocalAI` to App Store Connect.

The app bundle identifier is:

```text
jp.localai.iphone-server
```

Do not commit certificates, provisioning profiles, App Store Connect API keys, or passwords.

## Apple-side prerequisites

Complete these steps in Apple Developer / App Store Connect before running the workflow.

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

The primary language may be Japanese. User access can remain unrestricted inside App Store Connect.

### 3. App Store Connect API key

In App Store Connect, open **Users and Access -> Integrations -> App Store Connect API** and create a team API key that can upload builds.

Record:

- Issuer ID
- Key ID
- the downloaded `AuthKey_<KEY_ID>.p8` private key

The private key is only downloadable once. Store it securely and never commit it.

### 4. Apple Distribution certificate

Create or obtain an **Apple Distribution** certificate for the same Apple Developer team.

The GitHub Actions workflow expects the certificate exported as a password-protected PKCS#12 file (`.p12`).

On a Mac, the certificate and its matching private key can be exported from Keychain Access as a `.p12`. If the private key does not exist on the Mac that generated/imported the certificate, the certificate alone cannot be exported as a usable signing identity.

### 5. App Store provisioning profile

Create an **App Store Connect** distribution provisioning profile for:

```text
jp.localai.iphone-server
```

Select the Apple Distribution certificate used above and download the resulting `.mobileprovision` file.

## GitHub repository secrets

Open:

**GitHub repository -> Settings -> Secrets and variables -> Actions -> New repository secret**

Create all of the following secrets.

| Secret | Value |
| --- | --- |
| `APPSTORE_ISSUER_ID` | App Store Connect API Issuer ID |
| `APPSTORE_API_KEY_ID` | App Store Connect API Key ID |
| `APPSTORE_API_PRIVATE_KEY` | Entire contents of `AuthKey_<KEY_ID>.p8` |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `IOS_DISTRIBUTION_CERTIFICATE_P12` | Base64-encoded `.p12` |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `IOS_PROVISIONING_PROFILE_BASE64` | Base64-encoded `.mobileprovision` |
| `KEYCHAIN_PASSWORD` | A strong temporary password used only for the CI keychain |

For macOS/Linux, encode the binary files without line wrapping:

```bash
base64 < AppleDistribution.p12 | tr -d '\n'
base64 < iPhoneLocalAI_AppStore.mobileprovision | tr -d '\n'
```

Paste the resulting single-line strings into the corresponding GitHub secrets.

For `APPSTORE_API_PRIVATE_KEY`, paste the PEM text itself, including:

```text
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
```

## Run the TestFlight workflow

The workflow is intentionally manual.

1. Open **Actions** in GitHub.
2. Select **TestFlight**.
3. Choose **Run workflow**.
4. Select branch **iphone**.
5. Start the run.

The workflow will:

1. resolve Swift packages;
2. run the simulator unit tests;
3. install the signing certificate and provisioning profile into an isolated CI keychain;
4. archive the Release build for iOS;
5. export an App Store Connect IPA;
6. upload it with `iTMSTransporter`.

The build number is set from `GITHUB_RUN_NUMBER`, so repeated uploads automatically receive a new build number.

## After upload

In App Store Connect:

1. Open **Apps -> iPhone Local AI -> TestFlight**.
2. Wait for Apple processing to complete.
3. If Apple asks for export-compliance information, answer it for the app/build.
4. Create or use an Internal Testing group.
5. Add the App Store Connect user that will test the app.
6. Add the processed build to the group.
7. Install Apple's TestFlight app on the iPhone and install **iPhone Local AI**.

Internal TestFlight distribution does not publish the app on the public App Store.

## Common failure checks

### Missing or invalid signing identity

Verify that the `.p12` contains both the Apple Distribution certificate and its private key, that the password matches, and that the certificate is not expired.

### Provisioning profile does not match

The profile must be an App Store Connect distribution profile for exactly:

```text
jp.localai.iphone-server
```

It must use the same developer team and a compatible Apple Distribution certificate.

### Bundle ID mismatch

The following must all match:

- Apple Developer App ID
- App Store Connect app record
- `PRODUCT_BUNDLE_IDENTIFIER` in `iPhoneLocalAI.xcodeproj`
- provisioning profile
- `ExportOptions.plist` generated by the workflow

Current expected value:

```text
jp.localai.iphone-server
```

### App Store Connect authentication failure

Check `APPSTORE_ISSUER_ID`, `APPSTORE_API_KEY_ID`, and the exact private-key contents. Do not base64-encode the `.p8` for this workflow.

## Security notes

- Never paste Apple signing material into an issue, pull request, commit, or chat log.
- Repository secrets are the only intended storage location for CI credentials in this project.
- Rotate the App Store Connect API key if it is exposed.
- Revoke and replace the distribution certificate if its private key is exposed.
