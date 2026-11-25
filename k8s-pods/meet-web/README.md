# meet-web: the branded Meet web image

Recipe only (`image/Containerfile`): the same steps as `deploy/web/Dockerfile` (the host install's
image), with the upstream base `ghcr.io/jitsi/web:stable-11248-2` pinned by digest
(`sha256:212b4625…`, read from ghcr.io on 2026-11-25). Built from the repository root so the branding
stays only in `deploy/web/`:

```sh
podman build -f k8s-pods/meet-web/image/Containerfile -t ghcr.io/talkchief/meet-web:$(git rev-parse --short=12 HEAD) .
```

Tag: the 12-hex commit, immutable, never `latest`, private in `ghcr.io/talkchief`. The web settings
are not in the image (k8s-pods/meet-shard ConfigMaps). Used by `k8s-pods/meet-shard`, whose kustomization
holds the placeholder tag `000000000000` until the first build. **Not built yet:** no container
runtime was available; no CI build is set up for it in this PR.
