# Heretic QPack GitHub Actions build

The `Build Heretic QPack` workflow converts the compatible MLX checkpoint
`froggeric/Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit` into a Swiftlet QPack,
stores the resumable working directory on TrueNAS, and publishes the finished
container directly to Hugging Face.

It is manual-only. Pushing application code or creating a Priv AI release does
not run this large model job.

## Why TrueNAS is required

GitHub's `macos-26` runner is Apple Silicon, but it has only 14 GB of temporary
SSD. The completed QPack is approximately 19.5 GB. The workflow mounts the
TrueNAS `ssd-pool` share through Tailscale and writes the container to:

```text
ssd-pool/qpack-builds/qwen3.6-35b-heretic.qpack
```

Rerunning the workflow uses the same directory. Swiftlet resumes an interrupted
install using its `.install-progress.json` sidecar and returns immediately when
the container is already complete.

## Repository secrets

Create these encrypted secrets in **GitHub repository -> Settings -> Secrets
and variables -> Actions**:

| Secret | Purpose |
|---|---|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | Tailscale OAuth client secret |
| `TRUENAS_SMB_USERNAME` | SMB user allowed to write to `ssd-pool` |
| `TRUENAS_SMB_PASSWORD` | Password for that SMB user |
| `HF_TOKEN` | Hugging Face token with write access to the destination model repo |

The current SMB account name is `jbenzaquen`; store it as the secret instead of
putting it in the workflow.

## Tailscale setup

1. Open the Tailscale admin console.
2. Create or authorize the tag `tag:ci`.
3. Create an OAuth client with the `auth_keys` write scope and `tag:ci`.
4. Save its ID and secret in the GitHub secrets above.
5. If the tailnet uses restrictive grants/ACLs, allow `tag:ci` to reach
   `truenas-scale` on TCP port 445 only.

The workflow creates an ephemeral, tagged Tailscale node. Tailscale removes it
after the job finishes.

## Run the workflow

1. Open **Actions -> Build Heretic QPack** in GitHub.
2. Choose **Run workflow**.
3. Enter the destination as `HUGGING_FACE_USER/repository-name`.
4. Start the run.

Do not delete the TrueNAS QPack directory after an interrupted run. Start the
workflow again and it will resume. No GitHub artifact is created; the final
model is uploaded directly from TrueNAS to Hugging Face.

After a successful upload, paste the main Hugging Face repository URL into
Priv AI's Hugging Face model picker. The generated model card includes the
`swiftlet` and `qpack` tags that Priv AI requires for QPack discovery.

## Security notes

- Use a dedicated SMB account limited to `ssd-pool/qpack-builds` if practical.
- Restrict `tag:ci` to TrueNAS TCP port 445.
- Use a fine-grained Hugging Face token scoped to the destination repository.
- Rotate any credential that is accidentally printed or copied into a workflow
  input. Secrets belong only in GitHub's encrypted secret store.
