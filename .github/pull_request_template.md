## Summary

Describe what this change does and why.

## Tests

- [ ] `swift test --package-path app/SettleInCore` passes
- [ ] `xcodebuild -project app/SettleIn.xcodeproj -scheme SettleIn -destination 'platform=macOS' test` passes
- [ ] `swiftlint --strict --config app/.swiftlint.yml app` passes
- [ ] `bash catalog/validate.sh` passes
- [ ] I added or updated tests for this change

Check each box that applies. For a documentation-only change, say so here and leave the boxes unchecked.

## Security model

Does this change touch the security model? That covers signature checks, hash checks, the download host allowlist, the path allowlist, shell or process execution, and anything near a password.

- [ ] No
- [ ] Yes, and I explain below why it is safe
