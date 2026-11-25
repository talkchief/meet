#!/usr/bin/env python3
"""Offline regression for the Meet pod artifacts under pods/ (k8s-pods/README.md).

No cluster, kubectl, kustomize or container runtime: it loads every YAML file, follows every
kustomization from k8s-pods/overlays/cowork, and checks the rules of the cowork cluster design (kz5
doc/collaboration_cluster_architecture.md 5.7-5.9, 8, 10.2) and of the shared Cowork/Meet contract.
It also runs the bridge sidecar's drain against a local stand-in of the bridge's REST API.
Known gaps (placeholders that only a build or the cluster can fill) are printed as GAP lines and
do not fail the run; everything else must PASS.

    python3 scripts/test-k8s-pods.py
"""

import ast
import hashlib
import http.server
import importlib.util
import os
import re
import sys
import tempfile
import threading

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PODS = os.path.join(ROOT, 'k8s-pods')
FAILURES = []
GAPS = []
DIGEST = re.compile(r'^[a-z0-9.\-/:]+@sha256:[0-9a-f]{64}$')


def check(condition, message):
    print('%s: %s' % ('PASS' if condition else 'FAIL', message))
    if not condition:
        FAILURES.append(message)


def gap(message):
    print('GAP: %s' % message)
    GAPS.append(message)


def rel(path):
    return os.path.relpath(path, ROOT).replace(os.sep, '/')


def read(path):
    with open(os.path.join(ROOT, path), encoding='utf-8') as handle:
        return handle.read()


def load(path):
    return [doc for doc in yaml.safe_load_all(read(path)) if doc]


# ------------------------------------------------------------------ every YAML file parses
yaml_files = []
for base, _, files in os.walk(PODS):
    for name in files:
        if name.endswith(('.yaml', '.yml')):
            yaml_files.append(os.path.join(base, name))
bad = []
for path in yaml_files:
    try:
        load(rel(path))
    except yaml.YAMLError as err:
        bad.append('%s: %s' % (rel(path), err))
check(not bad, 'every YAML file under k8s-pods/ parses (%d files)%s' % (len(yaml_files), ''.join('\n  ' + b for b in bad)))

# ------------------------------------------------------------------ kustomizations, resolved from the overlay
OBJECTS = []          # (source file, object with namespace applied)
IMAGES = {}           # kustomize image name -> (newName, newTag/digest)
GENERATED = {}        # ConfigMap name -> {key: file path}
MERGED = {}           # ConfigMap name -> literals merged in by an overlay
visited = []


def walk_kustomization(directory, namespace=None):
    kpath = os.path.join(directory, 'kustomization.yaml')
    check(os.path.isfile(kpath), '%s has a kustomization.yaml' % rel(directory))
    if not os.path.isfile(kpath):
        return
    visited.append(rel(directory))
    kust = load(rel(kpath))[0]
    ns = kust.get('namespace', namespace)
    for res in kust.get('resources', []):
        target = os.path.normpath(os.path.join(directory, res))
        if os.path.isdir(target):
            walk_kustomization(target, None)
            continue
        check(os.path.isfile(target), '%s: resource %s exists' % (rel(kpath), res))
        if not os.path.isfile(target):
            continue
        check(not os.path.basename(target).startswith('secret'), '%s: no Secret file is a resource (%s)' % (rel(kpath), res))
        for obj in load(rel(target)):
            if ns and obj['kind'] not in ('Namespace', 'ClusterRole', 'ClusterRoleBinding',
                                          'ValidatingAdmissionPolicy', 'ValidatingAdmissionPolicyBinding'):
                obj.setdefault('metadata', {})['namespace'] = ns
            OBJECTS.append((rel(target), obj))
    for gen in kust.get('configMapGenerator', []):
        if gen.get('behavior') == 'merge':
            MERGED[gen['name']] = dict(l.split('=', 1) for l in gen.get('literals', []))
            continue
        files = {}
        for entry in gen.get('files', []) + gen.get('envs', []):
            key, _, src = entry.rpartition('=') if '=' in entry else (os.path.basename(entry), '', entry)
            path = os.path.normpath(os.path.join(directory, src))
            check(os.path.isfile(path), '%s: generator %s file %s exists' % (rel(kpath), gen['name'], src))
            files[key or os.path.basename(src)] = path
        GENERATED[gen['name']] = files
    for image in kust.get('images', []):
        IMAGES[image['name']] = (image.get('newName', image['name']), image.get('digest') or image.get('newTag'))


walk_kustomization(os.path.join(PODS, 'overlays', 'cowork'))
for name in ('meet-namespace', 'meet-asap', 'meet-events', 'meet-shard', 'meet-haproxy', 'meet-jvb', 'cluster-autoscaler'):
    check('k8s-pods/%s/k8s' % name in visited, 'the cowork overlay composes k8s-pods/%s' % name)
check(all(not any(o['kind'] == 'Secret' for _, o in OBJECTS) for _ in [0]), 'no Secret object is applied from Git')


