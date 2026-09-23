# Heretic QPack GitHub Actions build

The `Build Heretic QPack` workflow converts the compatible MLX checkpoint
`froggeric/Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit` into a Swiftlet QPack,
stores the resumable working directory on TrueNAS, and publishes the finished
container directly to Hugging Face.

It is manual-only. Pushing application code or creating a Priv AI release does
not run this large model job.

## Why TrueNAS is required

GitHub's `macos-26` runner is Apple Silicon, but it has only 14 GB of temporary
SSD. The completed QPack is approximately 19.5 GB. The workflow mounts a
dedicated TrueNAS `qpack-builds` SMB share through Tailscale. Configure that
share to point only at the existing QPack directory on the HDD pool. The
workflow writes the container and Hugging Face's resumable upload cache under:

```text
qpack-builds/qwen3.6-35b-heretic.qpack
qpack-builds/.hf-xet-cache
```

The workflow first requires at least 50 GiB free on that share. This accounts
for the QPack, the upload cache, and working room. It does not put model weights
or the upload cache on the runner's temporary SSD. A small Swift build and
Python tooling still use the runner disk.

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
| `TRUENAS_SMB_USERNAME` | Dedicated SMB user `git`, allowed on the `qpack-builds` share only |
| `TRUENAS_SMB_PASSWORD` | Password for that SMB user |
| `HF_TOKEN` | Hugging Face token with write access to the destination model repo |

The intended TrueNAS `git` account should have no shell, sudo, or TrueNAS API
role, and should be allowed only on the dedicated `qpack-builds` share.

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

1. Confirm the repository secrets `TRUENAS_SMB_USERNAME`,
   `TRUENAS_SMB_PASSWORD`, `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, and a
   fine-grained `HF_TOKEN` are configured.
2. Open **Actions -> Build Heretic QPack** in GitHub and choose **Run workflow**.
3. Keep **Preflight only** enabled for the first run. It writes and removes a
   tiny probe file, checks the mounted share's free capacity, and does not
   download or create model weights.
4. After preflight succeeds, run again with **Preflight only** disabled and
   enter the destination as `HUGGING_FACE_USER/repository-name`.

Do not delete the TrueNAS QPack directory after an interrupted run. Start the
workflow again and it will resume. No GitHub artifact is created; the final
model is uploaded directly from TrueNAS to Hugging Face.

After a successful upload, paste the main Hugging Face repository URL into
Priv AI's Hugging Face model picker. The generated model card includes the
`swiftlet` and `qpack` tags that Priv AI requires for QPack discovery.

## Security notes

- Use the dedicated `git` SMB account and `qpack-builds` share; do not grant it
  access to the broader storage share. TrueNAS adds SMB users to
  `builtin_users`, so explicit share-level restrictions are required to prevent
  access to other existing shares.
- Restrict `tag:ci` to TrueNAS TCP port 445.
- Use a fine-grained Hugging Face token scoped to the destination repository.
- Rotate any credential that is accidentally printed or copied into a workflow
  input. Secrets belong only in GitHub's encrypted secret store.
