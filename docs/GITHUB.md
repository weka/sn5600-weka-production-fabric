# Publish the handover privately

The repository is prepared locally. No remote GitHub repository was created
during packaging because a GitHub connection and destination owner were not
confirmed. The publication helper defaults to private visibility.

On the Mac, extract the ZIP, enter the extracted repository directory, and
authenticate your GitHub CLI if it is not already authenticated:

```bash
gh auth login
bash run_checks.sh verify
bash scripts/publish_github.sh OWNER/sn5600-weka-production-fabric
```

Replace OWNER with your GitHub user or organization. Use an organization only
if you have the required permission to create repositories there. The helper
stops if an origin remote already exists, so it cannot silently push this
handover over a different existing repository.

If Git asks for an author identity, set your usual Git name and email before
rerunning. The helper commits the reviewed local content, creates a private
repository and pushes the main branch. It does not connect to production.

Before calling the repository a complete rebuild source, collect the exact
host-side RoCE precheck/deployment payloads with
`bash scripts/collect_roce_reference.sh`. Their absence is explicitly recorded
in the current package. Add the latest cross-leaf test output after reviewing it.