def find(kind, name):
    hits = [o for _, o in OBJECTS if o['kind'] == kind and o['metadata']['name'] == name]
    check(len(hits) == 1, '%s %s exists exactly once' % (kind, name))
    return hits[0] if hits else {}


def pod_spec(obj):
    return obj['spec']['template']['spec']


def env_of(container):
    return dict((e['name'], e) for e in container.get('env', []))


# ------------------------------------------------------------------ images
WORKLOADS = [o for _, o in OBJECTS if o['kind'] in ('Deployment', 'StatefulSet', 'DaemonSet')]
for obj in WORKLOADS:
    spec = pod_spec(obj)
    for container in spec.get('initContainers', []) + spec['containers']:
        image = container['image']
        label = '%s/%s' % (obj['metadata']['name'], container['name'])
        check(':latest' not in image and image != 'latest', '%s: no latest tag' % label)
        if image in IMAGES:
            name, tag = IMAGES[image]
            if re.fullmatch(r'0{12}', str(tag)):
                gap('%s runs %s:%s, a placeholder until the meet-web image is built and pushed (no container runtime here)' % (label, name, tag))
            else:
                check(DIGEST.match('%s@%s' % (name, tag)) is not None, '%s: image %s pinned by digest' % (label, name))
        else:
            check(DIGEST.match(image) is not None, '%s: image %s pinned by digest' % (label, image))
containerfile = read('k8s-pods/meet-web/image/Containerfile')
check(re.search(r'^FROM ghcr\.io/jitsi/web:stable-11248-2@sha256:[0-9a-f]{64}$', containerfile, re.M) is not None,
      'meet-web base image is ghcr.io/jitsi/web:stable-11248-2 pinned by digest')
check('DJM_TAG=stable-11248-2' in read('deploy/VERSION'), 'deploy/VERSION still pins stable-11248-2 (the tag every Jitsi image here uses)')
check(all('stable-11248-2@sha256:' in c['image'] for o in WORKLOADS for c in pod_spec(o)['containers'] if 'ghcr.io/jitsi/' in c['image']),
      'every upstream Jitsi image is stable-11248-2 pinned by digest')

# ------------------------------------------------------------------ requests, limits, probes
for obj in WORKLOADS:
    for container in pod_spec(obj)['containers']:
        label = '%s/%s' % (obj['metadata']['name'], container['name'])
        res = container.get('resources', {})
        if label == 'meet-jvb/jvb':
            # Owner (2026-11-25): no CPU limit on the bridge (throttling shows as jitter).
            check(res['requests'].get('cpu') and res['requests'].get('memory') and res['limits'].get('memory') and 'cpu' not in res['limits'],
                  '%s: cpu and memory requests, memory limit, no CPU limit (owner decision)' % label)
            continue
        check(all(res.get(k, {}).get(r) for k in ('requests', 'limits') for r in ('cpu', 'memory')),
              '%s: cpu and memory requests and limits' % label)
        check('readinessProbe' in container and 'livenessProbe' in container, '%s: readiness and liveness probes' % label)
    for container in pod_spec(obj).get('initContainers', []):
        res = container.get('resources', {})
        check(all(res.get(k, {}).get(r) for k in ('requests', 'limits') for r in ('cpu', 'memory')),
              '%s/%s (init): cpu and memory requests and limits' % (obj['metadata']['name'], container['name']))

