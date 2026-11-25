# meet-asap: public keys for meeting tokens

The compose service `asap` on Kubernetes: two small nginx pods (`nginxinc/nginx-unprivileged:1.30.6-alpine3.24`
pinned by digest, non-root, read-only root) serving `/asap/<sha256(kid)>.pem` from the Secret
`meet-jwt-public` (key naming and the command are in `k8s/secret.example.yaml`). Prosody of both
shards reads `http://meet-asap.meet.svc.cluster.local:8080/asap`. Only the public key lives here; the
signing key stays in Cowork's Secret `meet-jwt`. NetworkPolicy: only the shard pods may connect; it
opens no connection.
