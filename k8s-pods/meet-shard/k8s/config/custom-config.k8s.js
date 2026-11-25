
// ---- Kubernetes (k8s-pods/meet-shard): appended after deploy/web/custom-config.js ----
// Peer-to-peer STUN on all three TalkChief TURN servers (one per worker), so a lost worker does not
// break two-person calls. TURN for peer-to-peer comes from Prosody (external_services), with
// time-limited credentials.
config.p2p = Object.assign({}, config.p2p, {
    stunServers: [
        { urls: 'stun:turn1.talkchief.io:3478' },
        { urls: 'stun:turn2.talkchief.io:3478' },
        { urls: 'stun:turn3.talkchief.io:3478' }
    ]
});
