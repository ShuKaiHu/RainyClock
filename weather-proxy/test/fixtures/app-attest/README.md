These public Apple-signed attestation fixtures come from the MIT-licensed
`uebelack/node-app-attest` upstream repository's `test/fixtures` directory, retrieved
2026-09-16. Original license is preserved in `LICENSE`.

- https://github.com/uebelack/node-app-attest/tree/main/test/fixtures
- They belong to upstream's example app, never to RainyClock or its users.
- The certificates are historical. Tests inject a 2024 verification time for the
  positive case and also assert that current-time verification rejects expiry.
- Tests use Apple's real App Attest root pinned by the package. Membership tests
  additionally generate ephemeral, explicitly synthetic StoreKit signing roots,
  never trusted by a running service. No live Apple account/ad traffic is used.
