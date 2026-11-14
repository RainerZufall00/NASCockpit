# NAS Cockpit – notes for Claude

Building, tests and the project layout are described in `CONTRIBUTING.md` and `docs/TECHNICAL.md`.

## Building without a Mac

Cloud sessions run on Linux and can't build iOS. So:

- Every push runs `.github/workflows/ci.yml` (simulator build with Xcode 27.2, no signing). After pushing, wait
  for the result and fix build errors before calling the work done (`gh run watch`, `gh run view --log-failed`).
- TestFlight and App Store builds come from Xcode Cloud, started by hand in App Store Connect.
  `ci_scripts/ci_post_clone.sh` writes `Config/Secrets.xcconfig` with the team ID; Xcode Cloud sets the build
  number.
- Testing happens via TestFlight (release build, CloudKit **production**). New CloudKit fields have to be added by
  hand in the CloudKit Console and deployed to production – say so explicitly in the summary.