# ------------------------------------------------------------------ shards
shard0 = find('Deployment', 'meet-shard-0')
shard1 = find('Deployment', 'meet-shard-1')
for shard in (shard0, shard1):
    spec = pod_spec(shard)
    name = shard['metadata']['name']
    terms = spec['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    check(shard['spec']['replicas'] == 1 and shard['spec']['strategy']['type'] == 'Recreate', '%s: one pod, Recreate' % name)
    check(any(t['topologyKey'] == 'kubernetes.io/hostname' and t['labelSelector']['matchLabels'] == {'app.kubernetes.io/name': 'meet-shard'} for t in terms),
          '%s: required anti-affinity against every shard pod on the same worker' % name)
    check(spec['nodeSelector'] == {'talkchief.io/pool': 'cowork-wk'}, '%s: runs on the workers' % name)
    by = dict((c['name'], c) for c in spec['containers'])
    check(sorted(by) == ['jicofo', 'prosody', 'web'], '%s: containers web, prosody, jicofo' % name)
    want = {'web': ('50m', '128Mi'), 'prosody': ('100m', '256Mi'), 'jicofo': ('200m', '768Mi')}
    check(all((by[c]['resources']['requests']['cpu'], by[c]['resources']['requests']['memory']) == want[c] for c in want),
          '%s: requests as the design (web 50m/128Mi, prosody 100m/256Mi, jicofo 200m/768Mi)' % name)
    check(by['web']['readinessProbe']['httpGet']['port'] == 'http' and by['prosody']['readinessProbe']['httpGet']['path'] == '/http-bind'
          and by['jicofo']['readinessProbe']['httpGet']['path'] == '/stats',
          '%s: probes on web HTTP, Prosody BOSH /http-bind and Jicofo REST' % name)
    penv = env_of(by['prosody'])
    check(penv['TURN_CREDENTIALS']['valueFrom']['secretKeyRef'] == {'name': 'turn-meet', 'key': 'static-auth-secret'},
          '%s: TURN secret from Secret turn-meet' % name)
    check(penv['TALKCHIEF_EVENTS_SECRET']['valueFrom']['secretKeyRef'] == {'name': 'meet-events', 'key': 'secret'},
          '%s: events secret from Secret meet-events' % name)
    check(all('valueFrom' in penv[k] for k in ('JICOFO_AUTH_PASSWORD', 'JVB_AUTH_PASSWORD')), '%s: XMPP passwords from Secrets' % name)
    check(any(p['containerPort'] == 5222 for p in by['prosody']['ports']), '%s: Prosody listens for bridges on 5222' % name)


def normalize(doc):
    text = yaml.safe_dump(doc, sort_keys=True)
    return text.replace('meet-shard-1', 'meet-shard-N').replace('meet-shard-0', 'meet-shard-N').replace("talkchief.io/shard: '1'", 'S').replace("talkchief.io/shard: '0'", 'S')


check(normalize(shard0) == normalize(shard1), 'shard 1 is identical to shard 0 apart from its number')
services = [o for _, o in OBJECTS if o['kind'] == 'Service' and o['metadata']['name'] in ('meet-shard-0', 'meet-shard-1')]
check(len(services) == 2 and all(s['spec']['type'] == 'ClusterIP' and {p['port'] for p in s['spec']['ports']} == {80, 5222} for s in services),
      'one ClusterIP Service per shard with web 80 and XMPP 5222')

# ------------------------------------------------------------------ shard config drift against deploy/
for name in ('mod_talkchief_room_events.lua', 'mod_talkchief_room_policy.lua'):
    check(read('k8s-pods/meet-shard/k8s/config/plugins/' + name) == read('deploy/prosody/plugins/' + name), 'Prosody module %s is a byte copy of deploy/' % name)
for name in ('custom-config.js', 'custom-interface_config.js'):
    check(read('k8s-pods/meet-shard/k8s/config/' + name) == read('deploy/web/' + name), '%s is a byte copy of deploy/web/' % name)


def env_file(path):
    out = {}
    for line in read(path).splitlines():
        if line.strip() and not line.lstrip().startswith('#'):
            key, _, value = line.partition('=')
            out[key.strip()] = value
    return out


host_env = env_file('deploy/env.talkchief')
shard_env = env_file('k8s-pods/meet-shard/k8s/config/shard.env')
left_out = {'CONFIG', 'HTTP_PORT', 'HTTPS_PORT', 'JVB_ADVERTISE_IPS'}
changed = {'ENABLE_HTTP_REDIRECT', 'JWT_ASAP_KEYSERVER', 'TURN_HOST', 'TURNS_HOST', 'TURNS_PORT'}
drift = sorted(k for k in host_env if k not in left_out | changed and shard_env.get(k) != host_env[k])
check(not drift, 'shard.env keeps every deploy/env.talkchief value except the listed Kubernetes changes%s' % ('' if not drift else ': ' + ', '.join(drift)))
check(not (left_out & set(shard_env)), 'shard.env leaves out host-only keys (CONFIG, HTTP_PORT, HTTPS_PORT, JVB_ADVERTISE_IPS)')
check(shard_env['AUTH_TYPE'] == 'jwt' and shard_env['JWT_ACCEPTED_ISSUERS'] == 'talkchief-cowork' and shard_env['JWT_ACCEPTED_AUDIENCES'] == 'talkchief-meet'
      and shard_env['JWT_SIGN_TYPE'] == 'RS256', 'JWT RS256, issuer talkchief-cowork, audience talkchief-meet')
check(shard_env['JWT_ASAP_KEYSERVER'] == 'http://meet-asap.meet.svc.cluster.local:8080/asap', 'Prosody fetches public keys from the meet-asap Service')
check(shard_env['TALKCHIEF_EVENTS_URL'].startswith('http://meet-events.meet.svc.cluster.local:8080/'), 'room events go to the meet-events relay')
check(shard_env.get('MAX_BRIDGE_PARTICIPANTS') == '25', 'Jicofo max participants per bridge set explicitly (25, CPX22 placeholder)')
jicofo_conf = read('k8s-pods/meet-shard/k8s/config/custom-jicofo.conf')
check('jicofo.bridge.max-bridge-participants = 25' in jicofo_conf and 'jicofo.bridge.max-bridge-participants-per-interval = 30' in jicofo_conf,
      'custom-jicofo.conf: max-bridge-participants 25, max-bridge-participants-per-interval 30')
code = lambda text: '\n'.join(l for l in text.splitlines() if not l.lstrip().startswith('#'))
meet_conf = code(read('k8s-pods/meet-shard/k8s/config/custom-meet.conf'))
host_conf = read('deploy/web/custom-meet.conf')
locations = lambda text: set(re.findall(r'^\s*location\s+([^{]+?)\s*\{', text, re.M))
check(locations(meet_conf) == locations(host_conf) | {'= /talkchief-shard-health'}, 'custom-meet.conf keeps every location of deploy/ and adds the shard health page')
check('10.1.0.46' not in meet_conf and '127.0.0.11' not in meet_conf and meet_conf.count('set $tccowork cowork-app.cowork.svc.cluster.local:8065;') == 2
      and meet_conf.count('proxy_set_header Host cowork.talkchief.io;') == 2,
      'custom-meet.conf reaches Cowork at cowork-app.cowork.svc:8065 with Host cowork.talkchief.io, no host addresses')
events_conf = code(read('k8s-pods/meet-events/k8s/events.conf'))
check('set $tccowork cowork-app.cowork.svc.cluster.local:8065;' in events_conf and 'proxy_pass http://$tccowork/api/v4/talkchief/meetings/events;' in events_conf and 'proxy_set_header Host cowork.talkchief.io;' in events_conf
      and '10.1.0.46' not in events_conf, 'the events relay forwards to cowork-app.cowork.svc:8065 with Host cowork.talkchief.io')

# ------------------------------------------------------------------ TURN and STUN
TURN = ['turn1.talkchief.io', 'turn2.talkchief.io', 'turn3.talkchief.io']
global_config = shard_env['GLOBAL_CONFIG'].replace('\\n', '\n')
entries = [dict(re.findall(r'(\w+) = ("[^"]*"|\w+)', e)) for e in re.findall(r'\{([^{}]*)\}', global_config)]
entries = [dict((k, v.strip('"')) for k, v in e.items()) for e in entries]
want = set()
for host in TURN:
    want |= {('stun', host, '3478', 'udp'), ('turn', host, '3478', 'udp'), ('turn', host, '3478', 'tcp'), ('turns', host, '443', 'tcp')}
have = {(e.get('type'), e.get('host'), e.get('port'), e.get('transport')) for e in entries}
check(have == want, 'Prosody external_services: stun 3478, turn 3478 UDP+TCP and turns 443 on each of turn1/2/3')
check(all(e.get('secret') == 'true' and 'username' not in e and 'password' not in e for e in entries if e['type'] != 'stun'),
      'TURN credentials are time-limited from the shared secret (secret = true), no static user or password')
check(shard_env['TURN_HOST'].split(',') == TURN and shard_env['TURNS_HOST'].split(',') == TURN and shard_env['TURNS_PORT'] == '443',
      'TURN_HOST/TURNS_HOST list the three servers (turns on 443)')
p2p = read('k8s-pods/meet-shard/k8s/config/custom-config.k8s.js')
check(all("stun:%s:3478" % h in p2p for h in TURN), 'peer-to-peer STUN lists turn1/2/3 on 3478')
static = [rel(os.path.join(b, f)) for b, _, fs in os.walk(PODS) for f in fs
          if re.search(r'TURN_(USERNAME|PASSWORD)|static-auth-secret\s*=|external_service_secret\s*=', open(os.path.join(b, f), encoding='utf-8', errors='ignore').read())]
check(not static, 'no static TURN credential in any config%s' % ('' if not static else ': ' + ', '.join(static)))

# ------------------------------------------------------------------ HAProxy and the load balancer
haproxy = find('StatefulSet', 'meet-haproxy')
check(haproxy['spec']['replicas'] == 2 and haproxy['spec']['podManagementPolicy'] == 'Parallel', 'HAProxy: two pods, started in parallel')
terms = pod_spec(haproxy)['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
check(terms[0]['topologyKey'] == 'kubernetes.io/hostname', 'HAProxy pods on different workers')
pdb = find('PodDisruptionBudget', 'meet-haproxy')
check(pdb['spec']['minAvailable'] == 1 and pdb['spec']['selector']['matchLabels'] == {'app.kubernetes.io/name': 'meet-haproxy'}, 'HAProxy PDB keeps one pod')
peers = find('Service', 'meet-haproxy-peers')
check(peers['spec']['clusterIP'] == 'None' and peers['spec']['publishNotReadyAddresses'] is True, 'headless peers Service publishes starting pods')
lb = find('Service', 'meet-haproxy')
ann = lb['metadata']['annotations']
P = 'load-balancer.hetzner.cloud/'
ports = dict((p['name'], p) for p in lb['spec']['ports'])
check(lb['spec']['type'] == 'LoadBalancer' and ann[P + 'name'] == 'meet-lb' and ann[P + 'type'] == 'lb11', 'Hetzner LB meet-lb, type lb11')
check(ann[P + 'use-private-ip'] == 'true', 'meet-lb targets the workers over the private network')
check(ann[P + 'protocol'] == 'tcp' and ports['https']['port'] == 443, 'TCP passthrough on 443 (TLS ends in HAProxy)')
check(ann[P + 'health-check-protocol'] == 'http' and ann[P + 'health-check-http-path'] == '/talkchief-haproxy-health'
      and ann[P + 'health-check-interval'] == '5s' and ann[P + 'health-check-retries'] == '2',
      'health check http /talkchief-haproxy-health every 5 s, 2 retries')
check(int(ann[P + 'health-check-port']) == ports['http']['nodePort'], 'health check port is the node port of HAProxy\'s port 80 frontend')
check(not any('sticky' in k or 'cookie' in k for k in ann), 'no load balancer stickiness')
check(lb['spec']['externalTrafficPolicy'] == 'Local', 'externalTrafficPolicy Local: only workers with an HAProxy pod pass the check')
known = set(re.findall(r'`(load-balancer\.hetzner\.cloud/[a-z0-9-]+)`', read('k8s-pods/meet-haproxy/hcloud-lb-annotations.txt')))
check(set(ann) <= known, 'every annotation name is in the hcloud CCM reference (k8s-pods/meet-haproxy/hcloud-lb-annotations.txt)')
cfg = read('k8s-pods/meet-haproxy/k8s/haproxy.cfg.template')
check(re.search(r'^\s*timeout tunnel 1h$', cfg, re.M) is not None, 'HAProxy timeout tunnel 1h for XMPP websockets')
check(re.search(r'^\s*timeout client 90s$', cfg, re.M) and re.search(r'^\s*timeout server 90s$', cfg, re.M), 'HAProxy client/server timeouts above the 60 s BOSH poll')
check('hash-type consistent' in cfg and 'balance hash var(txn.shardkey)' in cfg and 'stick-table type string len 256 size 200k expire 12h peers shards' in cfg,
      'rooms by consistent hash of tenant and room, peered stick table (feat/ha-shards)')
check('HPO' in cfg and '%HU' not in cfg and '%r' not in cfg and '%HQ' not in cfg, 'the log has the path only, never the query string (JWT)')
servers = re.findall(r'^\s*server (meet-shard-\d) (\S+) id (\d+)$', cfg, re.M)
check(sorted(set(servers)) == [('meet-shard-0', 'meet-shard-0.meet.svc.cluster.local:80', '1'), ('meet-shard-1', 'meet-shard-1.meet.svc.cluster.local:80', '2')]
      and len(servers) == 4, 'both backends list the two shard Services with fixed ids')
check(cfg.count('/talkchief-shard-health') >= 3 and cfg.count('uri /http-bind') == 2 and 'inter 2s fall 2' in cfg, 'shard health: Jicofo via web and Prosody BOSH, out after 2 failures in 2 s steps')
check('monitor-uri /talkchief-haproxy-health' in cfg and 'monitor fail if no_shard' in cfg and 'monitor fail if starting' in cfg,
      'LB check fails with no shard and during the 30 s startup grace')
check('peer meet-haproxy-0 @PEER0@:8445' in cfg and 'peer meet-haproxy-1 @PEER1@:8445' in cfg, 'HAProxy peers by pod name on 8445')

# ------------------------------------------------------------------ bridges
jvb = find('Deployment', 'meet-jvb')
spec = pod_spec(jvb)
by = dict((c['name'], c) for c in spec['containers'])
jenv = env_of(by['jvb'])
check(spec['hostNetwork'] is True and spec['dnsPolicy'] == 'ClusterFirstWithHostNet', 'JVB: host network with cluster DNS')
check(any(p['containerPort'] == 10000 and p.get('hostPort') == 10000 and p['protocol'] == 'UDP' for p in by['jvb']['ports']), 'JVB: UDP 10000 on the node')
check(spec['nodeSelector'] == {'talkchief.io/pool': 'cowork-jvb'}, 'JVB: only on cowork-jvb nodes')
check({'key': 'talkchief.io/pool', 'operator': 'Equal', 'value': 'cowork-jvb', 'effect': 'NoSchedule'} in spec['tolerations'], 'JVB: tolerates the bridge taint')
terms = spec['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
check(terms[0]['topologyKey'] == 'kubernetes.io/hostname', 'JVB: one per node (required anti-affinity)')
check(spec['terminationGracePeriodSeconds'] >= 10800, 'JVB: termination grace at least 3 h')
check('drained' in ' '.join(by['jvb']['lifecycle']['preStop']['exec']['command'])
      and by['sidecar']['lifecycle']['preStop']['exec']['command'][-1] == 'drain', 'JVB preStop waits for the sidecar\'s drain and graceful shutdown')
sidecar_src = read('k8s-pods/meet-jvb/k8s/jvb_sidecar.py')
check("'/colibri/drain/enable'" in sidecar_src and "{'graceful-shutdown': 'true'}" in sidecar_src and "'/colibri/shutdown'" in sidecar_src,
      'drain: enable drain, then POST /colibri/shutdown {"graceful-shutdown":"true"}')
check(jenv['JVB_DISABLE_STUN']['value'] == '1' and jenv['XMPP_SERVER']['value'] == 'meet-shard-0.meet.svc.cluster.local,meet-shard-1.meet.svc.cluster.local',
      'JVB: STUN off, registers with both shards\' Prosody')
check(jenv['COLIBRI_REST_ENABLED']['value'] == 'true' and jenv['SHUTDOWN_REST_ENABLED']['value'] == 'true'
      and 'private.host = 127.0.0.1' in read('k8s-pods/meet-jvb/k8s/custom-jvb.conf'), 'JVB: colibri and shutdown REST on, on loopback only')
check('JVB_ADVERTISE_IPS="$(cat /shared/advertise-ip)"' in by['jvb']['command'][-1] and spec['initContainers'][0]['command'][-1] == 'advertise'
      and "169.254.169.254/hetzner/v1/metadata/public-ipv4" in sidecar_src, 'JVB_ADVERTISE_IPS from the Hetzner metadata service at start')
check(by['jvb']['resources'] == {'requests': {'cpu': '1500m', 'memory': '2560Mi'}, 'limits': {'memory': '3Gi'}},
      'JVB sized for a CPX22 bridge node: requests 1.5 CPU / 2.5 GiB, memory limit 3 GiB, no CPU limit')
check(jenv['VIDEOBRIDGE_MAX_MEMORY']['value'] == '1536m', 'JVB Java heap 1536m')

# ------------------------------------------------------------------ bridge relay (Octo): prepared, off, one toggle
relay = env_file('k8s-pods/meet-namespace/k8s/relay.env')
check(relay == {'ENABLE_OCTO': 'false', 'JVB_OCTO_REGION': 'eu', 'JICOFO_OCTO_REGION': 'eu',
                'OCTO_BRIDGE_SELECTION_STRATEGY': 'IntraRegionBridgeSelectionStrategy'},
      'relay settings: off, region eu, IntraRegionBridgeSelectionStrategy')
check(MERGED.get('meet-relay') == {'ENABLE_OCTO': 'false'}, 'the cowork overlay holds the one relay toggle, off')
check(any(e.get('configMapRef', {}).get('name') == 'meet-relay' for e in by['jvb']['envFrom'])
      and jenv['JVB_OCTO_RELAY_ID']['valueFrom']['fieldRef']['fieldPath'] == 'metadata.name' and 'ENABLE_OCTO' not in jenv,
      'bridges read the relay toggle from meet-relay; relay id is the pod name')
check(all(any(e.get('configMapRef', {}).get('name') == 'meet-relay' for e in c['envFrom'])
          for sh in (shard0, shard1) for c in pod_spec(sh)['containers'] if c['name'] == 'jicofo'),
      'both shards\' Jicofo read the relay settings from meet-relay')
check(spec['automountServiceAccountToken'] is False
      and not any(m['name'] == 'sa-token' for m in by['jvb']['volumeMounts'])
      and any(m['name'] == 'sa-token' for m in by['sidecar']['volumeMounts']), 'the API token is mounted into the sidecar only')
check(jvb['spec']['template']['metadata']['annotations']['prometheus.io/port'] == '9888', 'JVB /metrics scraped through the sidecar on 9888')
role = find('Role', 'meet-jvb-deletion-cost')
check(role['rules'] == [{'apiGroups': [''], 'resources': ['pods'], 'verbs': ['get', 'patch']}], 'sidecar Role: get and patch pods only')
vap = find('ValidatingAdmissionPolicy', 'meet-jvb-own-pod-only')
check("authentication.kubernetes.io/pod-name" in str(vap['spec']['validations']) and 'pod-deletion-cost' in str(vap['spec']['validations']),
      'admission policy: own pod only, deletion-cost annotation only')

so = find('ScaledObject', 'meet-jvb')
triggers = dict((t['name'], t) for t in so['spec']['triggers'])
check(so['spec']['minReplicaCount'] == 2 and so['spec']['maxReplicaCount'] == 4, 'KEDA: min 2, max 4 bridges')
check(triggers['stress']['metadata']['threshold'] == '0.5' and 'avg_over_time(jitsi_jvb_stress_level' in triggers['stress']['metadata']['query']
      and '[2m]' in triggers['stress']['metadata']['query'], 'KEDA: stress threshold 0.5 over 2 min')
check('>= bool 0.2' in triggers['stress']['metadata']['query'] and '[30m:1m]' in triggers['stress']['metadata']['query'], 'KEDA: shrink only after 30 min below 0.2')
check(triggers['participants']['metadata']['threshold'] == '18', 'KEDA: one more bridge above 18 participants per bridge')
behavior = so['spec']['advanced']['horizontalPodAutoscalerConfig']['behavior']
check(behavior['scaleUp']['stabilizationWindowSeconds'] == 120 and behavior['scaleDown']['stabilizationWindowSeconds'] == 1800
      and behavior['scaleDown']['policies'] == [{'type': 'Pods', 'value': 1, 'periodSeconds': 900}], 'HPA: up after 2 min, down one at a time after 30 min')
gap('KEDA serverAddress is a placeholder until the voip Prometheus endpoint for this cluster exists (k8s-pods/overlays/cowork)')
gap('JVB metric names jitsi_jvb_stress_level / jitsi_jvb_participants to be checked against /metrics of stable-11248-2 in staging')

# ------------------------------------------------------------------ Cluster Autoscaler
ca = find('Deployment', 'cluster-autoscaler')
args = pod_spec(ca)['containers'][0]['command']
groups = sorted(a.split('=', 1)[1] for a in args if a.startswith('--nodes='))
check(groups == ['0:2:cpx22:fsn1:cowork-jvb-fsn', '1:2:cpx22:hel1:cowork-jvb-hel', '1:2:cpx22:nbg1:cowork-jvb-nbg'],
      'autoscaler node groups cowork-jvb-hel 1:2, -nbg 1:2, -fsn 0:2, CPX22')
check('--cloud-provider=hetzner' in args and '--balance-similar-node-groups' in args and '--scale-down-unneeded-time=10m' in args,
      'autoscaler: Hetzner provider, balanced groups, scale-down after 10 min')
check(pod_spec(ca)['nodeSelector'] == {'talkchief.io/pool': 'cowork-wk'}, 'autoscaler runs on a worker, never on a bridge node')
caenv = env_of(pod_spec(ca)['containers'][0])
check(all(caenv[k]['valueFrom']['secretKeyRef']['name'] == 'cluster-autoscaler-hcloud' for k in ('HCLOUD_TOKEN', 'HCLOUD_CLUSTER_CONFIG')),
      'HCLOUD token and Talos machine config from a Secret')
gap('HCLOUD_NETWORK / HCLOUD_FIREWALL are placeholders until Terraform names them (k8s-pods/overlays/cowork)')

# ------------------------------------------------------------------ NetworkPolicies
deny = find('NetworkPolicy', 'default-deny')
check(deny['spec']['podSelector'] == {} and sorted(deny['spec']['policyTypes']) == ['Egress', 'Ingress'] and deny['metadata']['namespace'] == 'meet',
      'default-deny NetworkPolicy in namespace meet')
dns = find('NetworkPolicy', 'allow-dns')
check({p['port'] for r in dns['spec']['egress'] for p in r['ports']} == {53}, 'every pod may use DNS')
policies = dict((o['metadata']['name'], o) for _, o in OBJECTS if o['kind'] == 'NetworkPolicy')
for name in ('meet-shard', 'meet-haproxy', 'meet-asap', 'meet-events'):
    check(name in policies, 'NetworkPolicy for %s' % name)
check(any(p['port'] == 8000 for r in policies['meet-haproxy']['spec']['egress'] for p in r['ports']), 'HAProxy may reach the shards\' web')
check(any(p['port'] == 8065 for r in policies['meet-shard']['spec']['egress'] for p in r['ports'])
      and any(p['port'] == 8065 for r in policies['meet-events']['spec']['egress'] for p in r['ports']), 'shards and the events relay may reach Cowork 8065')
cnp = find('CiliumNetworkPolicy', 'meet-shard-from-bridges')
check(cnp['spec']['ingress'][0]['toPorts'][0]['ports'] == [{'port': '5222', 'protocol': 'TCP'}], 'bridges (node addresses) may reach Prosody 5222 only')

# ------------------------------------------------------------------ alert rules
rules_cm = GENERATED['meet-prometheus-rules']
rules = yaml.safe_load(open(rules_cm['meet.yml'], encoding='utf-8'))['groups'][0]['rules']
by_name = dict((r['alert'], r) for r in rules)
check(set(by_name) == {'MeetShardDown', 'JvbStressHigh', 'JvbPoolAtMax', 'JvbPoolBelowMin', 'JvbCpuSteal'}, 'five Meet alerts')
kust = load('k8s-pods/meet-namespace/k8s/kustomization.yaml')[0]
check([g for g in kust['configMapGenerator'] if g['name'] == 'meet-prometheus-rules'][0]['options']['labels'] == {'talkchief.io/prometheus-rules': 'true'}, 'rules ConfigMap labelled talkchief.io/prometheus-rules')
steal = by_name['JvbCpuSteal']
check('mode="steal"' in steal['expr'] and '> 0.05' in steal['expr'] and 'cowork-jvb' in steal['expr'] and steal['for'] == '10m',
      'JvbCpuSteal: node CPU steal above 5 % for 10 min on cowork-jvb nodes')
check('> 0.8' in by_name['JvbStressHigh']['expr'] and by_name['JvbStressHigh']['for'] == '5m', 'JvbStressHigh: average stress above 0.8 for 5 min')
check(by_name['JvbPoolAtMax']['for'] == '15m' and by_name['MeetShardDown']['for'] == '2m', 'JvbPoolAtMax 15 min, MeetShardDown 2 min')
check('< 2' in by_name['JvbPoolBelowMin']['expr'] and 'zone' in by_name['JvbPoolBelowMin']['expr'], 'JvbPoolBelowMin: fewer than two bridges or one site')

# ------------------------------------------------------------------ no secrets in Git
SECRET_PATTERNS = [
    re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
    re.compile(r'(?<!sha256:)(?<![0-9a-fA-F])[0-9a-f]{40,}(?![0-9a-f])'),
    re.compile(r'(?i)(password|secret|token)\s*[:=]\s*["\']?(?!CHANGE_ME)[A-Za-z0-9+/_\-]{16,}'),
    re.compile(r'ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}'),
]
leaks = []
for base, _, files in os.walk(PODS):
    for name in files:
        path = os.path.join(base, name)
        text = open(path, encoding='utf-8', errors='ignore').read()
        if name == 'secret.example.yaml':
            for doc in yaml.safe_load_all(text):
                values = list((doc.get('stringData') or {}).values())
                if not values or not all('CHANGE_ME' in v for v in values):
                    leaks.append('%s: a non-placeholder value' % rel(path))
            continue
        for pattern in SECRET_PATTERNS:
            for match in pattern.finditer(text):
                before = text[max(0, match.start() - 7):match.start()]
                if before == 'commit ' or before.endswith('blob/'):
                    continue  # a public Git commit id
                leaks.append('%s: %s' % (rel(path), match.group(0)[:24]))
check(not leaks, 'no secret-looking value outside secret.example.yaml, which holds CHANGE_ME only%s' % ''.join('\n  ' + l for l in leaks))

# ------------------------------------------------------------------ sidecar, against a stand-in bridge
spec_mod = importlib.util.spec_from_file_location('jvb_sidecar', os.path.join(PODS, 'meet-jvb', 'k8s', 'jvb_sidecar.py'))
sidecar = importlib.util.module_from_spec(spec_mod)
spec_mod.loader.exec_module(sidecar)
check(sidecar.public_ipv4('95.216.1.2\n') == '95.216.1.2', 'advertise: a public IPv4 is accepted')
for wrong in ('10.0.0.5', '169.254.169.254', 'not-an-ip'):
    try:
        sidecar.public_ipv4(wrong)
        check(False, 'advertise: %s is refused' % wrong)
    except ValueError:
        check(True, 'advertise: %s is refused' % wrong)
check(sidecar.deletion_cost_patch(7) == {'metadata': {'annotations': {'controller.kubernetes.io/pod-deletion-cost': '7'}}},
      'deletion cost patch sets only the annotation, as a string')

CALLS = []
STATE = {'participants': 3, 'conferences': 1}


class FakeBridge(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body=b'{}'):
        self.send_response(code)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        CALLS.append(('GET', self.path))
        if self.path == '/colibri/stats':
            # Participants leave while the bridge is drained; conferences end after shutdown.
            if any(c == ('POST', '/colibri/drain/enable') for c in CALLS):
                STATE['participants'] = max(0, STATE['participants'] - 1)
            if any(c[1] == '/colibri/shutdown' for c in CALLS):
                STATE['conferences'] = 0
            self.reply(200, ('{"participants": %d, "conferences": %d}' % (STATE['participants'], STATE['conferences'])).encode())
        else:
            self.reply(404)

    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length).decode()
        CALLS.append(('POST', self.path) if self.path != '/colibri/shutdown' else ('POST', self.path, body))
        self.reply(200)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeBridge)
threading.Thread(target=server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory() as shared:
    sidecar.COLIBRI = 'http://127.0.0.1:%d' % server.server_address[1]
    sidecar.SHARED = shared
    sidecar.drain(deadline_seconds=60, poll=0, sleep=lambda _: None)
    posts = [c for c in CALLS if c[0] == 'POST']
    check(posts == [('POST', '/colibri/drain/enable'), ('POST', '/colibri/shutdown', '{"graceful-shutdown": "true"}')],
          'drain: drain first, graceful shutdown only after the last participant left')
    check(STATE['participants'] == 0 and os.path.isfile(os.path.join(shared, 'drained')), 'drain: writes the file the jvb preStop waits for')
    CALLS.clear()
    sidecar.COLIBRI = 'http://127.0.0.1:1'
    os.remove(os.path.join(shared, 'drained'))
    sidecar.drain(deadline_seconds=5, poll=0, sleep=lambda _: None)
    check(os.path.isfile(os.path.join(shared, 'drained')), 'drain: a bridge that no longer answers counts as drained')
server.shutdown()

# ------------------------------------------------------------------ result
print()
print('Known gaps (%d):' % len(GAPS))
for item in GAPS:
    print('  - ' + item)
if FAILURES:
    print('\n%d FAILED' % len(FAILURES))
    sys.exit(1)
print('\nALL PASSED')
