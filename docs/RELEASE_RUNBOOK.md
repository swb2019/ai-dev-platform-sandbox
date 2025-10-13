# Release Runbook

This runbook outlines the repeatable process for promoting the web application from Staging to Production environments.

## Prerequisites

- All Staging deployments completed successfully via `Deploy Staging` workflow.
- Playwright E2E validation job (`e2e-validation`) has passed on the commit to be promoted.
- No Sev-1/Sev-2 incidents are open for staging or production environments.
- Runtime metrics (error rates, latency, resource usage) have been reviewed in the last 24 hours.

## 1. Freeze and Tag

1. Ensure `main` is green and already deployed to staging.
2. Create an annotated release tag from the validated commit:
   ```bash
   git tag -a vX.Y.Z <commit-sha> -m "release: web vX.Y.Z"
   git push origin vX.Y.Z
   ```
3. Open a release ticket or update the existing one with the tag, change summary, and risk assessment.

## 2. Promote Artifacts

1. Promote the container image digest recorded during staging (see `artifacts/sbom/web-<sha>-cyclonedx.json`) into the production Artifact Registry repository.
2. Update `deploy/k8s/overlays/prod/kustomization.yaml` to reference the immutable digest if it differs from staging.
3. Submit a PR with the manifest change. Request review from platform and security.
4. Merge the PR using a Conventional Commit (`chore(release): promote vX.Y.Z`).

## 3. Deploy to Production

1. Trigger the Production deployment workflow manually (or execute the runbook command if automated):
   ```bash
   gh workflow run deploy-production.yml -f ref=main
   ```
2. Monitor workflow logs for supply-chain, deployment, and validation gates.
3. Wait for rollout completion (`kubectl rollout status deployment/web --namespace web --timeout=10m`).
4. Validate the production Gateway endpoint manually with a smoke test:
   ```bash
   PRODUCTION_IP=$(kubectl get gateway web -n web -o jsonpath='{.status.addresses[0].value}')
   curl --fail --retry 5 "http://$PRODUCTION_IP" | head
   ```

## 4. Post-Deployment Verification

- Confirm dashboards (APM, availability, error budget) remain within SLOs for 30 minutes.
- Verify CDN/WAF caches if applicable.
- Announce release in the `#releases` channel with tag, summary, and validation evidence.

## 5. Rollback Strategy

1. If issues arise, trigger an immediate rollback by redeploying the previous known-good tag:
   ```bash
   git tag -f rollback-vX.Y.Z <previous-commit>
   git push origin rollback-vX.Y.Z --force
   gh workflow run deploy-production.yml -f ref=rollback-vX.Y.Z
   ```
2. Alternatively, execute `kubectl rollout undo deployment/web -n web` while investigating.
3. File an incident report, collect logs, and schedule a postmortem within 24 hours.

## References

- `docs/DEPLOYMENT.md` for environment topology and GitHub Actions overview.
- `docs/SECURITY.md` for release approval requirements and signing policies.
- `docs/AGENT_PROTOCOLS.md` for agent responsibilities during release windows.
