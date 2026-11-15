# NAS Cockpit – notes for Claude

Building, tests and the project layout are described in `CONTRIBUTING.md` and `docs/TECHNICAL.md`.

## Building without a Mac

Cloud sessions run on Linux and can't build iOS. So:

- Every push runs `.github/workflows/ci.yml` (simulator build with Xcode 27.2, no signing). After pushing, wait
  for the result and fix build errors before calling the work done (`gh run watch`, `gh run view --log-failed`).
- TestFlight and App Store builds come from GitHub Actions: `.github/workflows/testflight.yml`, started by hand
  (Actions → TestFlight → Run workflow; `gh workflow run testflight.yml -f version=1.2.3`). It runs
  `ci_scripts/testflight.sh`: archive, sign with the developer's own certificates (repository secrets), check the
  signature, upload. Build number = UTC time `yyMMddHHmm`. Enter a new version when the project's version has
  already been released. Not Xcode Cloud: its cloud-managed certificate breaks on the umlaut in the account
  name (ITMS-90035). `ci_scripts/ci_post_clone.sh` still writes `Config/Secrets.xcconfig` with the team ID.
- Testing happens via TestFlight (release build, CloudKit **production**). New CloudKit fields have to be added by
  hand in the CloudKit Console and deployed to production – say so explicitly in the summary.
